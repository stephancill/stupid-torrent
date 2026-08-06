import Foundation
import CryptoKit

/// Diffie-Hellman over the fixed 768-bit prime used by MSE/PE (BEP 10). Generates a random
/// 160-bit private key and exposes the 96-byte big-endian public key and the shared secret.
public enum DH {
    /// The 768-bit MODP prime from BEP 10.
    public static let primeHex = "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a63a36210000000000090563"

    public static let prime: BigUInt = {
        let hexBytes = stride(from: 0, to: primeHex.count, by: 2).map {
            UInt8(primeHex[primeHex.index(primeHex.startIndex, offsetBy: $0)..<primeHex.index(primeHex.startIndex, offsetBy: $0 + 2)], radix: 16)!
        }
        return BigUInt(bytes: Data(hexBytes.reversed()))
    }()

    public static let generator = BigUInt(limbs: [2])

    public struct KeyPair {
        public let privateKey: BigUInt
        public let publicKey: Data // 96-byte big-endian
    }

    /// Generates a fresh key pair with a random 160-bit private key.
    public static func generate() -> KeyPair {
        let privateBytes = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
        let privateKey = BigUInt(bytes: privateBytes)
        let publicKey = publicKey(for: privateKey)
        return KeyPair(privateKey: privateKey, publicKey: publicKey)
    }

    public static func publicKey(for privateKey: BigUInt) -> Data {
        let value = generator.powerMod(privateKey, modulus: prime)
        let bytes = value.bytes // little-endian
        let bigEndian = Data(bytes.reversed())
        var out = Data(repeating: 0, count: 96)
        let offset = 96 - bigEndian.count
        if offset >= 0 {
            out.replaceSubrange(offset..<96, with: bigEndian)
        }
        return out
    }

    /// Computes the shared secret `peerPublic^privateKey mod prime`, 96-byte big-endian.
    public static func sharedSecret(privateKey: BigUInt, peerPublic: Data) -> Data {
        let peer = BigUInt(bytes: Data(peerPublic.reversed()))
        let value = peer.powerMod(privateKey, modulus: prime)
        let bytes = value.bytes
        let bigEndian = Data(bytes.reversed())
        var out = Data(repeating: 0, count: 96)
        let offset = 96 - bigEndian.count
        if offset >= 0 {
            out.replaceSubrange(offset..<96, with: bigEndian)
        }
        return out
    }
}
