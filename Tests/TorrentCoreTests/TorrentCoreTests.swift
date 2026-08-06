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
