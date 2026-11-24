import Foundation
import CryptoKit

enum MSEError: Error, Sendable {
    case plaintextFallback
    case noCryptoMethod
    case invalidVC
    case unexpectedInfoHash
    case syncNotFound
}

enum MSEHandshake {
    enum Method: Sendable {
        case plaintext
        case rc4

        init(select: UInt32) throws {
            switch select {
            case MSEHandshake.cryptoPlaintext: self = .plaintext
            case MSEHandshake.cryptoRC4: self = .rc4
            default: throw MSEError.noCryptoMethod
            }
        }
    }

    private static let cryptoPlaintext: UInt32 = 0x01
    private static let cryptoRC4: UInt32 = 0x02
    private static let verificationConstant = Data(repeating: 0, count: 8)
    private static let maxPadLength = 512

    static func initiate(stream: PeerStream, infoHash: Data) async throws -> Method {
        let keyPair = DH.generate()
        try await stream.send(keyPair.publicKey + randomPad())
        let secret = DH.sharedSecret(privateKey: keyPair.privateKey, peerPublic: try await readPeerPublicKey(stream: stream))
        let (encryptor, decryptor) = ciphers(secret: secret, infoHash: infoHash, isInitiator: true)

        let padC = randomPad()
        var offer = verificationConstant
        offer.appendUInt32BE(cryptoPlaintext | cryptoRC4)
        offer.appendUInt16BE(UInt16(padC.count))
        offer.append(padC)
        offer.appendUInt16BE(0)
        let skeyHash = zip(sha1(Data("req2".utf8), infoHash), sha1(Data("req3".utf8), secret)).map { $0 ^ $1 }
        try await stream.send(sha1(Data("req1".utf8), secret) + Data(skeyHash) + encryptor.update(offer))

        try await synchronize(stream: stream, on: decryptor.update(verificationConstant))
        let answer = decryptor.update(try await stream.read(exactly: 6))
        let method = try Method(select: answer.readUInt32BE(at: 0))
        _ = decryptor.update(try await stream.read(exactly: Int(answer.readUInt16BE(at: 4))))
        if method == .rc4 {
            stream.enableEncryption(encryptor: encryptor, decryptor: decryptor)
        }
        return method
    }

    static func respond(stream: PeerStream, infoHash: Data) async throws -> Method {
        let peerPublic = try await readPeerPublicKey(stream: stream)
        let keyPair = DH.generate()
        let secret = DH.sharedSecret(privateKey: keyPair.privateKey, peerPublic: peerPublic)
        try await stream.send(keyPair.publicKey + randomPad())
        let (encryptor, decryptor) = ciphers(secret: secret, infoHash: infoHash, isInitiator: false)

        try await synchronize(stream: stream, on: sha1(Data("req1".utf8), secret))
        let skeyHash = Data(zip(try await stream.read(exactly: 20), sha1(Data("req3".utf8), secret)).map { $0 ^ $1 })
        guard skeyHash == sha1(Data("req2".utf8), infoHash) else { throw MSEError.unexpectedInfoHash }

        let offer = decryptor.update(try await stream.read(exactly: 14))
        guard offer.prefix(8) == verificationConstant else { throw MSEError.invalidVC }
        let provide = offer.readUInt32BE(at: 8)
        let method: Method
        if provide & cryptoRC4 != 0 {
            method = .rc4
        } else if provide & cryptoPlaintext != 0 {
            method = .plaintext
        } else {
            throw MSEError.noCryptoMethod
        }
        _ = decryptor.update(try await stream.read(exactly: Int(offer.readUInt16BE(at: 12))))
        let iaLength = Int(decryptor.update(try await stream.read(exactly: 2)).readUInt16BE(at: 0))
        let initialPayload = decryptor.update(try await stream.read(exactly: iaLength))

        let padD = randomPad()
        var answer = verificationConstant
        answer.appendUInt32BE(method == .rc4 ? cryptoRC4 : cryptoPlaintext)
        answer.appendUInt16BE(UInt16(padD.count))
        answer.append(padD)
        try await stream.send(encryptor.update(answer))

        if method == .rc4 {
            stream.enableEncryption(encryptor: encryptor, decryptor: decryptor)
        }
        stream.unread(initialPayload)
        return method
    }

    private static func ciphers(secret: Data, infoHash: Data, isInitiator: Bool) -> (encryptor: RC4, decryptor: RC4) {
        let keyA = RC4(key: sha1(Data("keyA".utf8), secret, infoHash))
        let keyB = RC4(key: sha1(Data("keyB".utf8), secret, infoHash))
        return isInitiator ? (keyA, keyB) : (keyB, keyA)
    }

    private static func readPeerPublicKey(stream: PeerStream) async throws -> Data {
        let first = try await stream.read(exactly: 1)
        if first[first.startIndex] == 19 {
            stream.unread(first)
            throw MSEError.plaintextFallback
        }
        return first + (try await stream.read(exactly: DH.keyLength - 1))
    }

    private static func synchronize(stream: PeerStream, on pattern: Data) async throws {
        var window = Data()
        while window.count < maxPadLength + pattern.count {
            window.append(try await stream.read(exactly: 1))
            if window.suffix(pattern.count) == pattern { return }
        }
        throw MSEError.syncNotFound
    }

    private static func randomPad() -> Data {
        Data((0..<Int.random(in: 0..<maxPadLength)).map { _ in UInt8.random(in: 0...255) })
    }

    private static func sha1(_ parts: Data...) -> Data {
        var hasher = Insecure.SHA1()
        parts.forEach { hasher.update(data: $0) }
        return Data(hasher.finalize())
    }
}
