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
    /// DHT (BEP 5) peer discovery is best-effort; off for hermetic tests that must not touch the
    /// network beyond loopback.
    private let enableDHT: Bool

    var picker: PiecePicker
    private var receivedBlocks: [Int: Set<Int>] = [:]
    /// Total distinct bytes received per piece. Some peers coalesce a piece's final (short) block
    /// into the last full block, so per-offset block counting can never reach the needed count even
    /// though the data is complete on disk — byte coverage is the reliable completion signal.
    private var pieceReceivedBytes: [Int: Int] = [:]
    private var pieceBlockCursor: [Int: Int] = [:]
    private var activePieces: Set<Int> = []
    private var outstanding: [BlockKey: UUID] = [:]
    private var blockSenders: [BlockKey: UUID] = [:]
    private var pieceFailures: [Int: Int] = [:]
    private let maxPieceFailures = 5
    /// When each active piece last received a block. Pieces that stop making progress are
    /// requeued (stall detection) so their never-arriving blocks get re-requested.
    private var pieceLastProgress: [Int: ContinuousClock.Instant] = [:]
    private let stallTimeout = Duration.seconds(20)

    private var activePeerIDs: Set<UUID> = []
    private var peerSessions: [UUID: PeerSession] = [:]
    private var bannedPeers: Set<UUID> = []
    private var peerFailures: [UUID: Int] = [:]
    /// Peers currently in a connect attempt (socket dialing/handshaking). Removed once the
    /// connection is established, so `pendingPeerAddresses.count + activePeerIDs.count` counts
    /// connecting + connected exactly (mirrors webtorrent's `_numPending + _numConns`).
    private var pendingPeerAddresses: Set<PeerAddress> = []
    /// FIFO of discovered-but-unconnected peers. `drainPeerPool()` pops from this and dials while
    /// the pool has room; slots freed by a disconnect are refilled immediately (mirrors
    /// webtorrent's `_queue` + `_drain()`).
    private var peerQueue: [PeerAddress] = []
    private var queuedPeerAddresses: Set<PeerAddress> = []
    /// Reconnect backoff per address: [1s, 5s, 15s] (mirrors webtorrent's RECONNECT_WAIT).
    private var connectAttempts: [PeerAddress: Int] = [:]
    private let maxReconnectAttempts = 3
    private var trackerClients: [any TrackerClient] = []

    private var listener: TCPListener?
    private var listenerThread: Thread?
    private var listenPort: UInt16 = 0
    private var utpTransport: UTPTransport?
    /// Transports replaced by the listener's bound transport (pre-listener injected peers); stopped
    /// on `stop()` so their sockets/tasks don't leak.
    private var retiredUTPTransports: [UTPTransport] = []

    private var announceTask: Task<Void, Never>?
    private var dhtTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var isRunning = false
    /// Whether the download is paused. `pause()` tears down the network immediately and parks
    /// `run()`'s loop; `resume()` clears the flag and the loop restarts the machinery.
    private var isPaused = false
    /// Whether the announce/DHT/listener/ticker machinery has been started in the current run
    /// cycle. A torrent that never started networking (paused at entry, or completed) must not
    /// announce `.stopped` on teardown.
    private var networkStarted = false
    private var firstAnnounce = true
    private var verifiedDirty = false

    private var downloadedBytes: Int64 = 0
    private var uploadedBytes: Int64 = 0
    private var lastTickDownloaded: Int64 = 0
    private var lastTickUploaded: Int64 = 0
    private var downloadRate: Double = 0
    private var uploadRate: Double = 0
    private var lastSeeders = 0
    /// Last published status snapshot; `publishStatus()` skips publishing when nothing changed so
    /// the 1s ticker doesn't churn SwiftUI observers (which visibly pulses toolbar/menu items).
    private var lastPublishedStatus: TorrentStatus?

    public init(directory: URL, metainfo: Metainfo, peerID: Data = PeerID.generate(), maxActivePeers: Int = 50, stopAfterBytes: Int64? = nil, enableDHT: Bool = true, startPaused: Bool = false) {
        self.directory = directory
        self.metainfo = metainfo
        self.peerID = peerID
        self.maxActivePeers = maxActivePeers
        self.stopAfterBytes = stopAfterBytes
        self.enableDHT = enableDHT
        self.isPaused = startPaused
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

    /// Whether the run loop is active (including while parked by a pause).
    public var running: Bool { isRunning }

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

        // A torrent that is already complete has nothing to do on the network: no announce, no DHT
        // peer lookup, no listener, no seeding. It just sits there so the user can access and
        // stream the downloaded files. (Streaming reads reopen file handles on demand, so we don't
        // close storage here — `stop()` closes it on removal.)
        if picker.verified.allSet && !isPaused {
            await publishStatus()
            isRunning = false
            return
        }

        if !isPaused {
            await startNetworkMachinery()
        }
        // A torrent restored into the paused state (or paused between the flag read and here) must
        // publish that immediately so subscribers reflect it instead of a stale `.downloading`.
        await publishStatus()

        while !Task.isCancelled {
            // Park while paused; `resume()` flips the flag and the loop restarts the machinery.
            if isPaused {
                // A pause can interleave with a machinery start (actor reentrancy at an await), so
                // the machinery may already be up when we notice the flag — tear it down before
                // parking so nothing runs while paused.
                if networkStarted {
                    await stopNetwork()
                }
                while isPaused && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if Task.isCancelled { break }
                await startNetworkMachinery()
                continue
            }
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
        if networkStarted {
            let _ = await announceAll(event: picker.verified.allSet ? .completed : .none)
            let _ = await announceAll(event: .stopped)
        }
        await storage.close()
        isRunning = false
    }

    /// Starts the announce loop, DHT lookup loop, inbound listener, and ticker. Called at the start
    /// of `run()` and again each time the download resumes from a pause.
    private func startNetworkMachinery() async {
        guard !isPaused else { return }
        networkStarted = true
        announceTask = Task { [weak self] in
            await self?.announceLoop()
        }
        if enableDHT {
            dhtTask = Task { [weak self] in
                await self?.dhtLoop()
            }
        }
        await startListener()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tick()
            }
        }
        await publishStatus()
    }

    /// Tears down the download machinery: announce/DHT/ticker tasks cancelled, listener and µTP
    /// closed, peer queue cleared, all peers disconnected. Leaves the verified bitfield and storage
    /// intact (streaming still works for downloaded pieces). Used by `pause()` and by `run()`'s
    /// parked loop when a pause interleaved with a machinery start.
    private func stopNetwork() async {
        announceTask?.cancel()
        dhtTask?.cancel()
        tickerTask?.cancel()
        listener?.close()
        listenerThread?.cancel()
        await utpTransport?.stop()
        for transport in retiredUTPTransports {
            await transport.stop()
        }
        retiredUTPTransports.removeAll()
        peerQueue.removeAll()
        queuedPeerAddresses.removeAll()
        connectAttempts.removeAll()
        disconnectAllPeers()
        networkStarted = false
    }

    /// Pauses the download: tears the network down immediately (peers disconnected, listener and
    /// µTP closed, announce/DHT/ticker stopped, bitfield flushed) and publishes `.paused`. `run()`
    /// parks until `resume()`. Storage stays open so streaming still works for downloaded pieces.
    public func pause() async {
        guard isRunning, !isPaused else { return }
        isPaused = true
        await stopNetwork()
        try? await storage.saveVerified()
        let _ = await announceAll(event: .stopped)
        await publishStatus()
    }

    /// Resumes a paused download. `run()`'s parked loop notices the flag and restarts the network
    /// machinery (re-announcing `.started` so the tracker picks us up again).
    public func resume() async {
        guard isRunning, isPaused else { return }
        isPaused = false
        firstAnnounce = true
        await publishStatus()
    }

    public func stop() async {
        isPaused = false
        await stopNetwork()
        let _ = await announceAll(event: .stopped)
        try? await storage.saveVerified()
        await storage.close()
        isRunning = false
    }

    // MARK: - Peer coordination (called by PeerSession)

    func nextBlockRequest(for peer: PeerSession) async -> Block? {
        guard !bannedPeers.contains(peer.id) else { return nil }
        // Prefer an active piece with remaining blocks, lowest index first. Only request blocks
        // for pieces the peer claims to have (its bitfield/have messages); a peer without the
        // piece can never serve it, so requesting is wasted round-trips.
        let sortedActive = activePieces.sorted()
        for piece in sortedActive {
            if peer.hasPiece(piece), let block = nextBlock(in: piece) {
                registerOutstanding(block, peer: peer)
                return block
            }
        }
        guard let piece = picker.nextPiece(available: { peer.hasPiece($0) }) else {
            TorrentLog.log("nextBlockRequest[\(metainfo.name)]: picker empty (active=\(activePieces.count) verified=\(picker.verified.setCount)/\(metainfo.pieceCount) requested=\(picker.requested.setCount) cursor=\(picker.cursor))")
            return nil
        }
        picker.markRequested(piece)
        activePieces.insert(piece)
        // Keep progress already made on a piece that was requeued after a stall (don't wipe the
        // blocks we've already received); only a brand-new piece starts from scratch.
        if receivedBlocks[piece] == nil { receivedBlocks[piece] = [] }
        if pieceReceivedBytes[piece] == nil { pieceReceivedBytes[piece] = 0 }
        if pieceBlockCursor[piece] == nil { pieceBlockCursor[piece] = 0 }
        if let block = nextBlock(in: piece) {
            registerOutstanding(block, peer: peer)
            return block
        }
        return nil
    }

    private func nextBlock(in piece: Int) -> Block? {
        let pieceLength = self.pieceLength(piece)
        guard let cursor = pieceBlockCursor[piece] else { return nil }
        if cursor < pieceLength {
            let length = min(PeerMessage.blockSize, pieceLength - cursor)
            pieceBlockCursor[piece] = cursor + length
            return Block(index: piece, begin: cursor, length: length)
        }
        // The cursor is exhausted (every block was allocated once) but the piece is still missing
        // blocks — the peers they were handed to never delivered them. Re-request the next missing
        // block immediately (endgame-style) instead of waiting for the 20s stall timer, so a
        // near-complete piece finishes in one round-trip rather than stalling the download.
        let received = receivedBlocks[piece] ?? []
        guard received.count < neededBlockCount(piece) else { return nil }
        let missing = nextMissingOffset(piece)
        guard !received.contains(missing) else { return nil }
        return Block(index: piece, begin: missing, length: min(PeerMessage.blockSize, pieceLength - missing))
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
        pieceLastProgress[block.index] = ContinuousClock.now
        let receivedBytes = (pieceReceivedBytes[block.index] ?? 0) + data.count
        pieceReceivedBytes[block.index] = receivedBytes
        do {
            try await storage.writeBlock(piece: block.index, offset: block.begin, data: data)
        } catch {
            requeuePiece(block.index)
            await publishStatus()
            return
        }

        // Completion is signalled by byte coverage, not block count: a peer may coalesce the
        // piece's final short block into the last full block, so the offset set can fall one short
        // of `needed` while all bytes are present. SHA-1 verify is the real gate.
        guard receivedBytes >= pieceLength(block.index) else { return }
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
        // A freed slot should immediately pull the next queued peer (webtorrent's `_drain` runs on
        // every `removePeer`), so the pool stays full instead of waiting for the next announce.
        drainPeerPool()
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
        pieceReceivedBytes.removeValue(forKey: piece)
        pieceBlockCursor.removeValue(forKey: piece)
        pieceFailures.removeValue(forKey: piece)
        pieceLastProgress.removeValue(forKey: piece)
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
        pieceReceivedBytes.removeValue(forKey: piece)
        pieceBlockCursor.removeValue(forKey: piece)
        pieceLastProgress.removeValue(forKey: piece)
        for key in outstanding.keys where key.index == piece {
            outstanding.removeValue(forKey: key)
            blockSenders.removeValue(forKey: key)
        }
    }

    /// Stall detection: an active piece that stops receiving blocks (its remaining blocks were
    /// allocated once but the peer never delivered them) is requeued so the missing blocks get
    /// re-requested — possibly from a different peer. Keeps already-received blocks.
    private func requeueStalledPiece(_ piece: Int) {
        // Keep the piece ACTIVE (don't clearRequested/remove from activePieces): the sequential
        // picker's cursor has moved past it, so un-requesting it would let the last ~N blocks of a
        // near-complete piece sit unrequested forever. Staying active means the next peer refill
        // serves its missing blocks immediately, while the stall timer still bounds a dead piece.
        // Keep receivedBlocks AND pieceReceivedBytes: a requeued piece re-requests only its
        // missing blocks, and duplicates of already-received blocks are discarded, so resetting
        // the byte counter here would make the piece never reach receivedBytes >= pieceLength
        // (already-received bytes would never be re-counted) — it would verify-loop forever.
        pieceBlockCursor[piece] = nextMissingOffset(piece)
        pieceLastProgress.removeValue(forKey: piece)
        for key in outstanding.keys where key.index == piece {
            outstanding.removeValue(forKey: key)
            blockSenders.removeValue(forKey: key)
        }
    }

    /// The next block offset of `piece` not yet received (its cursor resets here after a stall).
    private func nextMissingOffset(_ piece: Int) -> Int {
        let count = neededBlockCount(piece)
        let received = receivedBlocks[piece] ?? []
        for index in 0..<count {
            let offset = index * PeerMessage.blockSize
            if !received.contains(offset) { return offset }
        }
        return 0
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

    /// Periodically queries the DHT for new peers and announces our listen port (BEP 5). Uses the
    /// app-lifetime shared node (`DHTNode`) so all torrents participate as ONE stable DHT node —
    /// a persistent identity and socket is what accumulates a live peer store and a real position
    /// in the DHT (mirrors webtorrent's long-running node).
    private func dhtLoop() async {
        while !Task.isCancelled {
            guard let dht = DHTNode.shared() else {
                try? await Task.sleep(for: .seconds(120))
                continue
            }
            let start = ContinuousClock.now
            if let dhtPeers = try? await dht.lookup(infoHash: metainfo.infoHash, timeout: 10) {
                TorrentLog.log("DHT: found \(dhtPeers.count) peers in \(ContinuousClock.now - start)")
                for peer in dhtPeers {
                    considerPeer(peer)
                }
            }
            try? await dht.announce(infoHash: metainfo.infoHash, port: listenPort)
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

    /// Adds a peer address to the connection queue and drains the pool. The pool is always kept
    /// at/near `maxActivePeers`: every queue add and every freed slot triggers a drain, so the
    /// client stays connected to as many live peers as possible (mirrors webtorrent's `_drain`).
    private func considerPeer(_ address: PeerAddress) {
        guard !isPaused else { return }
        guard !bannedPeers.contains(where: { peerSessions[$0]?.address == address }) else { return }
        guard !pendingPeerAddresses.contains(address),
              !queuedPeerAddresses.contains(address),
              !activePeerIDs.contains(where: { peerSessions[$0]?.address == address }) else { return }
        peerQueue.append(address)
        queuedPeerAddresses.insert(address)
        drainPeerPool()
    }

    private func drainPeerPool() {
        guard !isPaused else { return }
        while pendingPeerAddresses.count + activePeerIDs.count < maxActivePeers, !peerQueue.isEmpty {
            let address = peerQueue.removeFirst()
            queuedPeerAddresses.remove(address)
            pendingPeerAddresses.insert(address)
            TorrentLog.log("connecting to \(address.host):\(address.port)")
            let torrent = self
            Task {
                await torrent.runPeerConnection(to: address)
            }
        }
    }

    private func runPeerConnection(to address: PeerAddress) async {
        // µTP first (reaches µTP-only peers — webtorrent's advantage on swarms like The Odyssey),
        // then TCP. A µTP session that stalls before the BT handshake falls through to TCP.
        let utpHandshake = await connectUTP(to: address)
        let tcpHandshake = utpHandshake ? false : await connectTCP(to: address)
        // One reconnect schedule per address per attempt cycle (both transports tried). A peer that
        // handshaked is real — reset its budget (webtorrent resets `retries` on handshake) so it
        // gets fresh reconnect attempts when it drops.
        if utpHandshake || tcpHandshake {
            connectAttempts.removeValue(forKey: address)
        }
        scheduleReconnect(address)
        await publishStatus()
    }

    /// Re-queues a peer that dropped or failed to connect, with exponential backoff, so the pool
    /// keeps cycling candidates like webtorrent's `RECONNECT_WAIT`. Injected/manual peers and
    /// already-queued/pending ones are not re-queued (avoids duplicate attempts).
    private func scheduleReconnect(_ address: PeerAddress) {
        guard isRunning, !isPaused else { return }
        let attempts = connectAttempts[address] ?? 0
        guard attempts < maxReconnectAttempts else {
            connectAttempts.removeValue(forKey: address)
            return
        }
        connectAttempts[address] = attempts + 1
        let backoff = [1.0, 5.0, 15.0][attempts]
        guard !pendingPeerAddresses.contains(address), !queuedPeerAddresses.contains(address) else { return }
        queuedPeerAddresses.insert(address)
        let torrent = self
        Task {
            try? await Task.sleep(for: .seconds(backoff))
            await torrent.flushReconnect(address)
        }
    }

    /// Called by the reconnect timer: moves a backoff-queued peer back into the connection queue
    /// and drains the pool (webtorrent's `conn.on('close')` → `_addPeer` + `_drain`).
    private func flushReconnect(_ address: PeerAddress) {
        guard isRunning, !isPaused else { return }
        guard queuedPeerAddresses.remove(address) != nil else { return }
        peerQueue.append(address)
        drainPeerPool()
    }

    private func connectUTP(to address: PeerAddress) async -> Bool {
        let transport: UTPTransport?
        if let existing = utpTransport {
            transport = existing
        } else {
            transport = await ensureUTPTransport()
        }
        guard let transport else { return false }
        let connection = await transport.connect(to: address)
        do {
            try await connection.startAsInitiator(timeout: .seconds(2))
            let stream = UTPStream(connection: connection)
            let session = PeerSession(
                torrent: self,
                address: address,
                infoHash: metainfo.infoHash,
                peerID: peerID,
                stream: stream,
                isInitiator: true,
                supportsMSE: false,
                pieceCount: metainfo.pieceCount
            )
            // Connection established: free the pending slot before the (blocking) session runs, so
            // `pending + active` counts connecting + connected exactly, not double.
            pendingPeerAddresses.remove(address)
            activePeerIDs.insert(session.id)
            peerSessions[session.id] = session
            TorrentLog.log("µTP connected to \(address.host):\(address.port)")
            await session.run(handshakeBudget: .seconds(6))
            return session.completedHandshake
        } catch {
            TorrentLog.log("µTP connect to \(address.host):\(address.port) failed: \(error)")
            await connection.unregister()
            pendingPeerAddresses.remove(address)
            return false
        }
    }

    /// Creates an outbound-only µTP transport when the listener hasn't started yet (injected peers
    /// can be considered before `run()` calls `startListener()`). The listener's transport (with
    /// inbound accept) replaces this one once started.
    private func ensureUTPTransport() async -> UTPTransport? {
        guard utpTransport == nil else { return utpTransport }
        do {
            let udp = try UDPSocket()
            let transport = UTPTransport(socket: udp)
            await transport.start()
            utpTransport = transport
            return transport
        } catch {
            TorrentLog.log("µTP transport failed: \(error)")
            return nil
        }
    }

    private func connectTCP(to address: PeerAddress) async -> Bool {
        do {
            let stream = try PeerStream(host: address.host, port: address.port)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await stream.connect(timeout: 5) }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
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
                isInitiator: true,
                pieceCount: metainfo.pieceCount
            )
            pendingPeerAddresses.remove(address)
            activePeerIDs.insert(session.id)
            peerSessions[session.id] = session
            TorrentLog.log("connected to \(address.host):\(address.port)")
            await session.run()
            TorrentLog.log("peer session ended \(address.host):\(address.port)")
            return session.completedHandshake
        } catch {
            pendingPeerAddresses.remove(address)
            TorrentLog.log("connect to \(address.host):\(address.port) failed: \(error)")
            return false
        }
    }

    // MARK: - Inbound listener

    private func startListener() async {
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

            // µTP (BEP 29) on the same announced port: peers can reach us over UDP as well as TCP.
            // Accepts create plaintext BitTorrent sessions (µTP is its own transport). If binding
            // to the announced port fails, keep an unbound transport so outbound µTP still works.
            let udp = try UDPSocket()
            var inbound = false
            if (try? udp.bind(port: listenPort)) != nil {
                inbound = true
            }
            let transport = UTPTransport(socket: udp) { [weak self] connection, remote in
                guard let self else { return }
                await self.runAcceptedUTP(connection, remote: remote)
            }
            await transport.start()
            if let previous = utpTransport {
                retiredUTPTransports.append(previous)
            }
            utpTransport = transport
            TorrentLog.log(inbound ? "µTP listening on port \(listenPort)" : "µTP outbound only (bind to \(listenPort) failed)")
        } catch {
            TorrentLog.log("listener failed: \(error)")
            listenPort = 0
        }
    }

    private func runAcceptedUTP(_ connection: UTPConnection, remote: PeerAddress) async {
        guard activePeerIDs.count < maxActivePeers else {
            await connection.close()
            return
        }
        let stream = UTPStream(connection: connection)
        let session = PeerSession(
            torrent: self,
            address: remote,
            infoHash: metainfo.infoHash,
            peerID: peerID,
            stream: stream,
            isInitiator: false,
            supportsMSE: false,
            pieceCount: metainfo.pieceCount
        )
        activePeerIDs.insert(session.id)
        peerSessions[session.id] = session
        await session.run()
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
            isInitiator: false,
            pieceCount: metainfo.pieceCount
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
        requeueStalledPieces()
        if verifiedDirty {
            verifiedDirty = false
            try? await storage.saveVerified()
        }
        await publishStatus()
    }

    /// Requeues active pieces that haven't received a block recently — their remaining blocks
    /// were allocated once but the peer never delivered them, so without this the piece never
    /// completes (the classic "blocks written but nothing verifies" stall).
    private func requeueStalledPieces() {
        let now = ContinuousClock.now
        for piece in activePieces {
            guard let lastProgress = pieceLastProgress[piece] else {
                pieceLastProgress[piece] = now
                continue
            }
            if now - lastProgress >= stallTimeout {
                TorrentLog.log("piece \(piece) stalled (\(now - lastProgress) no progress); requeueing")
                requeueStalledPiece(piece)
            }
        }
    }

    private func publishStatus() async {
        let state: TorrentStatus.State = if isPaused {
            .paused
        } else if picker.verified.allSet {
            .seeding
        } else {
            .downloading
        }
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
        guard status != lastPublishedStatus else { return }
        lastPublishedStatus = status
        await statusBroadcast.publish(status)
    }
}

private struct BlockKey: Hashable {
    let index: Int
    let begin: Int
}
