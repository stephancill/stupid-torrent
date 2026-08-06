import Foundation

public struct Bitfield: Equatable, Sendable {
    public private(set) var bits: [Bool]

    public init(count: Int) {
        bits = Array(repeating: false, count: count)
    }

    public init(bits: [Bool]) {
        self.bits = bits
    }

    public var count: Int { bits.count }

    public subscript(index: Int) -> Bool {
        get { bits[index] }
        set { bits[index] = newValue }
    }

    public var setCount: Int {
        bits.reduce(0) { $0 + ($1 ? 1 : 0) }
    }

    public var allSet: Bool {
        bits.allSatisfy { $0 }
    }

    public func data() -> Data {
        var bytes = Data()
        var current: UInt8 = 0
        var bit = 0
        for value in bits {
            if value {
                current |= (0x80 >> bit)
            }
            bit += 1
            if bit == 8 {
                bytes.append(current)
                current = 0
                bit = 0
            }
        }
        if bit > 0 {
            bytes.append(current)
        }
        return bytes
    }

    public static func from(_ data: Data, count: Int) -> Bitfield {
        var bits = Array(repeating: false, count: count)
        for index in 0..<count {
            let byteIndex = index / 8
            guard byteIndex < data.count else { break }
            let bitIndex = index % 8
            bits[index] = (data[byteIndex] & (0x80 >> bitIndex)) != 0
        }
        return Bitfield(bits: bits)
    }
}
