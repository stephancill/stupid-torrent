import Foundation

extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendInt64BE(_ value: Int64) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        let bytes = [self[offset], self[offset + 1]]
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }

    func readInt32BE(at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32BE(at: offset))
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        (UInt64(self[offset]) << 56 | UInt64(self[offset + 1]) << 48 | UInt64(self[offset + 2]) << 40 | UInt64(self[offset + 3]) << 32
            | UInt64(self[offset + 4]) << 24 | UInt64(self[offset + 5]) << 16 | UInt64(self[offset + 6]) << 8 | UInt64(self[offset + 7]))
    }

    func readInt64BE(at offset: Int) -> Int64 {
        Int64(bitPattern: readUInt64BE(at: offset))
    }
}
