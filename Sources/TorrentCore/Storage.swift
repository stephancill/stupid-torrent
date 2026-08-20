import Foundation
import CryptoKit

public enum StorageError: Error, Sendable {
    case fileError(String)
    case outOfRange
    case diskFull(Error)
}

public actor Storage {
    private let directory: URL
    private let metainfo: Metainfo
    private var handles: [Int: FileHandle] = [:]
    private var verified: Bitfield

    public init(directory: URL, metainfo: Metainfo) {
        self.directory = directory
        self.metainfo = metainfo
        self.verified = Bitfield(count: metainfo.pieceCount)
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try allowAccessWhileLocked(at: directory)
        for index in metainfo.files.indices {
            let file = metainfo.files[index]
            let url = directory.appendingPathComponent(file.pathString)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try allowAccessWhileLocked(at: url.deletingLastPathComponent())
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            try allowAccessWhileLocked(at: url)
        }
    }

    public func close() {
        for handle in handles.values {
            try? handle.close()
        }
        handles.removeAll()
    }

    public func writeBlock(piece: Int, offset: Int, data: Data) throws {
        guard piece >= 0, piece < metainfo.pieceCount else { throw StorageError.outOfRange }
        let pieceStart = piece * metainfo.pieceLength
        let absoluteStart = pieceStart + offset
        let absoluteEnd = absoluteStart + data.count
        guard absoluteEnd <= metainfo.totalLength else { throw StorageError.outOfRange }

        var cursor = 0
        for slice in fileSlices(in: absoluteStart..<absoluteEnd) {
            let chunk = data.subdata(in: cursor..<(cursor + slice.length))
            try write(file: slice.fileIndex, offset: slice.fileOffset, data: chunk)
            cursor += slice.length
        }
    }

    public func read(piece: Int, offset: Int, length: Int) throws -> Data {
        guard piece >= 0, piece < metainfo.pieceCount else { throw StorageError.outOfRange }
        let pieceStart = piece * metainfo.pieceLength
        let absoluteStart = pieceStart + offset
        let absoluteEnd = absoluteStart + length
        guard absoluteEnd <= metainfo.totalLength else { throw StorageError.outOfRange }

        var result = Data()
        for slice in fileSlices(in: absoluteStart..<absoluteEnd) {
            try result.append(read(file: slice.fileIndex, offset: slice.fileOffset, length: slice.length))
        }
        return result
    }

    /// Reads an absolute byte range of the torrent (pieces span files transparently).
    public func read(bytes range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= metainfo.totalLength else {
            throw StorageError.outOfRange
        }
        var result = Data()
        var position = range.lowerBound
        while position < range.upperBound {
            let piece = position / metainfo.pieceLength
            let offset = position % metainfo.pieceLength
            let length = min(range.upperBound - position, metainfo.pieceLength - offset)
            result.append(try read(piece: piece, offset: offset, length: length))
            position += length
        }
        return result
    }

    public func pieceLength(_ piece: Int) -> Int {
        let start = piece * metainfo.pieceLength
        return min(metainfo.pieceLength, metainfo.totalLength - start)
    }

    public func verify(piece: Int) throws -> Bool {
        let length = pieceLength(piece)
        let data = try read(piece: piece, offset: 0, length: length)
        let digest = Data(Insecure.SHA1.hash(data: data))
        return digest == metainfo.pieceHashes[piece]
    }

    public func markVerified(_ piece: Int) {
        verified[piece] = true
    }

    public func clearVerified(_ piece: Int) {
        verified[piece] = false
    }

    public var verifiedBitfield: [Bool] {
        verified.bits
    }

    public var verifiedCount: Int {
        verified.setCount
    }

    public func verifiedSidecarURL() -> URL {
        directory.appendingPathComponent(".\(metainfo.infoHash.hexString).verified")
    }

    public func loadVerified() throws {
        let url = verifiedSidecarURL()
        guard let data = try? Data(contentsOf: url) else { return }
        guard data.count >= 4 else { return }
        let count = Int(data.readUInt32BE(at: 0))
        guard count == metainfo.pieceCount else { return }
        verified = Bitfield.from(Data(data.dropFirst(4)), count: count)
    }

    /// Synchronously reads the verified-piece count from the resume sidecar, so callers can
    /// show the restored state (e.g. a torrent already complete) before the engine loads it.
    public static func loadVerifiedCount(directory: URL, infoHash: Data, pieceCount: Int) -> Int {
        let url = directory.appendingPathComponent(".\(infoHash.hexString).verified")
        guard let data = try? Data(contentsOf: url), data.count >= 4 else { return 0 }
        let count = Int(data.readUInt32BE(at: 0))
        guard count == pieceCount else { return 0 }
        return Bitfield.from(Data(data.dropFirst(4)), count: count).setCount
    }

    public func saveVerified() throws {
        var data = Data()
        data.appendUInt32BE(UInt32(metainfo.pieceCount))
        data.append(verified.data())
        let url = verifiedSidecarURL()
        try data.write(to: url)
        try allowAccessWhileLocked(at: url)
    }

    private func write(file index: Int, offset: Int, data: Data) throws {
        do {
            let handle = try handle(forFile: index)
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
        } catch {
            throw StorageError.diskFull(error)
        }
    }

    private func read(file index: Int, offset: Int, length: Int) throws -> Data {
        let handle = try handle(forFile: index)
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: length)
        return data ?? Data()
    }

    private func handle(forFile index: Int) throws -> FileHandle {
        if let handle = handles[index] {
            return handle
        }
        let url = directory.appendingPathComponent(metainfo.files[index].pathString)
        guard let handle = try? FileHandle(forUpdating: url) else {
            throw StorageError.fileError("cannot open \(url.path)")
        }
        handles[index] = handle
        return handle
    }

    private func allowAccessWhileLocked(at url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private func fileSlices(in range: Range<Int>) -> [(fileIndex: Int, fileOffset: Int, length: Int)] {
        var slices: [(fileIndex: Int, fileOffset: Int, length: Int)] = []
        let offsets = metainfo.fileOffsets
        var position = range.lowerBound
        while position < range.upperBound {
            guard let index = offsets.indices.first(where: { position < offsets[$0] + metainfo.files[$0].length }) else { break }
            let fileOffset = position - offsets[index]
            let length = min(metainfo.files[index].length - fileOffset, range.upperBound - position)
            slices.append((fileIndex: index, fileOffset: fileOffset, length: length))
            position += length
        }
        return slices
    }
}

extension Data {
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
