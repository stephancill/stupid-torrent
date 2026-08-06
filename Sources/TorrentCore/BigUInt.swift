import Foundation

/// Minimal little-endian unsigned big integer (limbs of UInt64) implementing modular
/// exponentiation via Montgomery multiplication. Pure Swift, no dependencies. Used for the
/// 768-bit Diffie-Hellman in MSE/PE (BEP 10). Verified against Python's `pow`.
public struct BigUInt: Equatable, Sendable {
    public var limbs: [UInt64] // little-endian; leading zero limbs trimmed

    public init(limbs: [UInt64]) {
        self.limbs = BigUInt.strip(limbs)
    }

    public init(bytes: Data) {
        let byteCount = bytes.count
        var limbCount = (byteCount + 7) / 8
        var result = [UInt64](repeating: 0, count: limbCount)
        for (index, byte) in bytes.enumerated() {
            let limb = index / 8
            let shift = UInt64(index % 8) * 8
            result[limb] |= UInt64(byte) << shift
        }
        self.limbs = BigUInt.strip(result)
    }

    public var bytes: Data {
        var out = Data()
        for limb in limbs {
            var little = limb.littleEndian
            withUnsafeBytes(of: &little) { out.append(contentsOf: $0) }
        }
        return out
    }

    public var isZero: Bool { limbs.isEmpty }

    public static func strip(_ limbs: [UInt64]) -> [UInt64] {
        var out = limbs
        while out.last == 0 {
            out.removeLast()
        }
        return out
    }

    public static func compare(_ a: [UInt64], _ b: [UInt64]) -> Int {
        let aStripped = strip(a)
        let bStripped = strip(b)
        if aStripped.count != bStripped.count {
            return aStripped.count < bStripped.count ? -1 : 1
        }
        for index in aStripped.indices.reversed() {
            if aStripped[index] != bStripped[index] {
                return aStripped[index] < bStripped[index] ? -1 : 1
            }
        }
        return 0
    }

    /// `self^exponent mod modulus` using Montgomery multiplication.
    public func powerMod(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        let m = BigUInt.strip(modulus.limbs)
        guard !m.isEmpty, m[0] & 1 == 1 else { return BigUInt(limbs: [0]) }
        let n = m.count

        // R = 2^(64*n), M' = -M^{-1} mod 2^64
        let mPrime = BigUInt.modularInverse2exp64(of: m)
        // R2 = R^2 mod M = 2^(128*n) mod M, via repeated doubling
        var r2 = [UInt64](repeating: 0, count: n + 1)
        r2[0] = 1
        for _ in 0..<(128 * n) {
            r2 = BigUInt.doubleAndReduce(r2, m: m)
        }
        let r2Fixed = BigUInt.fixedWidth(r2, count: n)

        func redc(_ tIn: [UInt64]) -> [UInt64] {
            var t = BigUInt.fixedWidth(tIn, count: 2 * n + 2)
            for i in 0..<n {
                let mi = t[i].multipliedFullWidth(by: mPrime).low
                for j in 0..<n {
                    let (hi, lo) = mi.multipliedFullWidth(by: m[j])
                    BigUInt.addAt(&t, value: lo, at: i + j)
                    BigUInt.addAt(&t, value: hi, at: i + j + 1)
                }
            }
            // Include the carry limb at t[2n] (a REDC result can spill one limb).
            var result = Array(t[n..<min(2 * n + 1, t.count)])
            if result.count < n { result.append(contentsOf: Array(repeating: 0, count: n - result.count)) }
            while result.count > n && result.count > 1 {
                if result.last == 0 { result.removeLast() } else { break }
            }
            if BigUInt.compare(result, m) >= 0 {
                result = BigUInt.subtract(result, m)
            }
            return result
        }

        func montMul(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
            redc(BigUInt.multiply(a, b))
        }

        // Convert base to Montgomery form: base * R mod M = REDC(base * R2)
        let baseMont = redc(BigUInt.multiply(BigUInt.fixedWidth(self.limbs, count: n), r2Fixed))
        var resultMont = redc(r2Fixed) // 1 * R mod M = REDC(R2) = R mod M? handled via r2 below
        // Actually 1 in Montgomery form is R mod M. REDC(R2) = R^2 * R^{-1} = R mod M. Correct.

        var a = baseMont
        var e = exponent.limbs
        var bit = 0
        while !e.isEmpty {
            if e[0] & 1 == 1 {
                resultMont = montMul(resultMont, a)
            }
            a = montMul(a, a)
            e = BigUInt.shiftRightOnce(e)
            bit += 1
            _ = bit
        }
        // Convert back: REDC(resultMont) = resultMont * R^{-1} = result mod M
        return BigUInt(limbs: redc(resultMont))
    }

    /// Doubles `x` mod `m` (single conditional subtract is valid since x < m).
    private static func doubleAndReduce(_ x: [UInt64], m: [UInt64]) -> [UInt64] {
        var doubled = x
        var carry: UInt64 = 0
        for index in 0..<doubled.count {
            let (shifted, c) = doubled[index].multipliedReportingOverflow(by: 2)
            let (sum, c2) = shifted.addingReportingOverflow(carry)
            doubled[index] = sum
            carry = (c ? 1 : 0) &+ (c2 ? 1 : 0)
        }
        if carry != 0 {
            doubled.append(carry)
        }
        if BigUInt.compare(doubled, m) >= 0 {
            return BigUInt.subtract(doubled, m)
        }
        return doubled
    }

    private static func shiftRightOnce(_ limbs: [UInt64]) -> [UInt64] {
        var out = limbs
        var carry: UInt64 = 0
        for index in out.indices.reversed() {
            let newCarry = out[index] << 63
            out[index] = (out[index] >> 1) | carry
            carry = newCarry
        }
        return strip(out)
    }

    private static func fixedWidth(_ limbs: [UInt64], count: Int) -> [UInt64] {
        var out = Array(limbs.prefix(count))
        if out.count < count {
            out.append(contentsOf: Array(repeating: 0, count: count - out.count))
        }
        return out
    }

    /// Adds `value` into `limbs` at `index`, propagating carry upward.
    private static func addAt(_ limbs: inout [UInt64], value: UInt64, at index: Int) {
        var value = value
        var index = index
        while value != 0 {
            if index >= limbs.count { limbs.append(0) }
            let (sum, overflow) = limbs[index].addingReportingOverflow(value)
            limbs[index] = sum
            value = overflow ? 1 : 0
            index += 1
        }
    }

    /// Returns `-m^{-1} mod 2^64` (Newton's iteration).
    private static func modularInverse2exp64(of m: [UInt64]) -> UInt64 {
        var inv: UInt64 = 1
        for _ in 0..<6 {
            inv = inv &* (2 &- m[0] &* inv)
        }
        return 0 &- inv
    }

    /// Schoolbook multiply: `a * b` (full width).
    public static func multiply(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var result = [UInt64](repeating: 0, count: a.count + b.count)
        for (i, av) in a.enumerated() {
            var carry: UInt64 = 0
            for (j, bv) in b.enumerated() {
                // result[i+j] += av*bv + carry, keeping low 64 and carrying the rest.
                let (hi, lo) = av.multipliedFullWidth(by: bv)
                // 128-bit add: result[i+j] + lo + carry
                let (s1, c1) = result[i + j].addingReportingOverflow(lo)
                let (s2, c2) = s1.addingReportingOverflow(carry)
                result[i + j] = s2
                // new carry = hi + c1 + c2 (may overflow 64 bits -> fold into result[i+j+1])
                let overflow: UInt64 = (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
                let (hiSum, hiCarry) = hi.addingReportingOverflow(overflow)
                carry = hiSum
                if hiCarry {
                    var pos = i + j + 1
                    while true {
                        let (s, c) = result[pos].addingReportingOverflow(1)
                        result[pos] = s
                        if !c { break }
                        pos += 1
                    }
                }
            }
            // propagate final carry into the next column
            var pos = i + b.count
            while carry != 0 {
                let (s, c) = result[pos].addingReportingOverflow(carry)
                result[pos] = s
                carry = c ? 1 : 0
                pos += 1
            }
        }
        return strip(result)
    }

    public static func add(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let maxCount = max(a.count, b.count)
        var result = [UInt64](repeating: 0, count: maxCount + 1)
        var carry: UInt64 = 0
        for index in 0..<maxCount {
            let av = index < a.count ? a[index] : 0
            let bv = index < b.count ? b[index] : 0
            let (sum1, c1) = av.addingReportingOverflow(bv)
            let (sum2, c2) = sum1.addingReportingOverflow(carry)
            result[index] = sum2
            carry = (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
        }
        result[maxCount] = carry
        return strip(result)
    }

    public static func subtract(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var result = a
        var borrow: UInt64 = 0
        for index in 0..<result.count {
            let bv = index < b.count ? b[index] : 0
            let (diff1, b1) = result[index].subtractingReportingOverflow(bv)
            let (diff2, b2) = diff1.subtractingReportingOverflow(borrow)
            result[index] = diff2
            borrow = (b1 ? 1 : 0) &+ (b2 ? 1 : 0)
        }
        return strip(result)
    }
}
