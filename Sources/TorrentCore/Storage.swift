import Foundation
import CryptoKit

public enum StorageError: Error, Sendable {
    case fileError(String)
    case outOfRange
    case shortRead
    case diskFull
}

public actor Storage {
    private let directory: URL
    private let metainfo: Metainfo
    private var handles: [Int: FileHandle] = [:]

    public init(directory: URL, metainfo: Metainfo) {
        self.directory = directory
        self.metainfo = metainfo
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try allowAccessWhileLocked(at: directory)
        for file in metainfo.files {
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
        let start = try absoluteStart(piece: piece, offset: offset, length: data.count)
        var cursor = data.startIndex
        for slice in fileSlices(in: start..<(start + data.count)) {
            try write(file: slice.fileIndex, offset: slice.fileOffset, data: data[cursor..<(cursor + slice.length)])
            cursor += slice.length
        }
    }

    public func read(piece: Int, offset: Int, length: Int) throws -> Data {
        let start = try absoluteStart(piece: piece, offset: offset, length: length)
        return try read(bytes: start..<(start + length))
    }

    public func read(bytes range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= metainfo.totalLength else {
            throw StorageError.outOfRange
        }
        var result = Data()
        for slice in fileSlices(in: range) {
            try result.append(read(file: slice.fileIndex, offset: slice.fileOffset, length: slice.length))
        }
        return result
    }

    public func verify(piece: Int) throws -> Bool {
        let length = metainfo.length(ofPiece: piece)
        let data = try read(piece: piece, offset: 0, length: length)
        guard data.count == length else { throw StorageError.shortRead }
        return Data(Insecure.SHA1.hash(data: data)) == metainfo.pieceHashes[piece]
    }

    public func saveVerified(_ verified: Bitfield) throws {
        var data = Data()
        data.appendUInt32BE(UInt32(metainfo.pieceCount))
        data.append(verified.data())
        let url = Self.sidecarURL(directory: directory, infoHash: metainfo.infoHash)
        try data.write(to: url)
        try allowAccessWhileLocked(at: url)
    }

    public static func sidecarURL(directory: URL, infoHash: Data) -> URL {
        directory.appendingPathComponent(".\(infoHash.hexString).verified")
    }

    public static func loadVerified(directory: URL, metainfo: Metainfo) -> Bitfield {
        let url = sidecarURL(directory: directory, infoHash: metainfo.infoHash)
        guard let data = try? Data(contentsOf: url), data.count >= 4,
              Int(data.readUInt32BE(at: 0)) == metainfo.pieceCount else {
            return Bitfield(count: metainfo.pieceCount)
        }
        return Bitfield.from(data.dropFirst(4), count: metainfo.pieceCount)
    }

    private func absoluteStart(piece: Int, offset: Int, length: Int) throws -> Int {
        guard piece >= 0, piece < metainfo.pieceCount, offset >= 0, length >= 0 else { throw StorageError.outOfRange }
        let start = piece * metainfo.pieceLength + offset
        guard start + length <= metainfo.totalLength else { throw StorageError.outOfRange }
        return start
    }

    private func write(file index: Int, offset: Int, data: Data) throws {
        let handle = try handle(forFile: index)
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
        } catch let error as NSError where Self.isOutOfSpace(error) {
            throw StorageError.diskFull
        }
    }

    private static func isOutOfSpace(_ error: NSError) -> Bool {
        switch error.domain {
        case NSPOSIXErrorDomain: error.code == Int(ENOSPC)
        case NSCocoaErrorDomain: error.code == NSFileWriteOutOfSpaceError
        default: false
        }
    }

    private func read(file index: Int, offset: Int, length: Int) throws -> Data {
        let handle = try handle(forFile: index)
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
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
        let offsets = metainfo.fileOffsets
        var slices: [(fileIndex: Int, fileOffset: Int, length: Int)] = []
        var index = max(0, (offsets.lastIndex { $0 <= range.lowerBound }) ?? 0)
        var position = range.lowerBound
        while position < range.upperBound, index < offsets.count {
            let fileEnd = offsets[index] + metainfo.files[index].length
            if position < fileEnd {
                let length = min(fileEnd, range.upperBound) - position
                slices.append((fileIndex: index, fileOffset: position - offsets[index], length: length))
                position += length
            }
            index += 1
        }
        return slices
    }
}

extension Data {
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
