import Foundation
import AVFoundation
import TorrentCore

/// Serves a torrent file's verified bytes to AVPlayer through a custom-scheme `AVURLAsset`,
/// prioritizing the byte ranges the player requests so playback can start before the file
/// finishes downloading.
public final class TorrentStreamSession: @unchecked Sendable {
    public let delegate: TorrentResourceLoaderDelegate
    public let asset: AVURLAsset

    public init(torrent: Torrent, fileIndex: Int) {
        let name = torrent.fileName(fileIndex)
        let contentType = Torrent.contentType(forFileNamed: name) ?? "public.data"
        delegate = TorrentResourceLoaderDelegate(torrent: torrent, fileIndex: fileIndex, contentType: contentType)
        asset = delegate.makeAsset()
    }
}

public final class TorrentResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let torrent: Torrent
    private let fileIndex: Int
    private let fileLength: Int
    private let contentType: String
    private let queue = DispatchQueue(label: "stupid-torrent.stream")

    public init(torrent: Torrent, fileIndex: Int, contentType: String) {
        self.torrent = torrent
        self.fileIndex = fileIndex
        self.fileLength = torrent.fileSize(fileIndex)
        self.contentType = contentType
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
        let limit = requestedLength > 0 ? requestedLength : Int.max
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
                await torrent.streamPriority(fileIndex: fileIndex, range: offset..<min(offset + window, fileLength))
            } else if requestedLength > 0 {
                await torrent.streamPriority(fileIndex: fileIndex, range: offset..<min(offset + requestedLength, fileLength))
            }

            let available = await torrent.streamingAvailability(fileIndex: fileIndex, offset: offset)
            if available > 0 {
                let length = min(available, maxChunk, limit - served)
                guard length > 0 else { break }
                if let data = await torrent.streamingRead(fileIndex: fileIndex, offset: offset, length: length) {
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
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            // Bounded request with no data right now: give what we have; AVPlayer re-requests.
            break
        }
        TorrentLog.log("stream finish start=\(startOffset) served=\(served) allToEnd=\(allToEnd)")
        request.finishLoading()
    }
}
