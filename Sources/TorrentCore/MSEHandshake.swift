import Foundation
import CryptoKit

public enum MSEError: Error, Sendable {
    case timeout
    case closed
    case plaintextFallback
    case noCryptoMethod
    case invalidVC
    case unexpectedInfoHash
}

/// Message Stream Encryption (MSE/PE, BEP 10) handshake. Runs over a raw `PeerStream`; on
/// success it installs encrypt/decrypt transforms so the payload wire protocol is obfuscated.
///
/// Flow (A = initiator/outgoing, B = responder/incoming):
///   step 1  A => B   Diffie-Hellman Ya + PadA
///   step 2  B => A   Diffie-Hellman Yb + PadB
///   step 3  A => B   HASH(req1,S), HASH(req2,SKEY) XOR HASH(req3,S), ENCRYPT(VC,provide,len(padC),padC,len(IA))
///   step 4  B => A   ENCRYPT(VC,select,len(padD),padD)
///   step 5+          ENCRYPT2(payload)
public final class MSEHandshake: @unchecked Sendable {
    public enum Method: Int {
        case plaintext = 1
        case rc4 = 2
    }

    private let stream: PeerStream
    private var sharedSecret: Data?
    private var encryptCipher: RC4?
    private var decryptCipher: RC4?
    private(set) public var method: Method?

    public init(stream: PeerStream) {
        self.stream = stream
    }

    /// Runs the MSE handshake as the initiator (outgoing connection) for the given info hash.
    /// On success the peer's cipher method is stored in `method`; if the peer answers in
    /// plaintext, `MSEError.plaintextFallback` is thrown and the caller proceeds unencrypted.
    public func performAsInitiator(infoHash: Data) async throws {
        let keyPair = DH.generate()
        // step 1: Ya + PadA
        var step1 = keyPair.publicKey
        step1.append(randomPad())
        try await stream.send(step1)

        // step 2: read Yb (96 bytes) + PadB (variable). Peers send a plaintext handshake if they
        // don't support MSE; detect that by the first byte (19 = pstrlen of "BitTorrent protocol").
        let ybData = try await readUntilPeerPublicKey()
        guard ybData.count == 96 else {
            throw MSEError.closed
        }
        sharedSecret = DH.sharedSecret(privateKey: keyPair.privateKey, peerPublic: ybData)
        let S = sharedSecret!
        let skey = infoHash

        let keyA = sha1(Data("keyA".utf8), S, skey)
        let keyB = sha1(Data("keyB".utf8), S, skey)
        encryptCipher = RC4(key: keyA)
        decryptCipher = RC4(key: keyB)

        // step 3
        let req1 = sha1(Data("req1".utf8), S)
        let req2 = sha1(Data("req2".utf8), skey)
        let req3 = sha1(Data("req3".utf8), S)
        var xorHash = Data(count: 20)
        for i in 0..<20 { xorHash[i] = req2[i] ^ req3[i] }

        let provide: UInt32 = 0x01 | 0x02 // plaintext + RC4
        let padC = randomPad()
        let iaLength: UInt16 = 0

        var step3Plaintext = Data(repeating: 0, count: 8) // VC
        step3Plaintext.appendUInt32BE(provide)
        step3Plaintext.appendUInt16BE(UInt16(padC.count))
        step3Plaintext.append(padC)
        step3Plaintext.appendUInt16BE(iaLength)
        let encryptedPart = encryptCipher!.update(step3Plaintext)

        var step3 = req1
        step3.append(xorHash)
        step3.append(encryptedPart)
        try await stream.send(step3)

        // step 4: wait for encrypted VC + crypto_select + padD length + padD
        try await receiveStep4()
    }

    /// Runs the MSE handshake as the responder (incoming connection) for the given info hash.
    public func performAsResponder(infoHash: Data) async throws {
        // step 1: read Ya (96 bytes) + PadA; detect plaintext fallback.
        let yaData = try await readUntilPeerPublicKey()
        guard yaData.count == 96 else {
            throw MSEError.closed
        }
        let keyPair = DH.generate()
        sharedSecret = DH.sharedSecret(privateKey: keyPair.privateKey, peerPublic: yaData)
        let S = sharedSecret!
        let skey = infoHash

        // step 2: send Yb + PadB
        var step2 = keyPair.publicKey
        step2.append(randomPad())
        try await stream.send(step2)

        let keyA = sha1(Data("keyA".utf8), S, skey)
        let keyB = sha1(Data("keyB".utf8), S, skey)
        encryptCipher = RC4(key: keyB)
        decryptCipher = RC4(key: keyA)

        // step 3: HASH(req1,S) + XOR'd SKEY hash + ENCRYPT(...)
        let req1 = sha1(Data("req1".utf8), S)
        try await stream.readUntil(pattern: req1, maxBytes: 512)
        let xorHash = try await stream.read(exactly: 20)
        let req3 = sha1(Data("req3".utf8), S)
        var receivedInfoHashHash = Data(count: 20)
        for i in 0..<20 { receivedInfoHashHash[i] = xorHash[i] ^ req3[i] }
        // The xor hash recovers HASH('req2', SKEY); the responder matches that against the
        // known torrent (it cannot know the raw infohash yet).
        guard receivedInfoHashHash == sha1(Data("req2".utf8), infoHash) else {
            throw MSEError.unexpectedInfoHash
        }

        // decode ENCRYPT(VC, provide, len(padC), padC, len(IA))
        let header = decryptCipher!.update(try await stream.read(exactly: 14))
        guard header.prefix(8) == Data(repeating: 0, count: 8) else {
            throw MSEError.invalidVC
        }
        let provide = header.readUInt32BE(at: 8)
        guard provide & 0x01 != 0 || provide & 0x02 != 0 else {
            throw MSEError.noCryptoMethod
        }
        let padCLength = Int(header.readUInt16BE(at: 12))
        if padCLength > 0 {
            _ = decryptCipher!.update(try await stream.read(exactly: padCLength))
        }
        let iaLengthData = decryptCipher!.update(try await stream.read(exactly: 2))
        let iaLength = Int(iaLengthData.readUInt16BE(at: 0))
        if iaLength > 0 {
            // The initiator may embed the BitTorrent handshake in IA. Decrypt and hand it back.
            let ia = decryptCipher!.update(try await stream.read(exactly: iaLength))
            // Buffer it for the payload parser by replaying through the stream's decrypted path.
            stream.injectDecrypted(ia)
        }

        // step 4: select RC4 if offered, else plaintext.
        let wantPlaintext = provide & 0x01 != 0 && provide & 0x02 == 0
        let select: UInt32 = wantPlaintext ? 0x01 : 0x02
        var step4Plaintext = Data(repeating: 0, count: 8) // VC
        step4Plaintext.appendUInt32BE(select)
        let padD = randomPad()
        step4Plaintext.appendUInt16BE(UInt16(padD.count))
        step4Plaintext.append(padD)
        let encryptedStep4 = encryptCipher!.update(step4Plaintext)
        try await stream.send(encryptedStep4)

        method = select == 0x02 ? .rc4 : .plaintext
        installCiphers()
    }

    private func receiveStep4() async throws {
        guard let decryptCipher else { throw MSEError.closed }
        // The peer's step 4 is ENCRYPT(VC, ...) using its encrypt key = our decrypt key.
        // Resync on the encrypted VC pattern (search the raw stream for decrypt(VC)).
        let vcCipher = decryptCipher.update(Data(repeating: 0, count: 8))
        try await stream.readUntil(pattern: vcCipher, maxBytes: 512)
        let body = decryptCipher.update(try await stream.read(exactly: 6))
        let select = body.readUInt32BE(at: 0)
        guard select == 0x01 || select == 0x02 else {
            throw MSEError.noCryptoMethod
        }
        let padDLength = Int(body.readUInt16BE(at: 4))
        if padDLength > 0 {
            _ = decryptCipher.update(try await stream.read(exactly: padDLength))
        }
        method = select == 0x02 ? .rc4 : .plaintext
        installCiphers()
    }

    private func installCiphers() {
        let encrypt = encryptCipher!
        let decrypt = decryptCipher!
        if method == .rc4 {
            stream.enableEncryption(encrypt: { encrypt.update($0) }, decrypt: { decrypt.update($0) })
        } else {
            stream.enableEncryption(encrypt: { $0 }, decrypt: { $0 })
        }
    }

    /// Reads the 96-byte DH public key, tolerating trailing pad bytes. If the peer instead sends
    /// a plaintext handshake (first byte 19, "BitTorrent protocol"), throw `.plaintextFallback`.
    private func readUntilPeerPublicKey() async throws -> Data {
        let first = try await stream.read(exactly: 1)
        if first[0] == 19 {
            // Plaintext handshake; restore it and let the caller fall back.
            stream.unread(first)
            throw MSEError.plaintextFallback
        }
        var data = first
        data.append(try await stream.read(exactly: 95))
        return data
    }

    private func randomPad() -> Data {
        let length = Int.random(in: 0...511)
        return Data((0..<length).map { _ in UInt8.random(in: 0...255) })
    }

    private func sha1(_ parts: Data...) -> Data {
        var hasher = Insecure.SHA1()
        for part in parts {
            hasher.update(data: part)
        }
        return Data(hasher.finalize())
    }
}
