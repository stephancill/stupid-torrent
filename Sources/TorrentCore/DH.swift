import Foundation

enum DH {
    struct KeyPair {
        let privateKey: Data
        let publicKey: Data
    }

    static let keyLength = 96

    private static let field = MontgomeryField(
        modulusHex: "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a63a36210000000000090563"
    )

    static func generate() -> KeyPair {
        let privateKey = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
        return KeyPair(privateKey: privateKey, publicKey: publicKey(privateKey: privateKey))
    }

    static func publicKey(privateKey: Data) -> Data {
        field.power(base: [2] + Array(repeating: 0, count: MontgomeryField.limbCount - 1), exponent: privateKey)
    }

    static func sharedSecret(privateKey: Data, peerPublic: Data) -> Data {
        field.power(base: field.reduced(MontgomeryField.limbs(bigEndian: peerPublic)), exponent: privateKey)
    }
}

private struct MontgomeryField: Sendable {
    static let limbCount = 12

    let modulus: [UInt64]
    let inverse: UInt64
    let rSquared: [UInt64]
    let one: [UInt64]

    init(modulusHex: String) {
        let bytes = stride(from: 0, to: modulusHex.count, by: 2).map { offset -> UInt8 in
            let start = modulusHex.index(modulusHex.startIndex, offsetBy: offset)
            return UInt8(modulusHex[start..<modulusHex.index(start, offsetBy: 2)], radix: 16)!
        }
        modulus = Self.limbs(bigEndian: Data(bytes))
        var inverse: UInt64 = 1
        for _ in 0..<6 {
            inverse = inverse &* (2 &- modulus[0] &* inverse)
        }
        self.inverse = 0 &- inverse
        var r = [UInt64](repeating: 0, count: Self.limbCount)
        r[0] = 1
        for _ in 0..<(2 * 64 * Self.limbCount) {
            r = Self.doubled(r, modulus: modulus)
        }
        rSquared = r
        var unit = [UInt64](repeating: 0, count: Self.limbCount)
        unit[0] = 1
        one = Self.multiply(rSquared, unit, modulus: modulus, inverse: self.inverse)
    }

    static func limbs(bigEndian data: Data) -> [UInt64] {
        let padded = Data(repeating: 0, count: max(0, limbCount * 8 - data.count)) + data.suffix(limbCount * 8)
        return (0..<limbCount).map { padded.readUInt64BE(at: (limbCount - 1 - $0) * 8) }
    }

    func reduced(_ value: [UInt64]) -> [UInt64] {
        Self.isLess(value, modulus) ? value : Self.subtract(value, modulus)
    }

    func power(base: [UInt64], exponent: Data) -> Data {
        let montgomeryBase = Self.multiply(base, rSquared, modulus: modulus, inverse: inverse)
        var result = one
        for byte in exponent {
            for bit in (0..<8).reversed() {
                result = Self.multiply(result, result, modulus: modulus, inverse: inverse)
                if byte >> bit & 1 == 1 {
                    result = Self.multiply(result, montgomeryBase, modulus: modulus, inverse: inverse)
                }
            }
        }
        var unit = [UInt64](repeating: 0, count: Self.limbCount)
        unit[0] = 1
        let plain = Self.multiply(result, unit, modulus: modulus, inverse: inverse)
        var out = Data(capacity: Self.limbCount * 8)
        for limb in plain.reversed() {
            out.appendUInt64BE(limb)
        }
        return out
    }

    private static func multiply(_ a: [UInt64], _ b: [UInt64], modulus: [UInt64], inverse: UInt64) -> [UInt64] {
        let n = limbCount
        var t = [UInt64](repeating: 0, count: n + 2)
        for i in 0..<n {
            var carry: UInt64 = 0
            for j in 0..<n {
                (carry, t[j]) = multiplyAdd(a[j], b[i], t[j], carry)
            }
            let (sum, overflow) = t[n].addingReportingOverflow(carry)
            t[n] = sum
            t[n + 1] = overflow ? 1 : 0

            let m = t[0] &* inverse
            (carry, _) = multiplyAdd(m, modulus[0], t[0], 0)
            for j in 1..<n {
                (carry, t[j - 1]) = multiplyAdd(m, modulus[j], t[j], carry)
            }
            let (top, topOverflow) = t[n].addingReportingOverflow(carry)
            t[n - 1] = top
            t[n] = t[n + 1] &+ (topOverflow ? 1 : 0)
        }
        let result = Array(t[0..<n])
        return t[n] != 0 || !isLess(result, modulus) ? subtract(result, modulus) : result
    }

    private static func multiplyAdd(_ a: UInt64, _ b: UInt64, _ addend: UInt64, _ carry: UInt64) -> (high: UInt64, low: UInt64) {
        let (high, low) = a.multipliedFullWidth(by: b)
        let (sum1, overflow1) = low.addingReportingOverflow(addend)
        let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
        return (high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0), sum2)
    }

    private static func doubled(_ value: [UInt64], modulus: [UInt64]) -> [UInt64] {
        var result = value
        var carry: UInt64 = 0
        for index in result.indices {
            let next = result[index] >> 63
            result[index] = result[index] << 1 | carry
            carry = next
        }
        return carry != 0 || !isLess(result, modulus) ? subtract(result, modulus) : result
    }

    private static func isLess(_ a: [UInt64], _ b: [UInt64]) -> Bool {
        for index in a.indices.reversed() where a[index] != b[index] {
            return a[index] < b[index]
        }
        return false
    }

    private static func subtract(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var result = a
        var borrow = false
        for index in result.indices {
            let (difference, borrow1) = result[index].subtractingReportingOverflow(b[index])
            let (final, borrow2) = difference.subtractingReportingOverflow(borrow ? 1 : 0)
            result[index] = final
            borrow = borrow1 || borrow2
        }
        return result
    }
}
