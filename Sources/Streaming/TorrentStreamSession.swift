import Foundation
import AVFoundation
import TorrentCore

enum TorrentStreamSessionError: Error {
    case stopped
}

@MainActor public final class TorrentStreamSession {
    private let source: any TorrentStreamSource
    private let fileIndex: Int
    private let fileName: String
    private let cacheKey: MKVHLSStreamCache.Key?
    private var loader: TorrentResourceLoaderDelegate?
    private var hlsServer: HLSLoopbackServer?
    private var isStopped = false

    public convenience init(torrent: Torrent, fileIndex: Int) {
        self.init(
            source: TorrentStreamSourceAdapter(torrent: torrent),
            fileIndex: fileIndex,
            fileName: torrent.fileName(fileIndex),
            cacheKey: MKVHLSStreamCache.Key(infoHash: torrent.metainfo.infoHash, fileIndex: fileIndex)
        )
    }

    init(source: any TorrentStreamSource, fileIndex: Int, fileName: String, cacheKey: MKVHLSStreamCache.Key?) {
        self.source = source
        self.fileIndex = fileIndex
        self.fileName = fileName
        self.cacheKey = cacheKey
    }

    public func makePlayer() async -> AVPlayer {
        do {
            return try await preparePlayer()
        } catch {
            TorrentLog.log("playback unavailable for \(fileName): \(error)")
            return AVPlayer()
        }
    }

    public func preparePlayer() async throws -> AVPlayer {
        guard !isStopped else { throw TorrentStreamSessionError.stopped }
        guard Self.isMatroska(fileName: fileName) else {
            let loader = TorrentResourceLoaderDelegate(
                source: source,
                fileIndex: fileIndex,
                contentType: Torrent.contentType(forFileNamed: fileName) ?? "public.mpeg-4"
            )
            self.loader = loader
            return AVPlayer(playerItem: AVPlayerItem(asset: loader.makeAsset()))
        }
        let cached: MKVHLSStream? = if let cacheKey { await MKVHLSStreamCache.shared.take(key: cacheKey) } else { nil }
        let stream = cached ?? MKVHLSStream(source: source, fileIndex: fileIndex)
        try await stream.prepare()
        try Task.checkCancellation()
        guard !isStopped else { throw TorrentStreamSessionError.stopped }
        let server = try HLSLoopbackServer(stream: stream)
        server.start()
        hlsServer?.stop()
        hlsServer = server
        let item = AVPlayerItem(asset: AVURLAsset(url: server.playlistURL))
        item.preferredForwardBufferDuration = 60
        return AVPlayer(playerItem: item)
    }

    public func stop() {
        isStopped = true
        loader?.cancelAllLoading()
        loader = nil
        hlsServer?.stop()
        hlsServer = nil
    }

    public nonisolated static func isPlaybackAvailable(torrent: Torrent, fileIndex: Int) async -> Bool {
        let name = torrent.fileName(fileIndex)
        guard Torrent.isPlayable(fileNamed: name) else { return false }
        guard isMatroska(fileName: name) else { return true }
        let source = TorrentStreamSourceAdapter(torrent: torrent)
        if await source.isComplete(fileIndex: fileIndex) { return true }
        let stream = MKVHLSStream(source: source, fileIndex: fileIndex)
        do {
            try await stream.prepare()
        } catch {
            return false
        }
        await MKVHLSStreamCache.shared.store(
            stream,
            key: MKVHLSStreamCache.Key(infoHash: torrent.metainfo.infoHash, fileIndex: fileIndex)
        )
        return true
    }

    private nonisolated static func isMatroska(fileName: String) -> Bool {
        ["mkv", "mka"].contains((fileName as NSString).pathExtension.lowercased())
    }
}

final class TorrentResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private static let maxChunk = 512 * 1024
    private static let lookahead = 2 * 1024 * 1024

    private let source: any TorrentStreamSource
    private let fileIndex: Int
    private let contentType: String
    private let queue = DispatchQueue(label: "stupid-torrent.stream")
    private let taskLock = NSLock()
    private var loadingTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(source: any TorrentStreamSource, fileIndex: Int, contentType: String) {
        self.source = source
        self.fileIndex = fileIndex
        self.contentType = contentType
    }

    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: URL(string: "stupidtorrent://local/\(fileIndex)?id=\(UUID().uuidString)")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func cancelAllLoading() {
        let tasks = taskLock.withLock {
            defer { loadingTasks.removeAll() }
            return Array(loadingTasks.values)
        }
        tasks.forEach { $0.cancel() }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        startServing(loadingRequest)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForRenewalOfRequestedResource renewalRequest: AVAssetResourceRenewalRequest
    ) -> Bool {
        startServing(renewalRequest)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let task = taskLock.withLock { loadingTasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) }
        task?.cancel()
    }

    private func startServing(_ request: AVAssetResourceLoadingRequest) {
        let id = ObjectIdentifier(request)
        let task = Task { [weak self] in
            await self?.serve(request)
            _ = self?.taskLock.withLock { self?.loadingTasks.removeValue(forKey: id) }
        }
        taskLock.withLock { loadingTasks[id] = task }
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
        let startOffset = Int(dataRequest.currentOffset)
        let limit = allToEnd ? Int.max : requestedLength
        var offset = startOffset
        var served = 0
        var nextYield = 4 * 1024 * 1024

        TorrentLog.log("stream req start=\(startOffset) len=\(requestedLength) allToEnd=\(allToEnd) fileLen=\(fileLength)")
        while !Task.isCancelled {
            offset = max(offset, Int(dataRequest.currentOffset))
            guard offset >= 0, offset < fileLength, served < limit else { break }

            let window = allToEnd ? Self.lookahead : requestedLength
            if window > 0 {
                await source.prioritize(fileIndex: fileIndex, range: offset..<min(offset + window, fileLength))
            }

            let available = await source.availability(fileIndex: fileIndex, offset: offset)
            if available > 0,
               let data = await source.read(
                   fileIndex: fileIndex,
                   offset: offset,
                   length: min(available, Self.maxChunk, limit - served)
               ),
               !data.isEmpty {
                dataRequest.respond(with: data)
                offset += data.count
                served += data.count
                if allToEnd, served >= nextYield {
                    try? await Task.sleep(for: .milliseconds(10))
                    nextYield = served + 4 * 1024 * 1024
                }
                continue
            }
            guard allToEnd || requestedLength > 0 else { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if Task.isCancelled { return }
        TorrentLog.log("stream finish start=\(startOffset) served=\(served) allToEnd=\(allToEnd)")
        request.finishLoading()
    }
}
