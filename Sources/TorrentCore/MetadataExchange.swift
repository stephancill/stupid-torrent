import Foundation
import CryptoKit
import Bencode

public enum MetadataError: Error, Sendable {
    case wrongInfoHash
    case noExtensions
    case noMetadataExtension
    case peerHasNoMetadata
    case rejected
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

    /// Reads the peer's advertised `metadata_size` from an extended-handshake payload. A peer that
    /// supports `ut_metadata` but has no info dict (a leecher still bootstrapping) omits this field;
    /// requesting from such a peer only burns time, so callers gate on this before requesting.
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

    public func fetch(from address: PeerAddress, timeout: Duration = .seconds(5), connectTimeout: Duration = .seconds(3)) async throws -> Data {
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

        // MSE/PE (BEP 10): obfuscate the handshake + payload. Many metadata servers (and most of
        // this swarm) close plaintext connections, so encrypt first; peers without MSE answer in
        // plaintext, which falls back and continues unencrypted.
        let mse = MSEHandshake(stream: stream)
        do {
            try await mse.performAsInitiator(infoHash: infoHash)
            TorrentLog.log("metadata: MSE handshake ok (method \(mse.method == .rc4 ? "rc4" : "plaintext"))")
        } catch MSEError.plaintextFallback {
            TorrentLog.log("metadata: peer doesn't support MSE, using plaintext")
        }

        let local = Handshake.make(extensionEnabled: true, infoHash: infoHash, peerID: peerID)
        try await stream.send(local.encode())
        let remote = try Handshake.parse(try await stream.read(exactly: Handshake.length))
        guard remote.infoHash == infoHash else { throw MetadataError.wrongInfoHash }
        guard remote.supportsExtensions else { throw MetadataError.noExtensions }
        TorrentLog.log("metadata: handshake ok, peer supports extensions")

        try await stream.send(ExtendedHandshake.message(client: "stupid-torrent-client/0.1", port: clientPort).encode())
        TorrentLog.log("metadata: sent extended handshake")

        var metadataID: Int?
        var metadataSize: Int?
        while metadataID == nil {
            guard let message = try await readMessage(stream) else { continue }
            if case .extended(let extID, let payload) = message, extID == 0 {
                metadataID = ExtendedHandshake.utMetadataID(from: payload)
                metadataSize = ExtendedHandshake.metadataSize(from: payload)
            }
        }
        guard let metadataID else { throw MetadataError.noMetadataExtension }
        // A peer that advertises ut_metadata without a metadata_size has no info dict (it's a
        // leecher still bootstrapping). Skip it immediately instead of requesting and waiting for
        // data that will never come — webtorrent's ut_metadata does the same check.
        guard let metadataSize, metadataSize > 0 else { throw MetadataError.peerHasNoMetadata }
        // The id we advertise for ut_metadata (used by the peer when sending data TO us).
        let ourMetadataID: UInt8 = 1
        TorrentLog.log("metadata: peer ut_metadata id = \(metadataID), size = \(metadataSize)")

        let deadline = ContinuousClock.now + timeout
        let pieceCount = (metadataSize + MetadataMessage.chunkSize - 1) / MetadataMessage.chunkSize
        var chunks: [Int: Data] = [:]
        // Request all metadata pieces up front (webtorrent's `_requestPieces` sends them all at
        // once). Sequential request-after-data is slower and stalls on half-responders.
        for piece in 0..<pieceCount {
            try await stream.send(MetadataMessage.request(id: metadataID, piece: piece).encode())
        }

        while ContinuousClock.now < deadline {
            guard let message = try await readMessage(stream) else { continue }
            guard case .extended(let extID, let payload) = message, extID == ourMetadataID else { continue }
            guard let dataMessage = try? MetadataMessage.parseData(payload) else { continue }
            chunks[dataMessage.piece] = dataMessage.chunk
            TorrentLog.log("metadata: chunk \(dataMessage.piece) (\(dataMessage.chunk.count)B, \(chunks.count)/\(pieceCount))")
            if chunks.count >= pieceCount {
                var assembled = Data()
                for index in 0..<pieceCount {
                    guard let chunk = chunks[index] else { break }
                    assembled.append(chunk)
                }
                guard assembled.count == metadataSize else { continue }
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
        //   - Trackers return large peer lists that include real seeders
        //   - DHT (BEP 5) finds live, reachable peers that trackers often don't return
        // Announce to trackers FIRST, immediately (mirroring webtorrent's torrent-discovery: it
        // announces at t=0). The DHT lookup runs concurrently and its peers are swept afterward.
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

        // The swarm is overwhelmingly dead/NAT'd: only a handful of peers in a few hundred are
        // reachable and serve ut_metadata. Instead of giving up after one sample, re-announce for
        // fresh peer lists and keep sweeping until we find a cooperative peer or exhaust rounds.
        // The tracker sweep runs FIRST and immediately (tracker peers include seeders) — do NOT
        // block it on the DHT lookup, which takes ~20s. DHT peers are swept in parallel.
        let rounds = 6
        var seen: Set<PeerAddress> = []
        for round in 0..<rounds {
            var candidates: [PeerAddress] = []
            if round == 0 {
                // Sweep tracker-returned peers immediately. Kick off the DHT sweep concurrently
                // (its lookup has already been running) instead of awaiting it first.
                candidates = dedup(peers)
            } else {
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
                                    return response.peers
                                } catch {
                                    return []
                                }
                            }
                        }
                        for await result in group {
                            peers.append(contentsOf: result)
                        }
                    }
                }
                candidates = dedup(Array(Set(peers).subtracting(seen)))
            }
            let fresh = candidates.filter { seen.insert($0).inserted }.prefix(300)
            if round == 0, !fresh.isEmpty {
                // Sweep tracker candidates IMMEDIATELY, and run the DHT candidate sweep in
                // parallel — whichever finds a metadata server wins. Do NOT await the DHT lookup
                // before starting the tracker sweep (that was the ~20s stall).
                let result = try await withThrowingTaskGroup(of: (Metainfo, PeerAddress)?.self) { group in
                    group.addTask {
                        try await sweepCandidates(fresh, infoHash: magnet.infoHash, peerID: peerID, magnet: magnet)
                    }
                    group.addTask {
                        let dhtPeers = dedup(await dhtPeerTask.value)
                        return try await sweepCandidates(dhtPeers, infoHash: magnet.infoHash, peerID: peerID, magnet: magnet)
                    }
                    var result: (Metainfo, PeerAddress)? = nil
                    while let next = try await group.next() {
                        if let next {
                            result = next
                            group.cancelAll()
                            break
                        }
                    }
                    return result
                }
                if let result {
                    seen.formUnion(fresh)
                    return result
                }
            } else {
                TorrentLog.log("bootstrap round \(round): \(fresh.count) fresh candidate peers (total \(seen.count))")
                if let result = try await sweepCandidates(fresh, infoHash: magnet.infoHash, peerID: peerID, magnet: magnet) {
                    return result
                }
            }
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
            // Balance: webtorrent opens up to ~55 outgoing connections, but too much concurrency
            // makes peers reject/close (observed `write(9)`/`closed` at 30). 24 is a safe middle
            // ground that cycles dead peers ~2x faster than 12.
            let concurrency = min(24, list.count)
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
