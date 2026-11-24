import Foundation
import TorrentCore

protocol TorrentStreamSource: Sendable {
    func fileLength(fileIndex: Int) async -> Int
    func availability(fileIndex: Int, offset: Int) async -> Int
    func read(fileIndex: Int, offset: Int, length: Int) async -> Data?
    func prioritize(fileIndex: Int, range: Range<Int>) async
}

extension TorrentStreamSource {
    func isComplete(fileIndex: Int) async -> Bool {
        let length = await fileLength(fileIndex: fileIndex)
        guard length > 0 else { return false }
        return await availability(fileIndex: fileIndex, offset: 0) >= length
    }
}

struct TorrentStreamSourceAdapter: TorrentStreamSource {
    let torrent: Torrent

    func fileLength(fileIndex: Int) async -> Int {
        torrent.fileSize(fileIndex)
    }

    func availability(fileIndex: Int, offset: Int) async -> Int {
        await torrent.streamingAvailability(fileIndex: fileIndex, offset: offset)
    }

    func read(fileIndex: Int, offset: Int, length: Int) async -> Data? {
        await torrent.streamingRead(fileIndex: fileIndex, offset: offset, length: length)
    }

    func prioritize(fileIndex: Int, range: Range<Int>) async {
        await torrent.streamPriority(fileIndex: fileIndex, range: range)
    }
}
