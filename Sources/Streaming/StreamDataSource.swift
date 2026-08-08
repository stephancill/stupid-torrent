import Foundation
import TorrentCore

/// Abstract byte source for the streaming path. `TorrentSeekableInputStream` consumes this;
/// a fake implements it in tests, and `TorrentStreamSourceAdapter` forwards to the `Torrent`
/// actor's verified-byte APIs.
public protocol TorrentStreamSource: Sendable {
    func fileLength(fileIndex: Int) async -> Int
    /// Number of contiguous verified bytes in the file starting at `offset`.
    func availability(fileIndex: Int, offset: Int) async -> Int
    /// Reads verified bytes. Returns nil if the range isn't fully verified yet.
    func read(fileIndex: Int, offset: Int, length: Int) async -> Data?
    /// Prioritize a byte range so it downloads ahead of the sequential cursor.
    func prioritize(fileIndex: Int, range: Range<Int>) async
}

/// Adapter that forwards to the `Torrent` actor's streaming APIs.
public struct TorrentStreamSourceAdapter: TorrentStreamSource {
    private let torrent: Torrent

    public init(torrent: Torrent) {
        self.torrent = torrent
    }

    public func fileLength(fileIndex: Int) async -> Int {
        torrent.fileSize(fileIndex)
    }

    public func availability(fileIndex: Int, offset: Int) async -> Int {
        await torrent.streamingAvailability(fileIndex: fileIndex, offset: offset)
    }

    public func read(fileIndex: Int, offset: Int, length: Int) async -> Data? {
        await torrent.streamingRead(fileIndex: fileIndex, offset: offset, length: length)
    }

    public func prioritize(fileIndex: Int, range: Range<Int>) async {
        await torrent.streamPriority(fileIndex: fileIndex, range: range)
    }
}
