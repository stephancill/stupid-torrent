import Foundation

extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        appendBigEndian(value)
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        appendBigEndian(value)
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        appendBigEndian(value)
    }

    mutating func appendInt64BE(_ value: Int64) {
        appendBigEndian(value)
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        readBigEndian(UInt16.self, at: offset)
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        readBigEndian(UInt32.self, at: offset)
    }

    func readInt32BE(at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32BE(at: offset))
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        readBigEndian(UInt64.self, at: offset)
    }

    private mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    private func readBigEndian<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type, at offset: Int) -> T {
        let start = startIndex + offset
        return self[start..<(start + MemoryLayout<T>.size)].reduce(T.zero) { $0 << 8 | T($1) }
    }
}
