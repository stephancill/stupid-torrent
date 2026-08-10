import Foundation

public extension Torrent {
    /// File name for an index (last path component).
    nonisolated func fileName(_ fileIndex: Int) -> String {
        guard metainfo.files.indices.contains(fileIndex) else { return "" }
        return metainfo.files[fileIndex].name
    }

    /// Total length of a file in bytes.
    nonisolated func fileSize(_ fileIndex: Int) -> Int {
        guard metainfo.files.indices.contains(fileIndex) else { return 0 }
        return metainfo.files[fileIndex].length
    }

    /// Prioritize the pieces covering a byte range of a file so the streamer's window and
    /// moov tail download ahead of the sequential cursor. A range ahead of the sequential
    /// progress (seek target, moov tail) is a high-priority jump that also moves the sequential
    /// frontier there; the current window (which tracks the playhead and stays at or behind the
    /// progress) is a low-priority lookahead served after any jumps.
    func streamPriority(fileIndex: Int, range: Range<Int>) async {
        guard metainfo.files.indices.contains(fileIndex) else { return }
        let fileStart = metainfo.fileOffsets[fileIndex]
        let absolute = (fileStart + range.lowerBound)..<(fileStart + range.upperBound)
        let pieces = metainfo.pieceRange(forByteRange: absolute)
        guard !pieces.isEmpty else { return }
        var progress = 0
        while progress < picker.pieceCount && picker.verified[progress] { progress += 1 }
        let isJump = pieces.lowerBound > progress
        if isJump {
            // Jumps (seek targets, moov tail) download first and move the sequential frontier
            // so the in-order stream resumes from the target once the jump window drains. Replace
            // older stream windows so sequential seeks do not keep downloading obsolete targets.
            picker.cursor = pieces.lowerBound
            picker.replacePriorities(with: pieces, level: 10)
            return
        }
        for piece in pieces {
            picker.setPriority(piece, level: 0)
        }
    }

    /// Number of contiguous verified bytes in a file starting at `offset`.
    func streamingAvailability(fileIndex: Int, offset: Int) async -> Int {
        guard metainfo.files.indices.contains(fileIndex) else { return 0 }
        let fileStart = metainfo.fileOffsets[fileIndex]
        let fileLength = metainfo.files[fileIndex].length
        guard offset >= 0, offset < fileLength else { return 0 }
        var position = offset
        var piece = (fileStart + offset) / metainfo.pieceLength
        while position < fileLength {
            guard piece < metainfo.pieceCount, picker.verified[piece] else { break }
            let pieceAbsoluteEnd = min((piece + 1) * metainfo.pieceLength, metainfo.totalLength)
            position = min(pieceAbsoluteEnd, fileStart + fileLength) - fileStart
            piece += 1
        }
        return position - offset
    }

    /// Reads verified bytes from a file. Returns nil if the range isn't fully verified yet.
    func streamingRead(fileIndex: Int, offset: Int, length: Int) async -> Data? {
        guard metainfo.files.indices.contains(fileIndex) else { return nil }
        let fileStart = metainfo.fileOffsets[fileIndex]
        let fileLength = metainfo.files[fileIndex].length
        guard offset >= 0, offset + length <= fileLength else { return nil }
        let absolute = (fileStart + offset)..<(fileStart + offset + length)
        let pieces = metainfo.pieceRange(forByteRange: absolute)
        guard pieces.allSatisfy({ picker.verified[$0] }) else { return nil }
        for piece in pieces where !streamingValidatedPieces.contains(piece) {
            guard (try? await storage.verify(piece: piece)) == true else {
                await invalidateStaleStreamingPiece(piece)
                return nil
            }
            streamingValidatedPieces.insert(piece)
        }
        return try? await storage.read(bytes: absolute)
    }

    /// Content type for a media file by extension, or nil if not streamable by AVPlayer.
    public static func contentType(forFileNamed name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "m4v", "m4b": return "public.mpeg-4"
        case "m4a": return "com.apple.m4a-audio"
        case "mov": return "com.apple.quicktime-movie"
        case "mp3": return "public.mp3"
        case "aac", "m4p": return "public.aac-audio"
        case "wav": return "com.microsoft.waveform-audio"
        default: return nil
        }
    }

    /// How a media file should be played back. AVPlayer handles Apple containers plus Matroska
    /// (transmuxed to fragmented MP4 in `Streaming`); everything else is not streamable.
    public enum PlaybackKind: Equatable, Sendable {
        case avPlayer
        case none
    }

    public static func playbackKind(forFileNamed name: String) -> PlaybackKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if contentType(forFileNamed: name) != nil { return .avPlayer }
        switch ext {
        case "mkv", "mka": return .avPlayer
        default: return .none
        }
    }
}
