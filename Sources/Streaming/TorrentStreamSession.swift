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

    public init(torrent: Torrent, fileIndex: Int) {
        let name = torrent.fileName(fileIndex)
        let contentType = Torrent.contentType(forFileNamed: name)
        let ext = (name as NSString).pathExtension.lowercased()
        let source: any TorrentStreamSource
        if ext == "mkv" || ext == "mka" {
            let transmuxSource = TransmuxStreamSource(
                realSource: TorrentStreamSourceAdapter(torrent: torrent),
                fileIndex: fileIndex
            )
            source = transmuxSource
            self.transmuxSource = transmuxSource
        } else {
            source = TorrentStreamSourceAdapter(torrent: torrent)
            transmuxSource = nil
        }
        delegate = TorrentResourceLoaderDelegate(
            source: source,
            fileIndex: fileIndex,
            contentType: contentType ?? "public.mpeg-4",
            finishesAllToEndAtFrontier: ext == "mkv" || ext == "mka"
        )
        asset = delegate.makeAsset()
    }

    private func declaredDurationSeconds() async -> Double? {
        await transmuxSource?.declaredDurationSeconds()
    }

    @MainActor public func makePlayerItem() async -> AVPlayerItem {
        guard let duration = await declaredDurationSeconds() else {
            return AVPlayerItem(asset: asset)
        }
        return DeclaredDurationPlayerItem(
            asset: asset,
            declaredDuration: CMTime(seconds: duration, preferredTimescale: 600)
        )
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

public final class TorrentResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let source: any TorrentStreamSource
    private let fileIndex: Int
    private let contentType: String
    private let finishesAllToEndAtFrontier: Bool
    private let queue = DispatchQueue(label: "stupid-torrent.stream")

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
        let url = URL(string: "stupidtorrent://local/\(fileIndex)")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        Task { await self.serve(loadingRequest) }
        return true
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForRenewalOfRequestedResource renewalRequest: AVAssetResourceRenewalRequest
    ) -> Bool {
        Task { await self.serve(renewalRequest) }
        return true
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

        TorrentLog.log("stream req start=\(startOffset) len=\(requestedLength) allToEnd=\(allToEnd) fileLen=\(fileLength)")
        while true {
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
                    continue
                }
            }
            if Task.isCancelled {
                request.finishLoading(with: NSError(
                    domain: "stupid-torrent.stream",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "stream cancelled"]
                ))
                return
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
        TorrentLog.log("stream finish start=\(startOffset) served=\(served) allToEnd=\(allToEnd)")
        request.finishLoading()
    }
}
