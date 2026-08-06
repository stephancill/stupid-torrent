import Foundation

public enum PeerWireError: Error, Sendable, Equatable {
    case invalidHandshake
    case wrongInfoHash
    case wrongLength
    case unknownMessage
}

public enum PeerMessageID: UInt8, Sendable {
    case choke = 0
    case unchoke = 1
    case interested = 2
    case notInterested = 3
    case have = 4
    case bitfield = 5
    case request = 6
    case piece = 7
    case cancel = 8
    case port = 9
    case extended = 20
}

public struct Block: Equatable, Sendable {
    public let index: Int
    public let begin: Int
    public let length: Int

    public init(index: Int, begin: Int, length: Int) {
        self.index = index
        self.begin = begin
        self.length = length
    }
}

public enum PeerMessage: Equatable, Sendable {
    case choke
    case unchoke
    case interested
    case notInterested
    case have(Int)
    case bitfield(Data)
    case request(Block)
    case piece(Block, Data)
    case cancel(Block)
    case port(UInt16)
    case extended(UInt8, Data)

    public var messageID: PeerMessageID {
        switch self {
        case .choke: .choke
        case .unchoke: .unchoke
        case .interested: .interested
        case .notInterested: .notInterested
        case .have: .have
        case .bitfield: .bitfield
        case .request: .request
        case .piece: .piece
        case .cancel: .cancel
        case .port: .port
        case .extended: .extended
        }
    }

    public static let blockSize = 16 * 1024

    public func encode() -> Data {
        var payload = Data()
        payload.append(messageID.rawValue)
        switch self {
        case .choke, .unchoke, .interested, .notInterested:
            break
        case .have(let index):
            payload.appendInt32(index)
        case .bitfield(let bits):
            payload.append(bits)
        case .request(let block), .cancel(let block):
            payload.appendInt32(block.index)
            payload.appendInt32(block.begin)
            payload.appendInt32(block.length)
        case .piece(let block, let data):
            payload.appendInt32(block.index)
            payload.appendInt32(block.begin)
            payload.append(data)
        case .port(let port):
            payload.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xFF)])
        case .extended(let extendedID, let data):
            payload.append(extendedID)
            payload.append(data)
        }
        var frame = Data()
        frame.appendUInt32(UInt32(payload.count))
        frame.append(payload)
        return frame
    }

    /// Decodes one message from a length-prefixed frame. `length` is the 4-byte big-endian
    /// prefix (the payload byte count); `body` must contain exactly `length` bytes.
    public static func decode(length: Int, body: Data) throws -> PeerMessage {
        guard body.count == length else { throw PeerWireError.wrongLength }
        guard length > 0 else { throw PeerWireError.unknownMessage } // keepalive
        guard let id = PeerMessageID(rawValue: body[0]) else {
            throw PeerWireError.unknownMessage
        }
        let payload = Data(body.dropFirst())
        switch id {
        case .choke: return .choke
        case .unchoke: return .unchoke
        case .interested: return .interested
        case .notInterested: return .notInterested
        case .have:
            guard payload.count == 4 else { throw PeerWireError.unknownMessage }
            return .have(payload.int32(at: 0))
        case .bitfield:
            return .bitfield(Data(payload))
        case .request, .cancel:
            guard payload.count == 12 else { throw PeerWireError.unknownMessage }
            let block = Block(index: payload.int32(at: 0), begin: payload.int32(at: 4), length: payload.int32(at: 8))
            return id == .request ? .request(block) : .cancel(block)
        case .piece:
            guard payload.count >= 8 else { throw PeerWireError.unknownMessage }
            let block = Block(index: payload.int32(at: 0), begin: payload.int32(at: 4), length: payload.count - 8)
            return .piece(block, Data(payload.dropFirst(8)))
        case .port:
            guard payload.count == 2 else { throw PeerWireError.unknownMessage }
            let port = (UInt16(payload[0]) << 8) | UInt16(payload[1])
            return .port(port)
        case .extended:
            guard payload.count >= 1 else { throw PeerWireError.unknownMessage }
            return .extended(payload[0], Data(payload.dropFirst()))
        }
    }
}

public struct Handshake: Equatable, Sendable {
    public let reserved: Data
    public let infoHash: Data
    public let peerID: Data

    public static let protocolString = "BitTorrent protocol"
    public static let length = 1 + 19 + 8 + 20 + 20 // 68

    public var supportsExtensions: Bool {
        reserved.count == 8 && (reserved[5] & 0x10) != 0
    }

    public var supportsDHT: Bool {
        reserved.count == 8 && (reserved[7] & 0x01) != 0
    }

    public init(reserved: Data, infoHash: Data, peerID: Data) {
        self.reserved = reserved
        self.infoHash = infoHash
        self.peerID = peerID
    }

    public static func make(extensionEnabled: Bool = true, dhtEnabled: Bool = false, infoHash: Data, peerID: Data) -> Handshake {
        var reserved = Data(repeating: 0, count: 8)
        if extensionEnabled { reserved[5] |= 0x10 }
        if dhtEnabled { reserved[7] |= 0x01 }
        return Handshake(reserved: reserved, infoHash: infoHash, peerID: peerID)
    }

    public func encode() -> Data {
        var data = Data()
        data.append(UInt8(Self.protocolString.utf8.count))
        data.append(Data(Self.protocolString.utf8))
        data.append(reserved)
        data.append(infoHash)
        data.append(peerID)
        return data
    }

    public static func parse(_ data: Data) throws -> Handshake {
        guard data.count >= length else { throw PeerWireError.invalidHandshake }
        let pstrlen = Int(data[0])
        guard pstrlen == protocolString.utf8.count else { throw PeerWireError.invalidHandshake }
        let protocolBytes = data.subdata(in: 1..<(1 + pstrlen))
        guard String(decoding: protocolBytes, as: UTF8.self) == protocolString else {
            throw PeerWireError.invalidHandshake
        }
        let reserved = data.subdata(in: (1 + pstrlen)..<(1 + pstrlen + 8))
        let infoHash = data.subdata(in: (1 + pstrlen + 8)..<(1 + pstrlen + 8 + 20))
        let peerID = data.subdata(in: (1 + pstrlen + 8 + 20)..<(1 + pstrlen + 8 + 20 + 20))
        return Handshake(reserved: reserved, infoHash: infoHash, peerID: peerID)
    }
}

extension Data {
    mutating func appendInt32(_ value: Int) {
        appendUInt32(UInt32(truncatingIfNeeded: value))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}

extension Data {
    /// Big-endian int32 at `offset`, safe for Data slices (uses `startIndex`-relative indexing).
    func int32(at offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        let b0 = self[base], b1 = self[base + 1], b2 = self[base + 2], b3 = self[base + 3]
        return Int(UInt32(b0) << 24 | UInt32(b1) << 16 | UInt32(b2) << 8 | UInt32(b3))
    }
}
