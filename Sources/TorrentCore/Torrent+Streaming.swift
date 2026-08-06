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
    /// moov tail download ahead of the sequential cursor.
    func streamPriority(fileIndex: Int, range: Range<Int>) async {
        guard metainfo.files.indices.contains(fileIndex) else { return }
        let fileStart = metainfo.fileOffsets[fileIndex]
        let absolute = (fileStart + range.lowerBound)..<(fileStart + range.upperBound)
        picker.priority.formUnion(metainfo.pieceRange(forByteRange: absolute))
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
}
