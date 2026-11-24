import Foundation

public struct Bitfield: Equatable, Sendable {
    public private(set) var bits: [Bool]
    public private(set) var setCount: Int

    public init(count: Int) {
        bits = Array(repeating: false, count: count)
        setCount = 0
    }

    public init(bits: [Bool]) {
        self.bits = bits
        setCount = bits.reduce(0) { $0 + ($1 ? 1 : 0) }
    }

    public var count: Int { bits.count }

    public subscript(index: Int) -> Bool {
        get { bits[index] }
        set {
            guard bits[index] != newValue else { return }
            bits[index] = newValue
            setCount += newValue ? 1 : -1
        }
    }

    public var allSet: Bool {
        setCount == bits.count
    }

    public var setIndices: [Int] {
        bits.indices.filter { bits[$0] }
    }

    public func data() -> Data {
        var bytes = Data(repeating: 0, count: (bits.count + 7) / 8)
        for index in bits.indices where bits[index] {
            bytes[index / 8] |= 0x80 >> (index % 8)
        }
        return bytes
    }

    public static func from(_ data: Data, count: Int) -> Bitfield {
        let bytes = [UInt8](data)
        var bits = Array(repeating: false, count: count)
        for index in 0..<min(count, bytes.count * 8) {
            bits[index] = (bytes[index / 8] & (0x80 >> (index % 8))) != 0
        }
        return Bitfield(bits: bits)
    }
}
