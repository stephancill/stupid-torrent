import Foundation
import AVFoundation
import TorrentCore

/// Serves a torrent file's bytes to AVPlayer through a custom-scheme `AVURLAsset`,
/// prioritizing the byte ranges the player requests so playback can start before the file
/// finishes downloading. For Matroska files the bytes are the transmuxed fragmented MP4
/// (see `TransmuxStreamSource`); everything else is served raw.
public final class TorrentStreamSession: @unchecked Sendable {
    public let delegate: TorrentResourceLoaderDelegate
    public let asset: AVURLAsset
    private let transmuxSource: TransmuxStreamSource?
    private let hlsStream: MKVHLSStream?
    private let realSource: any TorrentStreamSource
    private let fileIndex: Int
    @MainActor private var hlsServer: HLSLoopbackServer?
    @MainActor private var hlsAsset: AVURLAsset?
    @MainActor private var hlsUnavailable = false
    @MainActor private var lifecycleGeneration = 0
    @MainActor private var isStopped = false

    public init(torrent: Torrent, fileIndex: Int) {
        let name = torrent.fileName(fileIndex)
        let contentType = Torrent.contentType(forFileNamed: name) ?? "public.mpeg-4"
        let ext = (name as NSString).pathExtension.lowercased()
        let realSource = TorrentStreamSourceAdapter(torrent: torrent)
        let source: any TorrentStreamSource
        if ext == "mkv" || ext == "mka" {
            let transmuxSource = TransmuxStreamSource(
                realSource: realSource,
                fileIndex: fileIndex
            )
            source = transmuxSource
            self.transmuxSource = transmuxSource
            hlsStream = MKVHLSStream(source: realSource, fileIndex: fileIndex)
        } else {
            source = realSource
            transmuxSource = nil
            hlsStream = nil
        }
        self.realSource = realSource
        self.fileIndex = fileIndex
        delegate = TorrentResourceLoaderDelegate(
            source: source,
            fileIndex: fileIndex,
            contentType: contentType,
            finishesAllToEndAtFrontier: ext == "mkv" || ext == "mka"
        )
        asset = delegate.makeAsset()
    }

    private func declaredDurationSeconds() async -> Double? {
        await transmuxSource?.declaredDurationSeconds()
    }

    @MainActor public func makePlayerItem() async -> AVPlayerItem {
        if await prepareHLS(), let hlsAsset {
            let item = AVPlayerItem(asset: hlsAsset)
            item.preferredForwardBufferDuration = 60
            return item
        }
        if Task.isCancelled || isStopped { return AVPlayerItem(asset: asset) }
        let supportsFarSeeking = await transmuxSource?.supportsFarSeeking() ?? false
        return await makePlayerItem(overridesDuration: supportsFarSeeking)
    }

    @MainActor private func makePlayerItem(overridesDuration: Bool) async -> AVPlayerItem {
        guard overridesDuration, let duration = await declaredDurationSeconds() else {
            return AVPlayerItem(asset: asset)
        }
        return DeclaredDurationPlayerItem(
            asset: asset,
            declaredDuration: CMTime(seconds: duration, preferredTimescale: 600)
        )
    }

    @MainActor public func makePlayer() async -> AVPlayer {
        if await prepareHLS(), let hlsAsset {
            let item = AVPlayerItem(asset: hlsAsset)
            item.preferredForwardBufferDuration = 60
            return AVPlayer(playerItem: item)
        }
        if Task.isCancelled || isStopped { return AVPlayer() }
        if hlsStream != nil {
            guard await sourceIsComplete() else { return AVPlayer() }
            return AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        return AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }

    public static func isPlaybackAvailable(torrent: Torrent, fileIndex: Int) async -> Bool {
        let name = torrent.fileName(fileIndex)
        guard Torrent.playbackKind(forFileNamed: name) != .none else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        guard ext == "mkv" || ext == "mka" else { return true }

        let source = TorrentStreamSourceAdapter(torrent: torrent)
        let length = await source.fileLength(fileIndex: fileIndex)
        guard length > 0 else { return false }
        if await source.availability(fileIndex: fileIndex, offset: 0) >= length { return true }
        do {
            try await MKVHLSStream(source: source, fileIndex: fileIndex).prepare()
            return true
        } catch {
            return false
        }
    }

    @MainActor public func stop() {
        lifecycleGeneration += 1
        isStopped = true
        delegate.cancelAllLoading()
        hlsServer?.stop()
        hlsServer = nil
        hlsAsset = nil
    }

    @MainActor private func prepareHLS() async -> Bool {
        if hlsAsset != nil { return true }
        guard !hlsUnavailable, !isStopped, let hlsStream else { return false }
        let generation = lifecycleGeneration
        do {
            try await hlsStream.prepare()
            try Task.checkCancellation()
            guard !isStopped, generation == lifecycleGeneration else {
                throw CancellationError()
            }
            let server = try HLSLoopbackServer(stream: hlsStream)
            server.start()
            hlsServer = server
            hlsAsset = AVURLAsset(url: server.playlistURL)
            return true
        } catch {
            hlsUnavailable = true
            TorrentLog.log("HLS preparation failed: \(error)")
            return false
        }
    }

    private func sourceIsComplete() async -> Bool {
        let length = await realSource.fileLength(fileIndex: fileIndex)
        guard length > 0 else { return false }
        return await realSource.availability(fileIndex: fileIndex, offset: 0) >= length
    }
}

private final class DeclaredDurationPlayerItem: AVPlayerItem, @unchecked Sendable {
    private let declaredDuration: CMTime

    init(asset: AVAsset, declaredDuration: CMTime) {
        self.declaredDuration = declaredDuration
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var duration: CMTime {
        declaredDuration
    }
}

struct PreparedTorrentSeek: @unchecked Sendable {
    let item: AVPlayerItem
    let timelineOffset: Double
}

private final class LockedSeekTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CMTime?
    private var timelineOffset = 0.0

    func get() -> CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: CMTime?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func clear(ifMatching expected: CMTime) {
        lock.lock()
        if value == expected { value = nil }
        lock.unlock()
    }

    func getTimelineOffset() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return timelineOffset
    }

    func setTimelineOffset(_ timelineOffset: Double) {
        lock.lock()
        self.timelineOffset = timelineOffset
        lock.unlock()
    }
}

@MainActor final class TorrentSeekingPlayer: AVPlayer, @unchecked Sendable {
    typealias PrepareSeek = @MainActor @Sendable (Double) async -> PreparedTorrentSeek?

    private var prepareSeek: PrepareSeek?
    private var timelineOffset = 0.0
    private var seekTask: Task<Void, Never>?
    private var seekGeneration = 0
    private var resumeAfterPendingSeek = false
    private let pendingSeekTime = LockedSeekTime()

    init(playerItem: AVPlayerItem, prepareSeek: @escaping PrepareSeek) {
        self.prepareSeek = prepareSeek
        super.init()
        replaceCurrentItem(with: playerItem)
    }

    override init() {
        prepareSeek = nil
        super.init()
    }

    required init?(coder: NSCoder) {
        prepareSeek = nil
        super.init()
    }

    nonisolated override func currentTime() -> CMTime {
        if let pending = pendingSeekTime.get() { return pending }
        return super.currentTime() + CMTime(
            seconds: pendingSeekTime.getTimelineOffset(),
            preferredTimescale: 600
        )
    }

    nonisolated override func seek(to time: CMTime) {
        seek(to: time, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
    }

    nonisolated override func seek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime
    ) {
        seek(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter) { _ in }
    }

    nonisolated override func seek(to time: CMTime, completionHandler: @escaping @Sendable (Bool) -> Void) {
        seek(
            to: time,
            toleranceBefore: .positiveInfinity,
            toleranceAfter: .positiveInfinity,
            completionHandler: completionHandler
        )
    }

    nonisolated override func seek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        Task { @MainActor [weak self] in
            await self?.handleSeek(
                to: time,
                toleranceBefore: toleranceBefore,
                toleranceAfter: toleranceAfter,
                completionHandler: completionHandler
            )
        }
    }

    private func handleSeek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completionHandler: @escaping @Sendable (Bool) -> Void
    ) async {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else {
            performSeek(
                to: time,
                toleranceBefore: toleranceBefore,
                toleranceAfter: toleranceAfter,
                completionHandler: completionHandler
            )
            return
        }

        seekGeneration += 1
        let generation = seekGeneration
        let hadPendingSeek = seekTask != nil || pendingSeekTime.get() != nil
        resumeAfterPendingSeek = rate != 0 || (hadPendingSeek && resumeAfterPendingSeek)
        seekTask?.cancel()
        seekTask = nil
        pendingSeekTime.set(time)

        pause()
        currentItem?.asset.cancelLoading()
        seekTask = Task { @MainActor [weak self] in
            guard let self, let prepareSeek, let prepared = await prepareSeek(seconds),
                  !Task.isCancelled, generation == seekGeneration else {
                if self?.seekGeneration == generation {
                    self?.pendingSeekTime.clear(ifMatching: time)
                    self?.seekTask = nil
                    self?.resumeAfterPendingSeek = false
                }
                completionHandler(false)
                return
            }
            timelineOffset = prepared.timelineOffset
            pendingSeekTime.setTimelineOffset(prepared.timelineOffset)
            replaceCurrentItem(with: prepared.item)
            let translatedTime = CMTime(
                seconds: max(0, seconds - prepared.timelineOffset),
                preferredTimescale: 600
            )
            performSeek(
                to: translatedTime,
                toleranceBefore: toleranceBefore,
                toleranceAfter: toleranceAfter
            ) { [weak self] finished in
                Task { @MainActor in
                    guard let self, generation == self.seekGeneration else {
                        completionHandler(false)
                        return
                    }
                    self.pendingSeekTime.clear(ifMatching: time)
                    let shouldResume = self.resumeAfterPendingSeek
                    self.resumeAfterPendingSeek = false
                    self.seekTask = nil
                    if shouldResume { self.play() }
                    completionHandler(finished)
                }
            }
        }
    }

    private func performSeek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        super.seek(
            to: time,
            toleranceBefore: toleranceBefore,
            toleranceAfter: toleranceAfter,
            completionHandler: completionHandler
        )
    }
}

public final class TorrentResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let source: any TorrentStreamSource
    private let fileIndex: Int
    private let contentType: String
    private let finishesAllToEndAtFrontier: Bool
    private let queue = DispatchQueue(label: "stupid-torrent.stream")
    private let taskLock = NSLock()
    private var loadingTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    public init(
        source: any TorrentStreamSource,
        fileIndex: Int,
        contentType: String,
        finishesAllToEndAtFrontier: Bool = false
    ) {
        self.source = source
        self.fileIndex = fileIndex
        self.contentType = contentType
        self.finishesAllToEndAtFrontier = finishesAllToEndAtFrontier
    }

    public func makeAsset() -> AVURLAsset {
        let url = URL(string: "stupidtorrent://local/\(fileIndex)?id=\(UUID().uuidString)")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    public func cancelAllLoading() {
        taskLock.lock()
        let tasks = Array(loadingTasks.values)
        loadingTasks.removeAll()
        taskLock.unlock()
        tasks.forEach { $0.cancel() }
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        startServing(loadingRequest)
        return true
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForRenewalOfRequestedResource renewalRequest: AVAssetResourceRenewalRequest
    ) -> Bool {
        startServing(renewalRequest)
        return true
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let id = ObjectIdentifier(loadingRequest)
        taskLock.lock()
        let task = loadingTasks.removeValue(forKey: id)
        taskLock.unlock()
        task?.cancel()
    }

    private func startServing(_ request: AVAssetResourceLoadingRequest) {
        let id = ObjectIdentifier(request)
        let task = Task { [weak self] in
            await self?.serve(request)
            self?.removeLoadingTask(id: id)
        }
        taskLock.lock()
        loadingTasks[id] = task
        taskLock.unlock()
    }

    private func removeLoadingTask(id: ObjectIdentifier) {
        taskLock.lock()
        loadingTasks.removeValue(forKey: id)
        taskLock.unlock()
    }

    private func serve(_ request: AVAssetResourceLoadingRequest) async {
        let fileLength = await source.fileLength(fileIndex: fileIndex)
        if let info = request.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(fileLength)
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return
        }

        let requestedLength = Int(dataRequest.requestedLength)
        let allToEnd = dataRequest.requestsAllDataToEndOfResource
        let maxChunk = 512 * 1024
        let startOffset = Int(dataRequest.currentOffset)
        // For all-to-end requests `requestedLength` is only AVPlayer's initial buffer hint, not
        // a bound — serve until the source is exhausted (finishes at `reachesEOF` / file end).
        // Bounded requests get exactly their requested range.
        let limit = allToEnd ? Int.max : requestedLength
        var offset = startOffset
        var served = 0
        var nextYield = 4 * 1024 * 1024

        TorrentLog.log("stream req start=\(startOffset) len=\(requestedLength) allToEnd=\(allToEnd) fileLen=\(fileLength)")
        while true {
            if Task.isCancelled { return }
            // Follow the player if it jumped its offset on its own.
            let current = Int(dataRequest.currentOffset)
            if current > offset { offset = current }

            guard offset >= 0, offset < fileLength, served < limit else { break }

            // Prioritize what AVPlayer needs to make progress, without flooding the whole file
            // into the priority set (which would defeat the moov-tail/seek jump). All-to-end
            // requests get a bounded lookahead window; bounded requests get their exact range.
            if allToEnd {
                let window = 2 * 1024 * 1024
                await source.prioritize(fileIndex: fileIndex, range: offset..<min(offset + window, fileLength))
            } else if requestedLength > 0 {
                await source.prioritize(fileIndex: fileIndex, range: offset..<min(offset + requestedLength, fileLength))
            }

            let available = await source.availability(fileIndex: fileIndex, offset: offset)
            if available > 0 {
                let length = min(available, maxChunk, limit - served)
                guard length > 0 else { break }
                if let data = await source.read(fileIndex: fileIndex, offset: offset, length: length), !data.isEmpty {
                    dataRequest.respond(with: data)
                    TorrentLog.log("stream served \(data.count) bytes at \(offset)")
                    offset += data.count
                    served += data.count
                    if allToEnd, served >= nextYield {
                        try? await Task.sleep(for: .milliseconds(10))
                        nextYield = served + 4 * 1024 * 1024
                    }
                    continue
                }
            }
            if allToEnd {
                // Finish once the source is exhausted (for the transmuxer's virtual file the
                // content length is an estimate, so EOF must come from the source itself).
                if await source.reachesEOF(fileIndex: fileIndex, offset: offset) {
                    break
                }
                if finishesAllToEndAtFrontier, served > 0 {
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            if requestedLength > 0 {
                // Bounded (seek / read-ahead) request: wait for the bytes rather than finishing
                // empty — otherwise a far seek on a still-downloading file is answered with
                // nothing and AVPlayer reverts to the buffered position.
                if await source.reachesEOF(fileIndex: fileIndex, offset: offset) {
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            // Probe request (requestedLength == 0): give what's available; AVPlayer re-requests.
            break
        }
        if Task.isCancelled { return }
        TorrentLog.log("stream finish start=\(startOffset) served=\(served) allToEnd=\(allToEnd)")
        request.finishLoading()
    }
}
