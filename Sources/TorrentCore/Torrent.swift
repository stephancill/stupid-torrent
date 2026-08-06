import Foundation
import CryptoKit

public actor Torrent {
    nonisolated public let metainfo: Metainfo
    nonisolated public let statusBroadcast: StatusBroadcast<TorrentStatus>

    private let directory: URL
    let storage: Storage
    private let peerID: Data
    private let maxActivePeers: Int
    private let stopAfterBytes: Int64?

    var picker: PiecePicker
    private var receivedBlocks: [Int: Set<Int>] = [:]
    private var pieceBlockCursor: [Int: Int] = [:]
    private var activePieces: Set<Int> = []
    private var outstanding: [BlockKey: UUID] = [:]
    private var blockSenders: [BlockKey: UUID] = [:]
    private var pieceFailures: [Int: Int] = [:]
    private let maxPieceFailures = 5

    private var activePeerIDs: Set<UUID> = []
    private var peerSessions: [UUID: PeerSession] = [:]
    private var bannedPeers: Set<UUID> = []
    private var peerFailures: [UUID: Int] = [:]
    private var pendingPeerAddresses: Set<PeerAddress> = []
    private var trackerClients: [any TrackerClient] = []

    private var listener: TCPListener?
    private var listenerThread: Thread?
    private var listenPort: UInt16 = 0

    private var announceTask: Task<Void, Never>?
    private var dhtTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var isRunning = false
    private var firstAnnounce = true
    private var verifiedDirty = false

    private var downloadedBytes: Int64 = 0
    private var uploadedBytes: Int64 = 0
    private var lastTickDownloaded: Int64 = 0
    private var lastTickUploaded: Int64 = 0
    private var downloadRate: Double = 0
    private var uploadRate: Double = 0
    private var lastSeeders = 0

    public init(directory: URL, metainfo: Metainfo, peerID: Data = PeerID.generate(), maxActivePeers: Int = 30, stopAfterBytes: Int64? = nil) {
        self.directory = directory
        self.metainfo = metainfo
        self.peerID = peerID
        self.maxActivePeers = maxActivePeers
        self.stopAfterBytes = stopAfterBytes
        self.storage = Storage(directory: directory, metainfo: metainfo)
        self.picker = PiecePicker(pieceCount: metainfo.pieceCount, verified: [Bool](repeating: false, count: metainfo.pieceCount))
        // Seed the broadcast with the restored state (from the resume sidecar) so subscribers
        // don't briefly see a fresh `.downloading 0/N` before run() loads the bitfield.
        let initialVerified = Storage.loadVerifiedCount(
            directory: directory,
            infoHash: metainfo.infoHash,
            pieceCount: metainfo.pieceCount
        )
        self.statusBroadcast = StatusBroadcast(TorrentStatus(
            name: metainfo.name,
            infoHash: metainfo.infoHash,
            state: initialVerified == metainfo.pieceCount ? .seeding : .downloading,
            verifiedCount: initialVerified,
            pieceCount: metainfo.pieceCount,
            peers: 0,
            seeds: 0,
            downloadRate: 0,
            uploadRate: 0,
            downloadedBytes: 0,
            uploadedBytes: 0
        ))
        for url in metainfo.flattenedTrackers {
            if let client = try? TrackerClientFactory.makeClient(for: url) {
                trackerClients.append(client)
            }
        }
    }

    public var verifiedCount: Int { picker.verified.setCount }

    /// Test/dev hook: inject a specific peer address to connect to directly, bypassing trackers.
    public func addPeer(host: String, port: UInt16) {
        considerPeer(PeerAddress(host: host, port: port))
    }

    public func run() async {
        guard !isRunning else { return }
        isRunning = true

        try? await storage.prepare()
        try? await storage.loadVerified()
        picker = PiecePicker(pieceCount: metainfo.pieceCount, verified: await storage.verifiedBitfield)

        announceTask = Task { [weak self] in
            await self?.announceLoop()
        }
        dhtTask = Task { [weak self] in
            await self?.dhtLoop()
        }
        startListener()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tick()
            }
        }
        await publishStatus()

        while !Task.isCancelled {
            if picker.verified.allSet { break }
            if let stopAfter = stopAfterBytes {
                let verifiedBytes = picker.verified.setCount * metainfo.pieceLength
                if verifiedBytes >= stopAfter { break }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        announceTask?.cancel()
        tickerTask?.cancel()
        dhtTask?.cancel()
        disconnectAllPeers()
        try? await storage.saveVerified()
        let _ = await announceAll(event: picker.verified.allSet ? .completed : .none)
        let _ = await announceAll(event: .stopped)
        await storage.close()
        isRunning = false
    }

    public func stop() async {
        announceTask?.cancel()
        tickerTask?.cancel()
        dhtTask?.cancel()
        listener?.close()
        listenerThread?.cancel()
        disconnectAllPeers()
        let _ = await announceAll(event: .stopped)
        try? await storage.saveVerified()
        await storage.close()
        isRunning = false
    }

    // MARK: - Peer coordination (called by PeerSession)

    func nextBlockRequest(for peer: PeerSession) async -> Block? {
        guard !bannedPeers.contains(peer.id) else { return nil }
        // Prefer an active piece with remaining blocks, lowest index first.
        let sortedActive = activePieces.sorted()
        for piece in sortedActive {
            if let block = nextBlock(in: piece) {
                registerOutstanding(block, peer: peer)
                return block
            }
        }
        guard let piece = picker.nextPiece() else { return nil }
        picker.markRequested(piece)
        activePieces.insert(piece)
        receivedBlocks[piece] = []
        pieceBlockCursor[piece] = 0
        if let block = nextBlock(in: piece) {
            registerOutstanding(block, peer: peer)
            return block
        }
        return nil
    }

    private func nextBlock(in piece: Int) -> Block? {
        let pieceLength = self.pieceLength(piece)
        guard let cursor = pieceBlockCursor[piece], cursor < pieceLength else { return nil }
        let length = min(PeerMessage.blockSize, pieceLength - cursor)
        pieceBlockCursor[piece] = cursor + length
        return Block(index: piece, begin: cursor, length: length)
    }

    private func registerOutstanding(_ block: Block, peer: PeerSession) {
        let key = BlockKey(index: block.index, begin: block.begin)
        outstanding[key] = peer.id
        blockSenders[key] = peer.id
    }

    func receivedBlock(_ block: Block, data: Data, from peer: PeerSession) async {
        guard activePieces.contains(block.index) else { return }
        outstanding.removeValue(forKey: BlockKey(index: block.index, begin: block.begin))

        var blocks = receivedBlocks[block.index] ?? []
        let isNew = blocks.insert(block.begin).inserted
        receivedBlocks[block.index] = blocks
        guard isNew else { return } // duplicate block

        downloadedBytes += Int64(data.count)
        do {
            try await storage.writeBlock(piece: block.index, offset: block.begin, data: data)
        } catch {
            requeuePiece(block.index)
            await publishStatus()
            return
        }

        let needed = neededBlockCount(block.index)
        guard blocks.count >= needed else { return }
        do {
            if try await storage.verify(piece: block.index) {
                await completePiece(block.index)
                TorrentLog.log("piece \(block.index) verified (\(picker.verified.setCount)/\(metainfo.pieceCount))")
            } else {
                TorrentLog.log("piece \(block.index) VERIFY FAILED (attempt \(pieceFailures[block.index] ?? 0 + 1)); banning its senders")
                await requeueAfterFailure(block.index)
            }
        } catch {
            requeuePiece(block.index)
        }
        await publishStatus()
    }

    private func requeueAfterFailure(_ piece: Int) async {
        let failures = (pieceFailures[piece] ?? 0) + 1
        pieceFailures[piece] = failures
        if failures >= maxPieceFailures {
            TorrentLog.log("piece \(piece) failed \(failures) times; giving up")
            requeuePiece(piece)
            return
        }
        let senders = Set(blockSenders.filter { $0.key.index == piece }.values)
        for id in senders {
            let count = (peerFailures[id] ?? 0) + 1
            peerFailures[id] = count
            // Only ban repeat offenders so a single bad block doesn't disconnect good peers.
            if count >= 2 {
                bannedPeers.insert(id)
                if let session = peerSessions.removeValue(forKey: id) {
                    activePeerIDs.remove(id)
                    session.disconnect()
                }
                TorrentLog.log("banning peer \(id) after \(count) piece failures")
            }
        }
        requeuePiece(piece)
    }

    func peerDisconnected(_ peer: PeerSession) async {
        activePeerIDs.remove(peer.id)
        peerSessions.removeValue(forKey: peer.id)
        pendingPeerAddresses.remove(peer.address)
        // Re-request any blocks that peer had outstanding.
        for (key, owner) in outstanding where owner == peer.id {
            outstanding.removeValue(forKey: key)
            blockSenders.removeValue(forKey: key)
            if let cursor = pieceBlockCursor[key.index] {
                pieceBlockCursor[key.index] = min(cursor, key.begin)
            }
        }
        await publishStatus()
    }

    func readVerifiedPiece(piece: Int, offset: Int, length: Int) async -> Data? {
        guard picker.verified[piece] else { return nil }
        guard offset >= 0, offset + length <= pieceLength(piece) else { return nil }
        guard let data = try? await storage.read(piece: piece, offset: offset, length: length) else { return nil }
        uploadedBytes += Int64(data.count)
        return data
    }

    private func completePiece(_ piece: Int) async {
        picker.markVerified(piece)
        await storage.markVerified(piece)
        activePieces.remove(piece)
        receivedBlocks.removeValue(forKey: piece)
        pieceBlockCursor.removeValue(forKey: piece)
        pieceFailures.removeValue(forKey: piece)
        for key in outstanding.keys where key.index == piece {
            outstanding.removeValue(forKey: key)
            blockSenders.removeValue(forKey: key)
        }
        verifiedDirty = true
        // Persist completion the moment it's reached, so a relaunch never shows a finished
        // torrent as downloading again (the end-of-run save below runs after slow announces).
        if picker.verified.allSet {
            try? await storage.saveVerified()
            verifiedDirty = false
        }
    }

    private func requeuePiece(_ piece: Int) {
        picker.clearRequested(piece)
        activePieces.remove(piece)
        receivedBlocks.removeValue(forKey: piece)
        pieceBlockCursor.removeValue(forKey: piece)
        for key in outstanding.keys where key.index == piece {
            outstanding.removeValue(forKey: key)
            blockSenders.removeValue(forKey: key)
        }
    }

    private func neededBlockCount(_ piece: Int) -> Int {
        (pieceLength(piece) + PeerMessage.blockSize - 1) / PeerMessage.blockSize
    }

    private func pieceLength(_ piece: Int) -> Int {
        let start = piece * metainfo.pieceLength
        return min(metainfo.pieceLength, metainfo.totalLength - start)
    }

    // MARK: - Tracker announce

    private func announceLoop() async {
        while !Task.isCancelled {
            let event: AnnounceEvent = firstAnnounce ? .started : .none
            firstAnnounce = false
            let interval = await announceAll(event: event)
            // Trackers suggest a long interval, but re-announce often to keep the peer pool
            // fresh (dead peers drop quickly). Cap between 60 and 90s.
            let sleep = min(max(interval, 60), 90)
            try? await Task.sleep(for: .seconds(sleep))
        }
    }

    /// Periodically queries the DHT for new peers; the tracker pool is mostly NAT'd peers, but
    /// DHT returns live, reachable ones (mirrors webtorrent's discovery sources).
    private func dhtLoop() async {
        while !Task.isCancelled {
            do {
                let dht = try DHTClient()
                let start = ContinuousClock.now
                if let dhtPeers = try? await dht.lookup(infoHash: metainfo.infoHash, timeout: 10) {
                    TorrentLog.log("DHT: found \(dhtPeers.count) peers in \(ContinuousClock.now - start)")
                    for peer in dhtPeers {
                        considerPeer(peer)
                    }
                }
                dht.stop()
            } catch {
                // DHT is best-effort; skip and retry later.
            }
            try? await Task.sleep(for: .seconds(120))
        }
    }

    private func announceAll(event: AnnounceEvent) async -> Int {
        let left = metainfo.totalLength - picker.verified.setCount * metainfo.pieceLength
        let request = AnnounceRequest(
            infoHash: metainfo.infoHash,
            peerID: peerID,
            port: listenPort,
            uploaded: uploadedBytes,
            downloaded: downloadedBytes,
            left: Int64(left),
            event: event,
            numWant: 80,
            key: Int32.random(in: .min ... .max)
        )
        var maxInterval = 0
        var seeds = 0
        var peerCount = 0
        await withTaskGroup(of: (Int, [PeerAddress], Int).self) { group in
            for client in trackerClients {
                group.addTask {
                    do {
                        let response = try await client.announce(request)
                        TorrentLog.log("announce \(event) ok: \(response.peers.count) peers, interval \(response.interval)")
                        return (response.interval, response.peers, response.seeders ?? 0)
                    } catch {
                        TorrentLog.log("announce \(event) failed: \(error)")
                        return (0, [], 0)
                    }
                }
            }
            for await (interval, peers, seeders) in group {
                maxInterval = max(maxInterval, interval)
                seeds = max(seeds, seeders)
                peerCount += peers.count
                for peer in peers {
                    self.considerPeer(peer)
                }
            }
        }
        lastSeeders = seeds
        TorrentLog.log("announce cycle complete: \(peerCount) total peers")
        await publishStatus()
        return maxInterval
    }

    private func considerPeer(_ address: PeerAddress) {
        guard pendingPeerAddresses.count + activePeerIDs.count < maxActivePeers else { return }
        guard !pendingPeerAddresses.contains(address) else { return }
        pendingPeerAddresses.insert(address)
        TorrentLog.log("connecting to \(address.host):\(address.port)")
        let torrent = self
        Task {
            await torrent.runPeerConnection(to: address)
        }
    }

    private func runPeerConnection(to address: PeerAddress) async {
        defer {
            pendingPeerAddresses.remove(address)
        }
        do {
            let stream = try PeerStream(host: address.host, port: address.port)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await stream.connect() }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    stream.close()
                    throw PeerStreamError.timeout
                }
                _ = try await group.next()
                group.cancelAll()
            }
            let session = PeerSession(
                torrent: self,
                address: address,
                infoHash: metainfo.infoHash,
                peerID: peerID,
                stream: stream,
                isInitiator: true
            )
            activePeerIDs.insert(session.id)
            peerSessions[session.id] = session
            TorrentLog.log("connected to \(address.host):\(address.port)")
            await session.run()
            TorrentLog.log("peer session ended \(address.host):\(address.port)")
        } catch {
            TorrentLog.log("connect to \(address.host):\(address.port) failed: \(error)")
        }
        await publishStatus()
    }

    // MARK: - Inbound listener

    private func startListener() {
        do {
            let listener = try TCPListener(port: 0)
            self.listener = listener
            listenPort = listener.port
            TorrentLog.log("listening on port \(listenPort)")
            let thread = Thread { [weak self] in
                guard let self else { return }
                while !Thread.current.isCancelled {
                    guard let fd = try? listener.accept() else { break }
                    let stream = PeerStream(fd: fd)
                    stream.start()
                    let torrent = self
                    Task {
                        await torrent.runAccepted(stream)
                    }
                }
            }
            thread.name = "stupid-torrent.listener"
            listenerThread = thread
            thread.start()
        } catch {
            TorrentLog.log("listener failed: \(error)")
            listenPort = 0
        }
    }

    private func runAccepted(_ stream: PeerStream) async {
        guard activePeerIDs.count < maxActivePeers else {
            stream.close()
            return
        }
        let session = PeerSession(
            torrent: self,
            address: PeerAddress(host: "incoming", port: 0),
            infoHash: metainfo.infoHash,
            peerID: peerID,
            stream: stream,
            isInitiator: false
        )
        activePeerIDs.insert(session.id)
        peerSessions[session.id] = session
        await session.run()
    }

    // MARK: - Status

    private func disconnectAllPeers() {
        for session in peerSessions.values {
            session.disconnect()
        }
        peerSessions.removeAll()
        activePeerIDs.removeAll()
    }

    private func tick() async {
        downloadRate = Double(downloadedBytes - lastTickDownloaded)
        uploadRate = Double(uploadedBytes - lastTickUploaded)
        lastTickDownloaded = downloadedBytes
        lastTickUploaded = uploadedBytes
        if verifiedDirty {
            verifiedDirty = false
            try? await storage.saveVerified()
        }
        await publishStatus()
    }

    private func publishStatus() async {
        let state: TorrentStatus.State = picker.verified.allSet ? .seeding : .downloading
        let status = TorrentStatus(
            name: metainfo.name,
            infoHash: metainfo.infoHash,
            state: state,
            verifiedCount: picker.verified.setCount,
            pieceCount: metainfo.pieceCount,
            peers: activePeerIDs.count,
            seeds: lastSeeders,
            downloadRate: downloadRate,
            uploadRate: uploadRate,
            downloadedBytes: downloadedBytes,
            uploadedBytes: uploadedBytes
        )
        await statusBroadcast.publish(status)
    }
}

private struct BlockKey: Hashable {
    let index: Int
    let begin: Int
}
