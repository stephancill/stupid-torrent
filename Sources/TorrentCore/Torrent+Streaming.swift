import Foundation

public extension Torrent {
    nonisolated func fileName(_ fileIndex: Int) -> String {
        guard metainfo.files.indices.contains(fileIndex) else { return "" }
        return metainfo.files[fileIndex].name
    }

    nonisolated func fileSize(_ fileIndex: Int) -> Int {
        guard metainfo.files.indices.contains(fileIndex) else { return 0 }
        return metainfo.files[fileIndex].length
    }

    func streamPriority(fileIndex: Int, range: Range<Int>) async {
        guard metainfo.files.indices.contains(fileIndex) else { return }
        let fileStart = metainfo.fileOffsets[fileIndex]
        let absolute = (fileStart + range.lowerBound)..<(fileStart + range.upperBound)
        let pieces = metainfo.pieceRange(forByteRange: absolute)
        guard !pieces.isEmpty else { return }
        if let head = pieces.first(where: { !scheduler.picker.verified[$0] }) {
            scheduler.urgentPieces = [head]
            scheduler.picker.setPriority(head, level: 20)
        }
        var progress = 0
        while progress < scheduler.picker.pieceCount && scheduler.picker.verified[progress] { progress += 1 }
        let isJump = pieces.lowerBound > progress
        if isJump {
            scheduler.picker.cursor = pieces.lowerBound
            scheduler.picker.replacePriorities(with: pieces, level: 10)
            if let head = scheduler.urgentPieces.first { scheduler.picker.setPriority(head, level: 20) }
            return
        }
        for piece in pieces {
            scheduler.picker.setPriority(piece, level: 0)
        }
    }

    func streamingAvailability(fileIndex: Int, offset: Int) async -> Int {
        guard metainfo.files.indices.contains(fileIndex) else { return 0 }
        let fileStart = metainfo.fileOffsets[fileIndex]
        let fileLength = metainfo.files[fileIndex].length
        guard offset >= 0, offset < fileLength else { return 0 }
        var position = offset
        var piece = (fileStart + offset) / metainfo.pieceLength
        while position < fileLength {
            guard piece < metainfo.pieceCount, scheduler.picker.verified[piece] else { break }
            let pieceAbsoluteEnd = piece * metainfo.pieceLength + metainfo.length(ofPiece: piece)
            position = min(pieceAbsoluteEnd, fileStart + fileLength) - fileStart
            piece += 1
        }
        return position - offset
    }

    func streamingRead(fileIndex: Int, offset: Int, length: Int) async -> Data? {
        guard metainfo.files.indices.contains(fileIndex) else { return nil }
        let fileStart = metainfo.fileOffsets[fileIndex]
        let fileLength = metainfo.files[fileIndex].length
        guard offset >= 0, offset + length <= fileLength else { return nil }
        let absolute = (fileStart + offset)..<(fileStart + offset + length)
        let pieces = metainfo.pieceRange(forByteRange: absolute)
        guard pieces.allSatisfy({ scheduler.picker.verified[$0] }) else { return nil }
        for piece in pieces where !streamingValidatedPieces.contains(piece) {
            guard (try? await storage.verify(piece: piece)) == true else {
                await invalidateStaleStreamingPiece(piece)
                return nil
            }
            streamingValidatedPieces.insert(piece)
        }
        return try? await storage.read(bytes: absolute)
    }

    static func contentType(forFileNamed name: String) -> String? {
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

    static func isPlayable(fileNamed name: String) -> Bool {
        if contentType(forFileNamed: name) != nil { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "mkv" || ext == "mka"
    }
}
