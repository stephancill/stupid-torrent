import Foundation
import CryptoKit
import Bencode

public enum MetadataError: Error, Sendable {
    case wrongInfoHash
    case noExtensions
    case noMetadataExtension
    case hashMismatch
    case timedOut
    case notData
}

public enum ExtendedHandshake {
    /// The extended-handshake message (BEP 10). Extended id 0 is always the handshake.
    public static func message(client: String, port: UInt16) -> PeerMessage {
        let payload = Bencode.encode(.dictionary([
            "m": .dictionary(["ut_metadata": .int(1)]),
            "v": .string(Data(client.utf8)),
            "p": .int(Int(port)),
            "reqq": .int(128),
        ]))
        return .extended(0, payload)
    }

    /// Reads the peer's negotiated `ut_metadata` extension id from an extended-handshake payload.
    public static func utMetadataID(from payload: Data) -> Int? {
        guard let root = try? Bencode.decode(payload),
              case .dictionary(let dict) = root,
              case .dictionary(let m)? = dict["m"],
              let id = m["ut_metadata"]?.intValue else { return nil }
        return id
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

    /// Parses a ut_metadata message payload. Returns the data message for msg_type 1,
    /// or nil for requests/rejects.
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

/// Fetches the raw bencoded info dict for an info hash from a peer, using the
/// ut_metadata extension (BEP 9/10). Used to bootstrap a magnet link into a full torrent.
public final class MetadataFetcher: @unchecked Sendable {
    private let infoHash: Data
    private let peerID: Data
    private let clientPort: UInt16

    public init(infoHash: Data, peerID: Data, clientPort: UInt16 = 0) {
        self.infoHash = infoHash
        self.peerID = peerID
        self.clientPort = clientPort
    }

    public func fetch(from address: PeerAddress, timeout: Duration = .seconds(8), connectTimeout: Duration = .seconds(4)) async throws -> Data {
        let stream = try PeerStream(host: address.host, port: address.port)
        return try await withTaskCancellationHandler {
            let timeoutTask = Task {
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled {
                    stream.close()
                }
            }
            defer {
                timeoutTask.cancel()
                stream.close()
            }
            let seconds = TimeInterval(connectTimeout.components.seconds) + TimeInterval(connectTimeout.components.attoseconds) / 1e18
            try await stream.connect(timeout: seconds)
        TorrentLog.log("metadata: connected to \(address.host)")

        let local = Handshake.make(extensionEnabled: true, infoHash: infoHash, peerID: peerID)
        try await stream.send(local.encode())
        let remote = try Handshake.parse(try await stream.read(exactly: Handshake.length))
        guard remote.infoHash == infoHash else { throw MetadataError.wrongInfoHash }
        guard remote.supportsExtensions else { throw MetadataError.noExtensions }
        TorrentLog.log("metadata: handshake ok, peer supports extensions")

        try await stream.send(ExtendedHandshake.message(client: "stupid-torrent-client/0.1", port: clientPort).encode())
        TorrentLog.log("metadata: sent extended handshake")

        var metadataID: Int?
        while metadataID == nil {
            guard let message = try await readMessage(stream) else { continue }
            if case .extended(let extID, let payload) = message, extID == 0 {
                metadataID = ExtendedHandshake.utMetadataID(from: payload)
            }
        }
        guard let metadataID else { throw MetadataError.noMetadataExtension }
        // The id we advertise for ut_metadata (used by the peer when sending data TO us).
        let ourMetadataID: UInt8 = 1
        TorrentLog.log("metadata: peer ut_metadata id = \(metadataID)")

        let deadline = ContinuousClock.now + timeout
        var chunks: [Int: Data] = [:]
        var totalSize: Int?
        var nextToRequest = 0
        func requestPiece(_ piece: Int) async throws {
            try await stream.send(MetadataMessage.request(id: metadataID, piece: piece).encode())
        }

        try await requestPiece(0)
        nextToRequest = 1

        while ContinuousClock.now < deadline {
            guard let message = try await readMessage(stream) else { continue }
            guard case .extended(let extID, let payload) = message, extID == ourMetadataID else { continue }
            guard let dataMessage = try? MetadataMessage.parseData(payload) else { continue }
            chunks[dataMessage.piece] = dataMessage.chunk
            TorrentLog.log("metadata: chunk \(dataMessage.piece) (\(dataMessage.chunk.count)B, \(chunks.count) so far)")
            totalSize = totalSize ?? dataMessage.totalSize
            if let total = totalSize {
                let pieceCount = (total + MetadataMessage.chunkSize - 1) / MetadataMessage.chunkSize
                while nextToRequest < pieceCount {
                    try await requestPiece(nextToRequest)
                    nextToRequest += 1
                }
            }
            if let total = totalSize {
                let pieceCount = (total + MetadataMessage.chunkSize - 1) / MetadataMessage.chunkSize
                guard chunks.count >= pieceCount else { continue }
                var assembled = Data()
                for index in 0..<pieceCount {
                    guard let chunk = chunks[index] else { break }
                    assembled.append(chunk)
                }
                guard assembled.count == total else { continue }
                if Data(Insecure.SHA1.hash(data: assembled)) == infoHash {
                    return assembled
                }
                throw MetadataError.hashMismatch
            }
        }
            throw MetadataError.timedOut
        } onCancel: {
            stream.close()
        }
    }

    private func readMessage(_ stream: PeerStream) async throws -> PeerMessage? {
        let lengthData = try await stream.read(exactly: 4)
        let length = Int(lengthData.readUInt32BE(at: 0))
        if length == 0 { return nil } // keepalive
        let body = try await stream.read(exactly: length)
        return try? PeerMessage.decode(length: length, body: body)
    }
}

public enum MagnetBootstrapper {
    /// Turns a magnet link into full `Metainfo` by discovering peers via its trackers (or an
    /// injected peer) and fetching the info dict over ut_metadata.
    public static func metainfo(
        from magnet: MagnetLink,
        peerID: Data = PeerID.generate(),
        injectedPeer: PeerAddress? = nil
    ) async throws -> Metainfo {
        try await metainfoAndPeer(from: magnet, peerID: peerID, injectedPeer: injectedPeer).metainfo
    }

    /// Bootstraps a magnet into full `Metainfo`, also returning the peer that actually served
    /// the metadata when one is found. That peer is a verified-reachable seed, so callers should
    /// feed it straight into the download instead of re-discovering the (mostly-dead) swarm.
    public static func metainfoAndPeer(
        from magnet: MagnetLink,
        peerID: Data = PeerID.generate(),
        injectedPeer: PeerAddress? = nil
    ) async throws -> (metainfo: Metainfo, metadataPeer: PeerAddress?) {
        var clients: [any TrackerClient] = []
        for url in magnet.trackers {
            if let client = try? TrackerClientFactory.makeClient(for: url) {
                clients.append(client)
            }
        }
        var peers: [PeerAddress] = []
        if let injectedPeer {
            peers.append(injectedPeer)
        }
        // DHT discovery is always attempted (it needs no trackers).
        let dhtClient = try? DHTClient()
        if clients.isEmpty && injectedPeer == nil && dhtClient == nil {
            throw MetadataError.timedOut
        }

        // Discovery runs on two fronts in parallel:
        //   - DHT (BEP 5) finds live, reachable peers that trackers often don't return
        //   - Trackers return large but mostly-NAT'd/poisoned peer lists
        // DHT peers are announced for this infohash, so they're far more likely to answer
        // ut_metadata; sweep them first, then fall back to tracker peers.
        let dhtPeerTask = Task { () -> [PeerAddress] in
            guard let dhtClient else { return [] }
            defer { dhtClient.stop() }
            TorrentLog.log("bootstrap: querying DHT for peers")
            if let dhtPeers = try? await dhtClient.lookup(infoHash: magnet.infoHash, timeout: 20) {
                TorrentLog.log("bootstrap: DHT returned \(dhtPeers.count) peers")
                return dhtPeers
            }
            return []
        }

        // The swarm is overwhelmingly dead/NAT'd: only a handful of peers in a few hundred are
        // reachable and serve ut_metadata. Instead of giving up after one sample, re-announce for
        // fresh peer lists and keep sweeping until we find a cooperative peer or exhaust rounds.
        let rounds = 6
        var seen: Set<PeerAddress> = []
        for round in 0..<rounds {
            if round == 0 {
                // Sweep DHT-discovered peers first (they're live, announced for this infohash).
                // Preserve DHT order (don't go through Set) since the first peers are the closest.
                let dhtPeers = Array(dedup(await dhtPeerTask.value))
                TorrentLog.log("bootstrap: sweeping \(dhtPeers.count) DHT peers for metadata")
                if let result = try await sweepCandidates(dhtPeers, infoHash: magnet.infoHash, peerID: peerID, magnet: magnet) {
                    return result
                }
                seen.formUnion(dhtPeers)
            }
            if !clients.isEmpty {
                let request = AnnounceRequest(
                    infoHash: magnet.infoHash,
                    peerID: peerID,
                    port: 6881,
                    left: 0,
                    event: .started,
                    numWant: 200,
                    key: Int32.random(in: .min ... .max)
                )
                await withTaskGroup(of: [PeerAddress].self) { group in
                    for client in clients {
                        group.addTask {
                            do {
                                let response = try await client.announce(request)
                                TorrentLog.log("bootstrap: announce got \(response.peers.count) peers (failure: \(response.failureReason ?? "none"))")
                                return response.peers
                            } catch {
                                TorrentLog.log("bootstrap: announce failed: \(error)")
                                return []
                            }
                        }
                    }
                    for await result in group {
                        peers.append(contentsOf: result)
                    }
                }
            }
            let fresh = Array(Set(peers).subtracting(seen)).prefix(300)
            TorrentLog.log("bootstrap round \(round): \(fresh.count) fresh candidate peers (total \(Set(peers).count))")
            if let result = try await sweepCandidates(fresh, infoHash: magnet.infoHash, peerID: peerID, magnet: magnet) {
                return result
            }
            seen.formUnion(fresh)
            if round < rounds - 1 {
                try? await Task.sleep(for: .seconds(3))
            }
        }
        throw MetadataError.timedOut
    }

    private static func sweepCandidates(
        _ candidates: some Sequence<PeerAddress>,
        infoHash: Data,
        peerID: Data,
        magnet: MagnetLink
    ) async throws -> (metainfo: Metainfo, metadataPeer: PeerAddress)? {
        let list = Array(candidates)
        guard !list.isEmpty else { return nil }
        return try await withThrowingTaskGroup(of: (Data, PeerAddress)?.self) { group in
            var iterator = list.makeIterator()
            // Keep concurrency low: peers reject/close when hammered with many simultaneous
            // connections (we observed `write(9)`/`closed` under concurrency 30).
            let concurrency = min(12, list.count)
            for _ in 0..<concurrency {
                guard let peer = iterator.next() else { break }
                group.addTask {
                    await fetchMetadata(from: peer, infoHash: infoHash, peerID: peerID)
                }
            }
            while let result = try await group.next() {
                if let result {
                    group.cancelAll()
                    let metainfo = try Metainfo(
                        infoDict: result.0,
                        trackers: [magnet.trackers],
                        displayName: magnet.displayName
                    )
                    return (metainfo, result.1)
                }
                if let peer = iterator.next() {
                    group.addTask {
                        await fetchMetadata(from: peer, infoHash: infoHash, peerID: peerID)
                    }
                }
            }
            return nil
        }
    }

    private static func fetchMetadata(from peer: PeerAddress, infoHash: Data, peerID: Data) async -> (Data, PeerAddress)? {
        do {
            let fetcher = MetadataFetcher(infoHash: infoHash, peerID: peerID)
            let infoDict = try await fetcher.fetch(from: peer)
            return (infoDict, peer)
        } catch let error as PeerStreamError {
            // A peer that closes on connect usually accepts a fresh connection; try once more.
            TorrentLog.log("bootstrap: peer \(peer.host) \(error); retrying once")
            let fetcher = MetadataFetcher(infoHash: infoHash, peerID: peerID)
            do {
                let infoDict = try await fetcher.fetch(from: peer)
                return (infoDict, peer)
            } catch {
                TorrentLog.log("bootstrap: peer \(peer.host) metadata failed: \(error)")
                return nil
            }
        } catch {
            TorrentLog.log("bootstrap: peer \(peer.host) metadata failed: \(error)")
            return nil
        }
    }

    private static func dedup(_ peers: [PeerAddress]) -> [PeerAddress] {
        var seen = Set<PeerAddress>()
        var out: [PeerAddress] = []
        for peer in peers where seen.insert(peer).inserted {
            out.append(peer)
        }
        return out
    }
}
