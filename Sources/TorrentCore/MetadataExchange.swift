import Foundation
import CryptoKit
import Bencode

public enum MetadataError: Error, Sendable {
    case noPeerSources
    case noExtensions
    case noMetadataExtension
    case peerHasNoMetadata
    case hashMismatch
    case timedOut
    case notData
}

public enum ExtendedHandshake {
    static let localMetadataID: UInt8 = 1

    public static func message(client: String) -> PeerMessage {
        let payload = Bencode.encode(.dictionary([
            "m": .dictionary(["ut_metadata": .int(Int(localMetadataID))]),
            "v": .string(Data(client.utf8)),
            "reqq": .int(128),
        ]))
        return .extended(0, payload)
    }

    public static func utMetadataID(from payload: Data) -> Int? {
        guard let root = try? Bencode.decode(payload),
              case .dictionary(let dict) = root,
              case .dictionary(let m)? = dict["m"],
              let id = m["ut_metadata"]?.intValue else { return nil }
        return id
    }

    public static func metadataSize(from payload: Data) -> Int? {
        guard let root = try? Bencode.decode(payload),
              case .dictionary(let dict) = root,
              let size = dict["metadata_size"]?.intValue else { return nil }
        return size
    }
}

public enum MetadataMessage {
    public static let chunkSize = 16 * 1024

    public static func request(id: Int, piece: Int) -> PeerMessage {
        let payload = Bencode.encode(.dictionary([
            "msg_type": .int(0),
            "piece": .int(piece),
        ]))
        return .extended(UInt8(id), payload)
    }

    public struct DataMessage {
        public let piece: Int
        public let totalSize: Int?
        public let chunk: Data
    }

    public static func parseData(_ payload: Data) throws -> DataMessage? {
        let (value, consumed) = try Bencode.decodeFirst(payload)
        guard case .dictionary(let dict) = value,
              let msgType = dict["msg_type"]?.intValue else {
            throw MetadataError.notData
        }
        switch msgType {
        case 1:
            return DataMessage(
                piece: dict["piece"]?.intValue ?? 0,
                totalSize: dict["total_size"]?.intValue,
                chunk: Data(payload.dropFirst(consumed))
            )
        default:
            return nil
        }
    }
}

struct MetadataFetcher: Sendable {
    let infoHash: Data

    func fetch(over connection: PeerConnection, timeout: Duration) async throws -> Data {
        guard connection.remote.supportsExtensions else { throw MetadataError.noExtensions }
        let transport = connection.transport
        return try await withTimeout(timeout, onCancel: { transport.close() }) {
            try await exchange(over: transport)
        }
    }

    private func exchange(over transport: any PeerTransport) async throws -> Data {
        try await transport.send(ExtendedHandshake.message(client: "stupid-torrent-client/\(TorrentCore.version)").encode())

        var handshake: Data?
        while handshake == nil {
            if case .extended(0, let payload)? = try await transport.readMessage() {
                handshake = payload
            }
        }
        guard let handshake, let metadataID = ExtendedHandshake.utMetadataID(from: handshake) else {
            throw MetadataError.noMetadataExtension
        }
        guard let metadataSize = ExtendedHandshake.metadataSize(from: handshake), metadataSize > 0 else {
            throw MetadataError.peerHasNoMetadata
        }

        let chunkCount = (metadataSize + MetadataMessage.chunkSize - 1) / MetadataMessage.chunkSize
        for piece in 0..<chunkCount {
            try await transport.send(MetadataMessage.request(id: metadataID, piece: piece).encode())
        }
        var chunks: [Int: Data] = [:]
        while chunks.count < chunkCount {
            guard case .extended(ExtendedHandshake.localMetadataID, let payload)? = try await transport.readMessage(),
                  let message = try? MetadataMessage.parseData(payload),
                  (0..<chunkCount).contains(message.piece) else { continue }
            chunks[message.piece] = message.chunk
        }
        let assembled = (0..<chunkCount).reduce(into: Data()) { $0.append(chunks[$1]!) }
        guard assembled.count == metadataSize, Data(Insecure.SHA1.hash(data: assembled)) == infoHash else {
            throw MetadataError.hashMismatch
        }
        return assembled
    }
}

public enum MagnetBootstrapper {
    private static let sweepConcurrency = 48
    private static let deadline = Duration.seconds(180)
    private static let placeholderPort: UInt16 = 6881

    public static func metainfoAndPeer(
        from magnet: MagnetLink,
        peerID: Data = PeerID.generate(),
        injectedPeer: PeerAddress? = nil
    ) async throws -> (metainfo: Metainfo, metadataPeer: PeerAddress?) {
        let clients = magnet.trackers.compactMap { try? TrackerClientFactory.makeClient(for: $0) }
        let dht = DHTNode.shared()
        guard !clients.isEmpty || injectedPeer != nil || dht != nil else { throw MetadataError.noPeerSources }

        let pool = PeerAccumulator()
        if let injectedPeer {
            await pool.add([injectedPeer])
        }
        let discovery = [
            Task { await discoverFromDHT(dht, infoHash: magnet.infoHash, into: pool) },
            Task { await discoverFromTrackers(clients, infoHash: magnet.infoHash, peerID: peerID, into: pool) },
        ]
        let utp = UTPTransport(socket: try UDPSocket())
        await utp.start()
        defer {
            discovery.forEach { $0.cancel() }
            Task { await utp.stop() }
        }

        let connector = PeerConnector(
            infoHash: magnet.infoHash,
            peerID: peerID,
            utp: utp,
            connectTimeout: .seconds(2),
            handshakeTimeout: .seconds(3)
        )
        let fetcher = MetadataFetcher(infoHash: magnet.infoHash)
        let found = try await sweep(pool: pool, connector: connector, fetcher: fetcher)
        await dht?.cacheKnownGood([found.1], for: magnet.infoHash)
        let metainfo = try Metainfo(infoDict: found.0, trackers: [magnet.trackers], displayName: magnet.displayName)
        return (metainfo, found.1)
    }

    private static func sweep(pool: PeerAccumulator, connector: PeerConnector, fetcher: MetadataFetcher) async throws -> (Data, PeerAddress) {
        do {
            return try await withTimeout(deadline, onCancel: { Task { await pool.close() } }) {
                try await firstServedMetadata(pool: pool, connector: connector, fetcher: fetcher)
            }
        } catch is TimeoutError {
            throw MetadataError.timedOut
        }
    }

    private static func firstServedMetadata(pool: PeerAccumulator, connector: PeerConnector, fetcher: MetadataFetcher) async throws -> (Data, PeerAddress) {
        try await withThrowingTaskGroup(of: (Data, PeerAddress)?.self) { group in
            for _ in 0..<sweepConcurrency {
                group.addTask {
                    while let peer = await pool.next() {
                        if let infoDict = await fetch(from: peer, connector: connector, fetcher: fetcher) {
                            return (infoDict, peer)
                        }
                    }
                    return nil
                }
            }
            for try await case let found? in group {
                await pool.close()
                group.cancelAll()
                return found
            }
            throw MetadataError.timedOut
        }
    }

    private static func fetch(from peer: PeerAddress, connector: PeerConnector, fetcher: MetadataFetcher) async -> Data? {
        do {
            let connection = try await connector.connect(to: peer)
            defer { connection.transport.close() }
            return try await fetcher.fetch(over: connection, timeout: .seconds(3))
        } catch {
            TorrentLog.log("bootstrap: peer \(peer.host) metadata failed: \(error)")
            return nil
        }
    }

    private static func discoverFromDHT(_ dht: DHTClient?, infoHash: Data, into pool: PeerAccumulator) async {
        guard let dht else { return }
        await pool.add(await dht.cachedPeers(infoHash: infoHash))
        let peers = try? await dht.lookup(infoHash: infoHash, timeout: 20) { batch in
            await pool.add(batch)
        }
        TorrentLog.log("bootstrap: DHT returned \(peers?.count ?? 0) peers")
    }

    private static func discoverFromTrackers(_ clients: [any TrackerClient], infoHash: Data, peerID: Data, into pool: PeerAccumulator) async {
        guard !clients.isEmpty else { return }
        let request = AnnounceRequest(infoHash: infoHash, peerID: peerID, port: placeholderPort, left: 0, event: .started, numWant: 200)
        while !Task.isCancelled {
            await withTaskGroup(of: Void.self) { group in
                for client in clients {
                    group.addTask {
                        do {
                            await pool.add(try await client.announce(request).peers)
                        } catch {
                            TorrentLog.log("bootstrap: announce failed: \(error)")
                        }
                    }
                }
            }
            try? await Task.sleep(for: .seconds(15))
        }
    }

    private actor PeerAccumulator {
        private var queued: [PeerAddress] = []
        private var seen: Set<PeerAddress> = []
        private var waiters: [CheckedContinuation<PeerAddress?, Never>] = []
        private var closed = false

        func add(_ peers: [PeerAddress]) {
            for peer in peers where !closed && seen.insert(peer).inserted {
                if waiters.isEmpty {
                    queued.append(peer)
                } else {
                    waiters.removeFirst().resume(returning: peer)
                }
            }
        }

        func next() async -> PeerAddress? {
            guard !closed else { return nil }
            if !queued.isEmpty { return queued.removeFirst() }
            return await withCheckedContinuation { waiters.append($0) }
        }

        func close() {
            closed = true
            queued.removeAll()
            waiters.forEach { $0.resume(returning: nil) }
            waiters.removeAll()
        }
    }
}
