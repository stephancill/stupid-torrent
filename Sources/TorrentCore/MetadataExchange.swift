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

    /// Fetches the info dict over TCP with MSE/PE encryption (BEP 10), falling back to plaintext
    /// for peers that don't speak MSE. The transport-level path used for injected peers and tests.
    public func fetch(from address: PeerAddress, timeout: Duration = .seconds(3), connectTimeout: Duration = .seconds(2)) async throws -> Data {
        let stream = try PeerStream(host: address.host, port: address.port)
        return try await withTaskCancellationHandler {
            // Connect is bounded by its own `connectTimeout`, so arm the overall timeout only
            // AFTER the connection is up. Arming it before lets a 3s timeout close the stream
            // while a slow/queued connect() is still in flight -> connect() runs on a closed fd
            // (EBADF), and every peer in a slow sweep dies with errno 9 instead of being swept.
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
            return try await performMetadataExchange(stream: stream, address: address, overUTP: false, timeout: timeout)
        } onCancel: {
            stream.close()
        }
    }

    /// Fetches the info dict over µTP (BEP 29) with a plaintext BitTorrent handshake — µTP is its
    /// own transport, so MSE is skipped (mirrors the download path's `supportsMSE: false` µTP
    /// sessions). Reaches µTP-only peers (transmission/deluge/webtorrent) that close TCP metadata
    /// connections.
    public func fetchUTP(from address: PeerAddress, transport: UTPTransport, timeout: Duration = .seconds(3), connectTimeout: Duration = .seconds(2)) async throws -> Data {
        let connection = await transport.connect(to: address)
        do {
            try await connection.startAsInitiator(timeout: connectTimeout)
        } catch {
            await connection.unregister()
            throw error
        }
        let stream = UTPStream(connection: connection)
        return try await withTaskCancellationHandler {
            TorrentLog.log("metadata: µTP connected to \(address.host)")
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
            return try await performMetadataExchange(stream: stream, address: address, overUTP: true, timeout: timeout)
        } onCancel: {
            stream.close()
        }
    }

    /// The wire exchange that is identical over both transports: BT handshake (extension bit),
    /// extended handshake (BEP 10), then ut_metadata (BEP 9) — request all pieces up front
    /// (webtorrent's `_requestPieces`) and assemble until the assembled dict hashes to the infohash.
    private func performMetadataExchange(stream: PeerTransport, address: PeerAddress, overUTP: Bool, timeout: Duration) async throws -> Data {
        let local = Handshake.make(extensionEnabled: true, infoHash: infoHash, peerID: peerID)
        try await stream.send(local.encode())
        let remote = try Handshake.parse(try await stream.read(exactly: Handshake.length))
        guard remote.infoHash == infoHash else { throw MetadataError.wrongInfoHash }
        guard remote.supportsExtensions else { throw MetadataError.noExtensions }
        TorrentLog.log("metadata: handshake ok, peer supports extensions\(overUTP ? " (µTP)" : "")")

        try await stream.send(ExtendedHandshake.message(client: "stupid-torrent-client/0.1", port: clientPort).encode())

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
    }

    private func readMessage(_ stream: PeerTransport) async throws -> PeerMessage? {
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
        if clients.isEmpty && injectedPeer == nil {
            throw MetadataError.timedOut
        }

        // Shared, concurrency-safe peer accumulator. Trackers and DHT append peers as each
        // response lands; the sweep loop drains them continuously. This mirrors webtorrent's
        // event-driven discovery: the first tracker/DHT response starts connection attempts
        // immediately instead of waiting for every announce to finish (a dead UDP tracker used
        // to gate the whole sweep on its 15s timeout).
        let pool = PeerAccumulator()
        if let injectedPeer {
            await pool.add(injectedPeer)
        }

        let dhtClient = try? DHTClient()
        let dhtTask = Task {
            guard let dhtClient else { return }
            defer { dhtClient.stop() }
            // Emit cached live peers for this infohash immediately, before any network query
            // (webtorrent's DHT peer store, emitted at next-tick).
            let cached = dhtClient.cachedPeers(infoHash: magnet.infoHash)
            TorrentLog.log("bootstrap: DHT cache has \(cached.count) cached peers")
            for peer in cached {
                await pool.add(peer)
            }
            TorrentLog.log("bootstrap: querying DHT for peers")
            if let dhtPeers = try? await dhtClient.lookup(infoHash: magnet.infoHash, timeout: 20) { batch in
                // Stream DHT peers into the pool as each get_peers response lands, so the sweep
                // starts on them long before the full lookup finishes.
                for peer in batch {
                    await pool.add(peer)
                }
            } {
                TorrentLog.log("bootstrap: DHT returned \(dhtPeers.count) peers")
            }
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
            for client in clients {
                Task {
                    do {
                        let response = try await client.announce(request)
                        TorrentLog.log("bootstrap: announce got \(response.peers.count) peers (failure: \(response.failureReason ?? "none"))")
                        for peer in response.peers {
                            await pool.add(peer)
                        }
                    } catch {
                        TorrentLog.log("bootstrap: announce failed: \(error)")
                    }
                }
            }
        }

        // Shared outbound-only µTP transport for the metadata sweep. Each candidate is raced
        // over µTP (plaintext) AND TCP (MSE) in parallel, like webtorrent's `utpOutgoing` +
        // `tcpOutgoing` — reaching µTP-only seeders costs nothing on the dead-peer lottery since
        // both transports share the same timeout budget.
        let utpTransport: UTPTransport?
        do {
            let transport = UTPTransport(socket: try UDPSocket())
            await transport.start()
            utpTransport = transport
        } catch {
            TorrentLog.log("bootstrap: µTP transport failed: \(error)")
            utpTransport = nil
        }
        defer {
            if let utpTransport {
                Task { await utpTransport.stop() }
            }
        }

        // Continuous sweep: drain the pool as peers arrive, refilling worker slots the moment
        // one frees (a true pipeline, like webtorrent's conn pool) instead of draining fixed
        // batches. Slower trackers/DHT results join mid-flight.
        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline {
            let active = await pool.queuedCount
            if active == 0 {
                // Nothing new yet (trackers still resolving, DHT still bootstrapping). Poll.
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            TorrentLog.log("bootstrap: streaming sweep (pool \(active))")
            if let result = try await sweepStreaming(pool, infoHash: magnet.infoHash, peerID: peerID, magnet: magnet, utpTransport: utpTransport) {
                dhtTask.cancel()
                // Remember the peer that actually served metadata as confirmed-reachable, so the
                // next resolution for this infohash retries it first instead of re-draining stale
                // get_peers records.
                dhtClient?.cacheKnownGood([result.metadataPeer], for: magnet.infoHash)
                return result
            }
        }
        dhtTask.cancel()
        throw MetadataError.timedOut
    }

    /// Concurrency-safe peer accumulator: discovery sources (trackers, DHT, injected) append
    /// peers as each response lands; the sweep workers pull them one at a time.
    private actor PeerAccumulator {
        private var queued: [PeerAddress] = []
        private var seen: Set<PeerAddress> = []

        var queuedCount: Int { queued.count }

        func add(_ peer: PeerAddress) {
            guard seen.insert(peer).inserted else { return }
            queued.append(peer)
        }

        func takeOne() -> PeerAddress? {
            guard !queued.isEmpty else { return nil }
            return queued.removeFirst()
        }
    }

    /// Streaming peer sweep: `concurrency` workers each pull the next candidate from the live
    /// pool the moment their slot frees, so the pool is drained continuously at the maximum
    /// churn rate (mirrors webtorrent's conn-pool `_drain`). Returns on the first peer that
    /// serves metadata, or nil when the pool drains completely.
    private static func sweepStreaming(
        _ pool: PeerAccumulator,
        infoHash: Data,
        peerID: Data,
        magnet: MagnetLink,
        utpTransport: UTPTransport?,
        concurrency: Int = 48
    ) async throws -> (metainfo: Metainfo, metadataPeer: PeerAddress)? {
        try await withThrowingTaskGroup(of: (Data, PeerAddress)?.self) { group in
            var active = 0
            while active < concurrency {
                guard let peer = await pool.takeOne() else { break }
                group.addTask {
                    await fetchMetadata(from: peer, infoHash: infoHash, peerID: peerID, utpTransport: utpTransport)
                }
                active += 1
            }
            while let result = try await group.next() {
                active -= 1
                if let result {
                    group.cancelAll()
                    let metainfo = try Metainfo(
                        infoDict: result.0,
                        trackers: [magnet.trackers],
                        displayName: magnet.displayName
                    )
                    return (metainfo, result.1)
                }
                // Refill the freed slot from the live pool immediately.
                if let peer = await pool.takeOne() {
                    group.addTask {
                        await fetchMetadata(from: peer, infoHash: infoHash, peerID: peerID, utpTransport: utpTransport)
                    }
                    active += 1
                }
            }
            return nil
        }
    }

    private static func fetchMetadata(from peer: PeerAddress, infoHash: Data, peerID: Data, utpTransport: UTPTransport?) async -> (Data, PeerAddress)? {
        // Race µTP and TCP (webtorrent opens both `utpOutgoing` + `tcpOutgoing` and keeps the
        // first to connect). Both share the connect/`metadata` budget, so a dead peer still costs
        // ~one timeout — but a µTP-only seeder is reachable. Retry once when a peer closes on
        // connect (fresh connection usually works); timeouts are NOT retried.
        do {
            let fetcher = MetadataFetcher(infoHash: infoHash, peerID: peerID)
            let infoDict = try await raceTransports(fetcher, from: peer, utpTransport: utpTransport)
            return (infoDict, peer)
        } catch PeerStreamError.closed {
            TorrentLog.log("bootstrap: peer \(peer.host) closed on connect; retrying once")
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

    /// Runs the TCP (MSE) fetch and the µTP (plaintext) fetch concurrently; the first success
    /// wins and the loser is cancelled. If no transport succeeds, the first error is returned.
    private static func raceTransports(_ fetcher: MetadataFetcher, from peer: PeerAddress, utpTransport: UTPTransport?) async throws -> Data {
        let outcome = await withTaskGroup(of: Result<Data, Error>.self) { group in
            group.addTask {
                do {
                    return .success(try await fetcher.fetch(from: peer))
                } catch {
                    return .failure(error)
                }
            }
            if let utpTransport {
                group.addTask {
                    do {
                        return .success(try await fetcher.fetchUTP(from: peer, transport: utpTransport))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var firstFailure: Error?
            while let result = await group.next() {
                switch result {
                case .success(let data):
                    group.cancelAll()
                    return Result<Data, Error>.success(data)
                case .failure(let error):
                    if firstFailure == nil {
                        firstFailure = error
                    }
                }
            }
            return Result<Data, Error>.failure(firstFailure ?? MetadataError.timedOut)
        }
        return try outcome.get()
    }
}
