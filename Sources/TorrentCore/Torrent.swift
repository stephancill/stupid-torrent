import Foundation

actor TorrentStartupGate {
    static let shared = TorrentStartupGate()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

struct PeerLink {
    let address: PeerAddress
    let transport: any PeerTransport
    let outbox: AsyncStream<Data>.Continuation
    var pieces: Bitfield
    var peerChoking = true
    var peerInterested = false
    var amChoking = true
    var lastReceived = ContinuousClock.now

    func send(_ message: PeerMessage) {
        outbox.yield(message.encode())
    }
}

public actor Torrent {
    nonisolated public let metainfo: Metainfo
    nonisolated public let statusBroadcast: StatusBroadcast<TorrentStatus>
    nonisolated public let initialStatus: TorrentStatus

    private let directory: URL
    let storage: Storage
    private let peerID = PeerID.generate()
    private let stopAfterBytes: Int64?
    private let enableDHT: Bool
    private let trackerClients: [any TrackerClient]
    private let maxOutstandingRequests = 48
    private let maxUnchokedPeers = 8
    private let peerIdleTimeout = Duration.seconds(30)
    private let maxServedBlockLength = 128 * 1024

    var scheduler: BlockScheduler
    private var pool = PeerPool(capacity: 50)
    private var links: [UUID: PeerLink] = [:]

    private var listener: TCPListener?
    private var listenPort: UInt16 = 0
    private var utp: UTPTransport?
    private var networkTasks: [Task<Void, Never>] = []

    private var isRunning = false
    private var isPaused: Bool
    private var isStopped = false
    private var resumeLoaded = false
    private var networkStarted = false
    private var networkGeneration = 0
    private var firstAnnounce = true
    private var verifiedDirty = false
    private var wakeWaiter: CheckedContinuation<Void, Never>?
    private var wakePending = false
    var streamingValidatedPieces: Set<Int> = []

    private var downloadedBytes: Int64 = 0
    private var uploadedBytes: Int64 = 0
    private var lastTickDownloaded: Int64 = 0
    private var lastTickUploaded: Int64 = 0
    private var lastRateSampleTime = ContinuousClock.now
    private var downloadRate: Double = 0
    private var uploadRate: Double = 0
    private var lastSeeders = 0
    private var lastPublishedStatus: TorrentStatus?

    public init(directory: URL, metainfo: Metainfo, stopAfterBytes: Int64? = nil, enableDHT: Bool = true, startPaused: Bool = false) {
        self.directory = directory
        self.metainfo = metainfo
        self.stopAfterBytes = stopAfterBytes
        self.enableDHT = enableDHT && !metainfo.isPrivate
        self.isPaused = startPaused
        self.storage = Storage(directory: directory, metainfo: metainfo)
        self.scheduler = BlockScheduler(metainfo: metainfo, verified: Bitfield(count: metainfo.pieceCount))
        self.trackerClients = metainfo.flattenedTrackers.compactMap { try? TrackerClientFactory.makeClient(for: $0) }
        let restored = Storage.loadVerified(directory: directory, metainfo: metainfo)
        let status = TorrentStatus(
            name: metainfo.displayName,
            infoHash: metainfo.infoHash,
            state: restored.allSet ? .complete : .downloading,
            verifiedCount: restored.setCount,
            pieceCount: metainfo.pieceCount,
            peers: 0,
            seeds: 0,
            downloadRate: 0,
            uploadRate: 0,
            downloadedBytes: 0,
            uploadedBytes: 0
        )
        self.initialStatus = status
        self.statusBroadcast = StatusBroadcast(status)
    }

    public var verifiedCount: Int { scheduler.picker.verified.setCount }

    public var running: Bool { isRunning }

    var listeningPort: UInt16 { listenPort }

    public func addPeer(host: String, port: UInt16) {
        considerPeer(PeerAddress(host: host, port: port))
    }

    public func run() async {
        guard !isRunning, !isStopped else { return }
        isRunning = true
        await TorrentStartupGate.shared.acquire()
        guard !Task.isCancelled else {
            await TorrentStartupGate.shared.release()
            isRunning = false
            return
        }
        await loadResumeState()
        await TorrentStartupGate.shared.release()
        await publishStatus()

        repeat {
            while !Task.isCancelled, !isStopped {
                if isPaused {
                    await teardownNetwork(announcing: [.stopped])
                } else if downloadFinished {
                    break
                } else if !networkStarted {
                    await startNetwork()
                }
                await waitForWake()
            }
            await teardownNetwork(announcing: scheduler.picker.verified.allSet ? [.completed, .stopped] : [.stopped])
            await saveVerified()
            await storage.close()
        } while !Task.isCancelled && !isStopped && !downloadFinished
        isRunning = false
        await publishStatus()
    }

    public func pause() async {
        guard isRunning, !isPaused else { return }
        isPaused = true
        wake()
        await teardownNetwork(announcing: [.stopped])
        await saveVerified()
        await publishStatus()
    }

    public func resume() async {
        guard isRunning, isPaused else { return }
        isPaused = false
        wake()
        await publishStatus()
    }

    public func stop() async {
        isStopped = true
        isPaused = false
        wake()
        await teardownNetwork(announcing: [.stopped])
        await saveVerified()
        await storage.close()
    }

    func markPieceVerified(_ piece: Int) {
        scheduler.picker.markVerified(piece)
    }

    func invalidateStaleStreamingPiece(_ piece: Int) async {
        guard scheduler.picker.verified[piece] else { return }
        await unverify(pieces: [piece])
        scheduler.picker.setPriority(piece, level: 10)
        TorrentLog.log("piece \(piece) failed streaming revalidation; cleared stale resume state")
        if isRunning {
            wake()
        } else if !isStopped {
            Task { await self.run() }
        }
    }

    private var downloadFinished: Bool {
        let verified = scheduler.picker.verified
        if verified.allSet { return true }
        guard let stopAfterBytes else { return false }
        return metainfo.verifiedByteCount(pieceCount: verified.setCount) >= stopAfterBytes
    }

    private func wake() {
        if let waiter = wakeWaiter {
            wakeWaiter = nil
            waiter.resume()
        } else {
            wakePending = true
        }
    }

    private func waitForWake() async {
        guard !wakePending else {
            wakePending = false
            return
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { wakeWaiter = $0 }
        } onCancel: {
            Task { await self.wake() }
        }
        wakePending = false
    }

    private func loadResumeState() async {
        do {
            try await storage.prepare()
        } catch {
            TorrentLog.log("storage prepare failed for \(metainfo.name): \(error)")
        }
        let restored = Storage.loadVerified(directory: directory, metainfo: metainfo)
        scheduler = BlockScheduler(metainfo: metainfo, verified: restored)
        resumeLoaded = true
        var stale: [Int] = []
        for piece in restored.setIndices {
            guard !Task.isCancelled else { break }
            if (try? await storage.verify(piece: piece)) != true {
                stale.append(piece)
            }
        }
        guard !stale.isEmpty else { return }
        await unverify(pieces: stale)
        TorrentLog.log("startup re-verify cleared \(stale.count) stale pieces")
    }

    private func unverify(pieces: [Int]) async {
        for piece in pieces {
            scheduler.unverify(piece: piece)
            streamingValidatedPieces.remove(piece)
        }
        await saveVerified()
        await publishStatus()
    }

    private func saveVerified() async {
        guard resumeLoaded else { return }
        verifiedDirty = false
        do {
            try await storage.saveVerified(scheduler.picker.verified)
        } catch {
            TorrentLog.log("saving resume state failed for \(metainfo.name): \(error)")
        }
    }

    private func startNetwork() async {
        networkStarted = true
        networkGeneration += 1
        let generation = networkGeneration
        firstAnnounce = true
        resetTransferRates()
        startListener()
        let utp = makeUTPTransport()
        self.utp = utp
        await utp?.start()
        guard networkStarted, generation == networkGeneration else {
            await utp?.stop()
            return
        }
        networkTasks = [
            Task { await self.announceLoop() },
            Task { await self.tickerLoop() },
        ]
        if enableDHT {
            networkTasks.append(Task { await self.dhtLoop() })
        }
        drainPeerPool()
        await publishStatus()
    }

    private func teardownNetwork(announcing events: [AnnounceEvent]) async {
        guard networkStarted else { return }
        networkStarted = false
        networkTasks.forEach { $0.cancel() }
        networkTasks.removeAll()
        listener?.close()
        listener = nil
        let utp = self.utp
        self.utp = nil
        pool.reset()
        for (id, link) in links {
            link.transport.close()
            link.outbox.finish()
            scheduler.release(peer: id)
        }
        links.removeAll()
        resetTransferRates()
        await publishStatus()
        await utp?.stop()
        for event in events {
            _ = await announceAll(event: event)
        }
    }

    private func startListener() {
        do {
            let listener = try TCPListener(port: 0)
            self.listener = listener
            listenPort = listener.port
            TorrentLog.log("listening on port \(listenPort)")
            BlockingIO.spawn(name: "peer-listener") { [torrent = self] in
                while let accepted = try? listener.acceptPeer() {
                    let stream = PeerStream(fd: accepted.fd)
                    Task { await torrent.acceptInbound(stream, from: accepted.address, encrypted: true) }
                }
            }
        } catch {
            TorrentLog.log("listener failed: \(error)")
            listenPort = 0
        }
    }

    private func makeUTPTransport() -> UTPTransport? {
        do {
            let socket = try UDPSocket()
            if listenPort != 0 {
                do {
                    try socket.bind(port: listenPort)
                } catch {
                    TorrentLog.log("µTP outbound only (bind to \(listenPort) failed: \(error))")
                }
            }
            return UTPTransport(socket: socket) { [weak self] connection, remote in
                await self?.acceptInbound(connection, from: remote, encrypted: false)
            }
        } catch {
            TorrentLog.log("µTP transport failed: \(error)")
            return nil
        }
    }

    private func connector() -> PeerConnector {
        PeerConnector(
            infoHash: metainfo.infoHash,
            peerID: peerID,
            utp: utp,
            connectTimeout: .seconds(5),
            handshakeTimeout: .seconds(6)
        )
    }

    private func acceptInbound(_ transport: any PeerTransport, from address: PeerAddress, encrypted: Bool) async {
        guard networkStarted, links.count + pool.dialing.count < pool.capacity, !pool.banned.contains(address) else {
            transport.close()
            return
        }
        do {
            let connection = try await connector().accept(transport, from: address, encrypted: encrypted)
            await PeerSession(connection: connection, torrent: self).run()
        } catch {
            TorrentLog.log("inbound handshake from \(address.host) failed: \(error)")
        }
    }

    private func considerPeer(_ address: PeerAddress) {
        guard !isPaused else { return }
        pool.enqueue(address, isConnected: links.values.contains { $0.address == address })
        drainPeerPool()
    }

    private func drainPeerPool() {
        guard networkStarted else { return }
        while let address = pool.nextDial(connectedCount: links.count) {
            TorrentLog.log("connecting to \(address.host):\(address.port)")
            Task { await self.dial(address) }
        }
    }

    private func dial(_ address: PeerAddress) async {
        let connection: PeerConnection?
        do {
            connection = try await connector().connect(to: address)
        } catch {
            TorrentLog.log("connect to \(address.host):\(address.port) failed: \(error)")
            connection = nil
        }
        pool.dialEnded(address)
        if let connection {
            TorrentLog.log("connected to \(address.host):\(address.port)")
            await PeerSession(connection: connection, torrent: self).run()
        }
        if networkStarted, let delay = pool.reconnectDelay(for: address, handshook: connection != nil) {
            Task {
                try? await Task.sleep(for: delay)
                self.reconnect(address)
            }
        }
        drainPeerPool()
        await publishStatus()
    }

    private func reconnect(_ address: PeerAddress) {
        guard networkStarted, !isPaused else { return }
        pool.reconnect(address)
        drainPeerPool()
    }

    func register(_ session: PeerSession, outbox: AsyncStream<Data>.Continuation) async -> Bool {
        let address = session.connection.address
        guard networkStarted, !pool.banned.contains(address) else { return false }
        let link = PeerLink(
            address: address,
            transport: session.connection.transport,
            outbox: outbox,
            pieces: Bitfield(count: metainfo.pieceCount)
        )
        links[session.id] = link
        let verified = scheduler.picker.verified
        if verified.setCount > 0 {
            link.send(.bitfield(verified.data()))
        }
        if !verified.allSet {
            link.send(.interested)
        }
        await publishStatus()
        return true
    }

    func unregister(_ id: UUID) async {
        guard let link = links.removeValue(forKey: id) else { return }
        scheduler.release(peer: id)
        if !link.amChoking, let next = links.first(where: { $0.value.amChoking && $0.value.peerInterested })?.key {
            unchokeIfPossible(next)
        }
        drainPeerPool()
        await publishStatus()
    }

    func handle(_ message: PeerMessage?, from id: UUID) async {
        guard links[id] != nil else { return }
        links[id]?.lastReceived = .now
        switch message {
        case nil, .haveNone, .cancel, .port, .extended:
            break
        case .choke:
            links[id]?.peerChoking = true
        case .unchoke:
            links[id]?.peerChoking = false
            requestBlocks(from: id)
        case .interested:
            links[id]?.peerInterested = true
            unchokeIfPossible(id)
        case .notInterested:
            links[id]?.peerInterested = false
        case .have(let piece):
            guard piece >= 0, piece < metainfo.pieceCount else { return }
            links[id]?.pieces[piece] = true
            requestBlocks(from: id)
        case .bitfield(let bits):
            links[id]?.pieces = Bitfield.from(bits, count: metainfo.pieceCount)
            requestBlocks(from: id)
        case .haveAll:
            links[id]?.pieces = Bitfield(bits: Array(repeating: true, count: metainfo.pieceCount))
            requestBlocks(from: id)
        case .request(let block):
            await serve(block, to: id)
        case .piece(let block, let data):
            await receive(block, data: data, from: id)
            requestBlocks(from: id)
        }
    }

    private func requestBlocks(from id: UUID) {
        guard let link = links[id], !link.peerChoking else { return }
        var batch = Data()
        let now = ContinuousClock.now
        while scheduler.inFlightCount(for: id) < maxOutstandingRequests,
              let block = scheduler.nextRequest(for: id, has: { link.pieces[$0] }, now: now) {
            batch.append(PeerMessage.request(block).encode())
        }
        guard !batch.isEmpty else { return }
        link.outbox.yield(batch)
    }

    private func unchokeIfPossible(_ id: UUID) {
        guard let link = links[id], link.amChoking, link.peerInterested,
              links.values.count(where: { !$0.amChoking }) < maxUnchokedPeers else { return }
        links[id]?.amChoking = false
        link.send(.unchoke)
    }

    private func serve(_ block: Block, to id: UUID) async {
        guard let link = links[id], !link.amChoking,
              block.index >= 0, block.index < metainfo.pieceCount, scheduler.picker.verified[block.index],
              block.length > 0, block.length <= maxServedBlockLength, block.begin >= 0,
              block.begin + block.length <= metainfo.length(ofPiece: block.index) else { return }
        guard let data = try? await storage.read(piece: block.index, offset: block.begin, length: block.length),
              links[id] != nil else { return }
        uploadedBytes += Int64(data.count)
        link.send(.piece(block, data))
        await publishTransferStatusIfNeeded()
    }

    private func receive(_ block: Block, data: Data, from id: UUID) async {
        guard let address = links[id]?.address else { return }
        let delivery = scheduler.receive(block, byteCount: data.count, from: id, address: address, now: .now)
        guard delivery != .ignored else { return }
        downloadedBytes += Int64(data.count)
        do {
            try await storage.writeBlock(piece: block.index, offset: block.begin, data: data)
        } catch {
            TorrentLog.log("writing piece \(block.index) failed: \(error)")
            scheduler.requeue(piece: block.index)
            await publishStatus()
            return
        }
        guard delivery == .completed else {
            await publishTransferStatusIfNeeded()
            return
        }
        do {
            if try await storage.verify(piece: block.index) {
                await completePiece(block.index)
            } else {
                failPiece(block.index)
            }
        } catch {
            TorrentLog.log("verifying piece \(block.index) failed: \(error)")
            scheduler.requeue(piece: block.index)
        }
        await publishStatus()
    }

    private func completePiece(_ piece: Int) async {
        scheduler.complete(piece: piece)
        verifiedDirty = true
        for link in links.values {
            link.send(.have(piece))
        }
        TorrentLog.log("piece \(piece) verified (\(scheduler.picker.verified.setCount)/\(metainfo.pieceCount))")
        if downloadFinished {
            await saveVerified()
            wake()
        }
    }

    private func failPiece(_ piece: Int) {
        let contributors = scheduler.fail(piece: piece)
        TorrentLog.log("piece \(piece) VERIFY FAILED (attempt \(scheduler.failures[piece] ?? 0))")
        for address in contributors where pool.strike(address) {
            TorrentLog.log("banning peer \(address.host):\(address.port) after repeated piece failures")
            for link in links.values where link.address == address {
                link.transport.close()
            }
        }
    }

    private func announceLoop() async {
        while !Task.isCancelled {
            let event: AnnounceEvent = firstAnnounce ? .started : .none
            firstAnnounce = false
            let interval = await announceAll(event: event)
            try? await Task.sleep(for: .seconds(min(max(interval, 60), 90)))
        }
    }

    private func dhtLoop() async {
        while !Task.isCancelled {
            if let dht = DHTNode.shared() {
                let start = ContinuousClock.now
                if let peers = try? await dht.lookup(infoHash: metainfo.infoHash, timeout: 10) {
                    TorrentLog.log("DHT: found \(peers.count) peers in \(ContinuousClock.now - start)")
                    peers.forEach(considerPeer)
                }
                if listenPort != 0 {
                    try? await dht.announce(infoHash: metainfo.infoHash, port: listenPort)
                }
            }
            try? await Task.sleep(for: .seconds(120))
        }
    }

    private func tickerLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await tick()
        }
    }

    private func announceAll(event: AnnounceEvent) async -> Int {
        let left = Int64(metainfo.totalLength) - metainfo.verifiedByteCount(pieceCount: scheduler.picker.verified.setCount)
        let request = AnnounceRequest(
            infoHash: metainfo.infoHash,
            peerID: peerID,
            port: listenPort,
            uploaded: uploadedBytes,
            downloaded: downloadedBytes,
            left: left,
            event: event,
            numWant: 80,
            key: Int32.random(in: .min ... .max)
        )
        var maxInterval = 0
        var seeds = 0
        await withTaskGroup(of: AnnounceResponse?.self) { group in
            for client in trackerClients {
                group.addTask {
                    do {
                        return try await client.announce(request)
                    } catch {
                        TorrentLog.log("announce \(event) failed: \(error)")
                        return nil
                    }
                }
            }
            for await case let response? in group {
                TorrentLog.log("announce \(event) ok: \(response.peers.count) peers, interval \(response.interval)")
                maxInterval = max(maxInterval, response.interval)
                seeds = max(seeds, response.seeders ?? 0)
                if event != .stopped {
                    response.peers.forEach(considerPeer)
                }
            }
        }
        lastSeeders = seeds
        await publishStatus()
        return maxInterval
    }

    private func tick() async {
        updateTransferRatesIfNeeded()
        let now = ContinuousClock.now
        let stalled = scheduler.requeueStalled(now: now)
        if !stalled.isEmpty {
            TorrentLog.log("pieces \(stalled) stalled; requeueing")
            links.keys.forEach(requestBlocks)
        }
        for link in links.values where now - link.lastReceived >= peerIdleTimeout {
            link.transport.close()
        }
        if verifiedDirty {
            await saveVerified()
        }
        await publishStatus()
    }

    private func publishTransferStatusIfNeeded() async {
        guard updateTransferRatesIfNeeded() else { return }
        await publishStatus()
    }

    @discardableResult
    private func updateTransferRatesIfNeeded() -> Bool {
        let now = ContinuousClock.now
        let elapsed = lastRateSampleTime.duration(to: now)
        guard elapsed >= .seconds(1) else { return false }
        let seconds = elapsed.timeInterval
        downloadRate = Double(downloadedBytes - lastTickDownloaded) / seconds
        uploadRate = Double(uploadedBytes - lastTickUploaded) / seconds
        lastTickDownloaded = downloadedBytes
        lastTickUploaded = uploadedBytes
        lastRateSampleTime = now
        return true
    }

    private func resetTransferRates() {
        downloadRate = 0
        uploadRate = 0
        lastTickDownloaded = downloadedBytes
        lastTickUploaded = uploadedBytes
        lastRateSampleTime = .now
    }

    private func publishStatus() async {
        let state: TorrentStatus.State = if isPaused {
            .paused
        } else if scheduler.picker.verified.allSet {
            .complete
        } else {
            .downloading
        }
        let status = TorrentStatus(
            name: metainfo.displayName,
            infoHash: metainfo.infoHash,
            state: state,
            verifiedCount: scheduler.picker.verified.setCount,
            pieceCount: metainfo.pieceCount,
            peers: links.count,
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
