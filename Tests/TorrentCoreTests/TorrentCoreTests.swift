import Testing
import Foundation
import CryptoKit
import Bencode
import TorrentCore
import TorrentTestingSupport

@testable import TorrentCore

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

@Suite struct MetadataExchangeTests {
    @Test func extendedHandshakeAdvertisesUtMetadata() {
        let message = ExtendedHandshake.message(client: "stupid-torrent-client/0.1", port: 6881)
        guard case .extended(let extID, let payload) = message else {
            Issue.record("expected extended message")
            return
        }
        #expect(extID == 0)
        #expect(ExtendedHandshake.utMetadataID(from: payload) == 1)
    }

    @Test func metadataRequestEncoding() {
        let message = MetadataMessage.request(id: 9, piece: 3)
        guard case .extended(let extID, let payload) = message else {
            Issue.record("expected extended message")
            return
        }
        #expect(extID == 9)
        #expect(payload == Data("d8:msg_typei0e5:piecei3ee".utf8))
    }

    @Test func metadataDataParsing() throws {
        let chunk = Data(repeating: 0xAB, count: 10)
        var payload = Data("d8:msg_typei1e5:piecei0e10:total_sizei52428800ee".utf8)
        payload.append(chunk)
        let data = try MetadataMessage.parseData(payload)
        #expect(data?.piece == 0)
        #expect(data?.totalSize == 52_428_800)
        #expect(data?.chunk == chunk)
    }

    @Test func fixtureInfoDictChunksAssembleAndHash() throws {
        let data = try Fixtures.bigBuckBunnyTorrentData
        let infoDict = try Bencode.rawValue(forKey: "info", in: data)

        var chunks: [Data] = []
        var cursor = 0
        while cursor < infoDict.count {
            let end = min(cursor + 16_384, infoDict.count)
            chunks.append(Data(infoDict[cursor..<end]))
            cursor = end
        }
        var assembled = Data()
        for chunk in chunks { assembled.append(chunk) }
        #expect(assembled == infoDict)

        let meta = try Metainfo(infoDict: infoDict, trackers: [[URL(string: "udp://tracker.test:1")!]])
        #expect(meta.infoHash.hexString == "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")
        #expect(meta.pieceCount == 1055)
        #expect(meta.totalLength == 276_445_467)
    }
}

@Suite struct PeerWireTests {
    @Test func requestEncodingMatchesGoldenBytes() {
        let message = PeerMessage.request(Block(index: 0, begin: 0, length: 16_384))
        #expect(message.encode() == Data([0x00, 0x00, 0x00, 0x0D, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00]))
    }

    @Test func interestedEncoding() {
        #expect(PeerMessage.interested.encode() == Data([0x00, 0x00, 0x00, 0x01, 0x02]))
    }

    @Test func decodeRoundTrips() throws {
        let messages: [PeerMessage] = [
            .choke,
            .unchoke,
            .interested,
            .notInterested,
            .have(5),
            .bitfield(Data([0xFF, 0x00])),
            .request(Block(index: 1, begin: 2, length: 3)),
            .cancel(Block(index: 4, begin: 5, length: 6)),
            .piece(Block(index: 7, begin: 8, length: 3), Data([9, 10, 11])),
            .port(6881),
        ]
        for message in messages {
            let frame = message.encode()
            let length = Int(frame.readUInt32BE(at: 0))
            let body = frame.dropFirst(4)
            #expect(try PeerMessage.decode(length: length, body: Data(body)) == message)
        }
    }

    @Test func handshakeStructure() throws {
        let hash = Data(repeating: 0xAB, count: 20)
        let id = Data(repeating: 0xCD, count: 20)
        let hs = Handshake.make(extensionEnabled: true, infoHash: hash, peerID: id)
        let encoded = hs.encode()
        #expect(encoded.count == 68)
        #expect(encoded[0] == 19)
        #expect(String(decoding: encoded[1..<20], as: UTF8.self) == "BitTorrent protocol")
        #expect(encoded[25] & 0x10 != 0) // extension bit
        let parsed = try Handshake.parse(encoded)
        #expect(parsed.infoHash == hash)
        #expect(parsed.peerID == id)
        #expect(parsed.supportsExtensions)
    }

    @Test func pieceEncodingIncludesIndexBegin() throws {
        let message = PeerMessage.piece(Block(index: 0, begin: 16_384, length: 8), Data(repeating: 1, count: 8))
        let frame = message.encode()
        let length = Int(frame.readUInt32BE(at: 0))
        let body = frame.dropFirst(4)
        #expect(length == 17) // id + 12 + 4-byte data... id(1)+index(4)+begin(4)+len implied(0)+data(8) = 17
        let decoded = try PeerMessage.decode(length: length, body: Data(body))
        #expect(decoded == message)
    }
}

@Suite struct BitfieldTests {
    @Test func roundTripsThroughWireFormat() {
        let bits = [true, false, true, true, false, false, false, true, false, true] // 10 bits
        let bf = Bitfield(bits: bits)
        #expect(bf.count == 10)
        #expect(bf.setCount == 5)
        let data = bf.data()
        #expect(data.count == 2)
        let back = Bitfield.from(data, count: 10)
        #expect(back.bits == bits)
    }

    @Test func partialBytePaddingIsIgnored() {
        // 10 pieces -> 2 bytes; the 6 high bits of the last byte are padding.
        let bf = Bitfield(bits: [true, false, true, true, false, false, false, true, false, true])
        let back = Bitfield.from(bf.data(), count: 10)
        #expect(back.bits == bf.bits)
        #expect(back[9] == true)
    }
}

@Suite struct StorageTests {
    @Test func loadVerifiedCountReadsSidecar() throws {
        let metainfo = try Metainfo(data: try Fixtures.bigBuckBunnyTorrentData)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // No sidecar yet -> 0.
        #expect(Storage.loadVerifiedCount(directory: dir, infoHash: metainfo.infoHash, pieceCount: metainfo.pieceCount) == 0)

        // Full sidecar -> complete.
        var full = Data()
        full.appendUInt32BE(UInt32(metainfo.pieceCount))
        full.append(Bitfield(bits: [Bool](repeating: true, count: metainfo.pieceCount)).data())
        try full.write(to: dir.appendingPathComponent(".\(metainfo.infoHash.hexString).verified"))
        #expect(Storage.loadVerifiedCount(directory: dir, infoHash: metainfo.infoHash, pieceCount: metainfo.pieceCount) == metainfo.pieceCount)

        // Half sidecar -> half.
        var half = Data()
        let halfCount = metainfo.pieceCount / 2
        half.appendUInt32BE(UInt32(metainfo.pieceCount))
        half.append(Bitfield(bits: (0..<metainfo.pieceCount).map { $0 < halfCount }).data())
        try half.write(to: dir.appendingPathComponent(".\(metainfo.infoHash.hexString).verified"))
        #expect(Storage.loadVerifiedCount(directory: dir, infoHash: metainfo.infoHash, pieceCount: metainfo.pieceCount) == halfCount)
    }
}

@Suite struct PiecePickerTests {
    @Test func walksPiecesInOrder() {
        var picker = PiecePicker(pieceCount: 5, verified: [false, false, false, false, false])
        #expect(picker.nextPiece() == 0)
        #expect(picker.nextPiece() == 1)
        picker.markVerified(1)
        #expect(picker.nextPiece() == 2)
    }

    @Test func higherPriorityLevelJumpsAheadOfLowerIndexPieces() {
        var picker = PiecePicker(pieceCount: 13, verified: [false, false, false, false, false, false, false, false, false, false, false, false, false])
        picker.setPriority(12, level: 10) // moov tail piece
        picker.setPriority(0, level: 0)   // current window
        picker.setPriority(1, level: 0)
        // Level 10 is served before level 0, even though piece 12 has a higher index.
        #expect(picker.nextPiece() == 12)
        picker.markRequested(12)
        // Then the window, lowest index first.
        #expect(picker.nextPiece() == 0)
        picker.markRequested(0)
        #expect(picker.nextPiece() == 1)
    }

    @Test func verifiedPieceLeavesPriority() {
        var picker = PiecePicker(pieceCount: 3, verified: [false, false, false])
        picker.setPriority(2, level: 10)
        picker.markRequested(2)
        picker.markVerified(2)
        // With the priority piece gone, the sequential cursor walk takes over.
        #expect(picker.nextPiece() == 0)
    }

    @Test func lowerLevelUsedWhenHigherLevelExhausted() {
        var picker = PiecePicker(pieceCount: 5, verified: [false, false, false, false, false])
        picker.setPriority(0, level: 10)
        picker.setPriority(3, level: 5)
        picker.markRequested(0)
        #expect(picker.nextPiece() == 3)
    }

    @Test func setPriorityKeepsHighestLevel() {
        var picker = PiecePicker(pieceCount: 5, verified: [false, false, false, false, false])
        picker.setPriority(2, level: 0)
        picker.setPriority(2, level: 10) // seek/jump re-prioritizes
        #expect(picker.priority[2] == 10)
        picker.setPriority(2, level: 0) // window request must not downgrade
        #expect(picker.priority[2] == 10)
        #expect(picker.nextPiece() == 2)
    }

    @Test func setPrioritySkipsVerifiedPieces() {
        var picker = PiecePicker(pieceCount: 5, verified: [false, true, false, false, false])
        picker.setPriority(1, level: 10)
        #expect(picker.priority[1] == nil)
        #expect(picker.nextPiece() == 0)
    }
}

@Suite struct MetainfoTests {
    @Test func parsesBigBuckBunnyFixture() throws {
        let info = try Metainfo(data: try Fixtures.bigBuckBunnyTorrentData)
        #expect(info.infoHash.hexString == "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")
        #expect(info.name == "Big Buck Bunny")
        #expect(info.pieceLength == 262144)
        #expect(info.pieceCount == 1055)
        #expect(info.files.map(\.name) == ["Big Buck Bunny.en.srt", "Big Buck Bunny.mp4", "poster.jpg"])
        #expect(info.files.map(\.length) == [140, 276_134_947, 310_380])
        #expect(info.totalLength == 276_445_467)
        #expect(!info.isPrivate)
    }

    @Test func parsesFixtureTrackers() throws {
        let info = try Metainfo(data: try Fixtures.bigBuckBunnyTorrentData)
        #expect(info.trackerTiers.count == 8)
        let hosts = info.flattenedTrackers.map(\.host)
        #expect(hosts.contains("tracker.opentrackr.org"))
        #expect(hosts.contains("explodie.org"))
    }

    @Test func persistedMagnetMetadataRoundTrips() throws {
        let fixture = try Fixtures.bigBuckBunnyTorrentData
        let source = try Metainfo(data: fixture)
        let metadata = try Metainfo(
            infoDict: source.infoDict,
            trackers: source.trackerTiers,
            displayName: "Big Buck Bunny Magnet"
        )
        let restored = try Metainfo(data: metadata.torrentData())

        #expect(restored.infoHash == source.infoHash)
        #expect(restored.name == source.name)
        #expect(restored.displayName == "Big Buck Bunny Magnet")
        #expect(restored.pieceCount == source.pieceCount)
        #expect(restored.trackerTiers == source.trackerTiers)
    }

    @Test func mapsPiecesToFilesAcrossBoundaries() throws {
        let info = try Metainfo(data: try Fixtures.bigBuckBunnyTorrentData)
        // srt occupies bytes 0..140, which is inside piece 0; mp4 starts at 140.
        #expect(info.location(piece: 0, pieceOffset: 0)?.fileIndex == 0)
        #expect(info.location(piece: 0, pieceOffset: 139)?.fileIndex == 0)
        #expect(info.location(piece: 0, pieceOffset: 140)?.fileIndex == 1)
        #expect(info.location(piece: 0, pieceOffset: 141)?.fileIndex == 1)
        #expect(info.location(piece: 0, pieceOffset: 1000)?.fileOffset == 860)
        // poster starts at 276135087, mid-piece 1053 (a piece spanning mp4 -> poster).
        #expect(info.byteRange(ofFileAt: 1) == 140..<276_135_087)
        let posterStart = info.location(piece: 1053, pieceOffset: 97_455)
        #expect(posterStart?.fileIndex == 2)
        #expect(posterStart?.fileOffset == 0)
        #expect(info.pieceRange(forByteRange: 140..<276_135_087) == 0..<1054)
        #expect(info.location(piece: 1055) == nil)
    }
}

@Suite struct MagnetTests {
    @Test func parsesBigBuckBunnyMagnet() throws {
        let magnet = "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big+Buck+Bunny&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Fexplodie.org%3A6969%2Fannounce&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce"
        let link = try MagnetLinkParser.parse(magnet)
        #expect(link.infoHash.hexString == "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")
        #expect(link.displayName == "Big Buck Bunny")
        #expect(link.trackers.count == 4)
        #expect(link.trackers.map(\.host).contains("tracker.opentrackr.org"))
        #expect(link.trackers.map(\.port).contains(1337))
    }

    @Test func parsesBase32InfoHash() throws {
        let link = try MagnetLinkParser.parse("magnet:?xt=urn:btih:3WBFL3G4PSSV7MF37AJSHWDQMLNR63I4")
        #expect(link.infoHash.hexString == "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")
    }

    @Test func rejectsInvalidMagnets() {
        #expect(throws: MagnetError.self) { try MagnetLinkParser.parse("http://example.com") }
        #expect(throws: MagnetError.self) { try MagnetLinkParser.parse("magnet:?dn=noinfohash") }
    }
}

@Suite struct DHTTests {
    @Test func pingRoundTrips() throws {
        let id = Data(repeating: 0x42, count: 20)
        let txn = Data([0xAB, 0xCD])
        let packet = KRPCWire.encode(query: .ping(id: id), transaction: txn)
        let message = try KRPCWire.decode(packet)
        guard case .query(let transaction, let name, let args) = message else {
            Issue.record("expected query")
            return
        }
        #expect(transaction == txn)
        #expect(name == "ping")
        #expect(args["id"]?.stringValue == id)
    }

    @Test func getPeersRoundTrips() throws {
        let id = Data(repeating: 0x11, count: 20)
        let infoHash = Data(repeating: 0x22, count: 20)
        let txn = Data([0x01, 0x02])
        let packet = KRPCWire.encode(query: .getPeers(id: id, infoHash: infoHash), transaction: txn)
        let message = try KRPCWire.decode(packet)
        guard case .query(_, let name, let args) = message else {
            Issue.record("expected query")
            return
        }
        #expect(name == "get_peers")
        #expect(args["info_hash"]?.stringValue == infoHash)
    }

    @Test func responseRoundTrips() throws {
        let txn = Data([0x07, 0x08])
        let nodeID = Data(repeating: 0x33, count: 20)
        let peer = Data([192, 168, 1, 10, 0x1A, 0xE1])
        let packet = KRPCWire.encodeResponse(transaction: txn, reply: [
            "id": .string(nodeID),
            "token": .string(Data([0x01, 0x02, 0x03])),
            "values": .list([.string(peer)]),
        ])
        let message = try KRPCWire.decode(packet)
        guard case .response(let transaction, let reply) = message else {
            Issue.record("expected response")
            return
        }
        #expect(transaction == txn)
        #expect(reply["id"]?.stringValue == nodeID)
        guard case .list(let values)? = reply["values"], let first = values.first?.stringValue else {
            Issue.record("missing values")
            return
        }
        #expect(CompactPeer.parse(first) == [PeerAddress(host: "192.168.1.10", port: 6881)])
    }

    @Test func compactNodeRoundTrip() {
        let node = KRPCNodeInfo(id: Data(repeating: 0x55, count: 20), host: "10.0.0.1", port: 51413)
        let parsed = CompactNode.parse(CompactNode.encode([node]))
        #expect(parsed == [node])
    }

    @Test func routingTableClosestByXorDistance() {
        let localID = Data(repeating: 0x00, count: 20)
        let table = RoutingTable(localID: localID, k: 2)
        let far = KRPCNodeInfo(id: Data([0x80] + Array(repeating: 0x00, count: 19)), host: "a", port: 1)
        let near = KRPCNodeInfo(id: Data([0x01] + Array(repeating: 0x00, count: 19)), host: "b", port: 2)
        table.add(far)
        table.add(near)
        let target = Data([0x02] + Array(repeating: 0x00, count: 19))
        let closest = table.closest(to: target, count: 1)
        #expect(closest.first?.id == near.id)
    }
}

@Suite struct MSETests {
    @Test func rc4RoundTrips() {
        let key = Data((1...32).map { UInt8($0) })
        let plain = Data("The quick brown fox jumps over the lazy dog".utf8)
        let cipher = RC4(key: key)
        let encrypted = cipher.update(plain)
        let decrypted = RC4(key: key).update(encrypted)
        #expect(decrypted == plain)
    }

    @Test func rc4MatchesPythonReference() {
        // First byte of RC4(key=1..32) after the 1024-byte keystream drop encrypting "A" (0x41).
        let key = Data((1...32).map { UInt8($0) })
        let out = RC4(key: key).update(Data("A".utf8))
        #expect(out.first == 0x3e)
    }

    @Test func dhPublicKeyMatchesPython() {
        // priv = 0x0123456789abcdef0123456789abcdef01234567
        let privateBytes: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67]
        let priv = BigUInt(bytes: Data(privateBytes.reversed()))
        let pub = DH.publicKey(for: priv)
        let expected = "6fd4bc7aa649593205ec30348a3ccc737b61fa01e9e1762c2c53eb69033afecbdf7c13b8ac3643af78d0760b0f42db009f2b96c970f009d060faf617f117d0f1c221cea0561b9a86e852fc70a6f09ad0f82378603aa5e56b811deb3f534bf276"
        #expect(pub.map { String(format: "%02x", $0) }.joined() == expected)
    }

    @Test func dhSharedSecretMatchesPython() {
        let privateBytes: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67]
        let priv = BigUInt(bytes: Data(privateBytes.reversed()))
        let peerPublic: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11, 0x22, 0x33, 0x44]
        var peerBytes = Data(repeating: 0, count: 76)
        peerBytes.append(contentsOf: peerPublic)
        let shared = DH.sharedSecret(privateKey: priv, peerPublic: peerBytes)
        let expected = "4d51a0f2a2454332ddc6b13a082f1aae8befbba7342d9286c93eb72bfefad8d52e9d3571227ac05325d52e3e4194d0ad8ff76ec40293c860479072880c57b369237a2a587c5bf19ea4fc64d14e4d57e7cdcb6487f7fc452d757019daee1c9682"
        #expect(shared.map { String(format: "%02x", $0) }.joined() == expected)
    }
}
