import Foundation

/// µTP (BEP 29) protocol constants and wire codec.
public enum UTP {
    public static let version: UInt8 = 1

    public enum PacketType: UInt8, Sendable {
        case data = 0
        case fin = 1
        case state = 2
        case reset = 3
        case syn = 4
    }

    public enum ConnectionState: Int, Sendable {
        case idle = 0
        case synSent = 1
        case synRecv = 2
        case connected = 3
        case reset = 4
        case destroy = 5
    }

    /// Extension header types.
    public enum Extension: UInt8, Sendable {
        case none = 0
        case selectiveAck = 1
        case extensionBits = 2
        case socketRead = 3
        case socketWrite = 4
    }

    public static let headerSize = 20
    /// Maximum packet size we send (base + extensions + payload). libutp default MTU-derived.
    public static let maxPacketSize = 1400
    public static let seqNrMask: UInt16 = 0xFFFF

    public struct Packet: Sendable {
        public var type: PacketType
        public var connectionID: UInt16
        public var timestamp: UInt32
        public var replyMicro: UInt32
        public var windowSize: UInt32
        public var seqNr: UInt16
        public var ackNr: UInt16
        /// Parsed extensions: SACK bitmask bytes (nil if none).
        public var sack: [UInt8]?
        public var extensionBits: [UInt8]?
        public var payload: Data

        public init(type: PacketType, connectionID: UInt16, timestamp: UInt32, replyMicro: UInt32, windowSize: UInt32, seqNr: UInt16, ackNr: UInt16, sack: [UInt8]? = nil, payload: Data = Data()) {
            self.type = type
            self.connectionID = connectionID
            self.timestamp = timestamp
            self.replyMicro = replyMicro
            self.windowSize = windowSize
            self.seqNr = seqNr
            self.ackNr = ackNr
            self.sack = sack
            self.payload = payload
            self.extensionBits = nil
        }

        public var isSYN: Bool { type == .syn }
        public var isFIN: Bool { type == .fin }
        public var isData: Bool { type == .data }
        public var isState: Bool { type == .state }
        public var isReset: Bool { type == .reset }
    }

    /// Encodes a packet. `extensionBits`/`sack` are emitted as extension headers when present.
    /// Extension headers are a linked list: each entry's type byte names the NEXT extension in the
    /// chain, terminating with `none` (0). Matches libutp's `write_outgoing_packet` + `send_ack`.
    public static func encode(_ packet: Packet) -> Data {
        var out = Data()
        let versionType = (packet.type.rawValue << 4) | version
        out.append(versionType)

        var extFirst: UInt8 = Extension.none.rawValue
        var extData = Data()
        let sack = packet.sack
        if let bits = packet.extensionBits {
            // extension_bits (2) first, then SACK (1) when present.
            extFirst = Extension.extensionBits.rawValue
            extData.append(sack == nil ? Extension.none.rawValue : Extension.selectiveAck.rawValue)
            extData.append(UInt8(bits.count))
            extData.append(contentsOf: bits)
            if let sack {
                extData.append(Extension.none.rawValue)
                extData.append(UInt8(sack.count))
                extData.append(contentsOf: sack)
            }
        } else if let sack {
            extFirst = Extension.selectiveAck.rawValue
            extData.append(Extension.none.rawValue)
            extData.append(UInt8(sack.count))
            extData.append(contentsOf: sack)
        }

        out.append(extFirst)
        out.appendUInt16BE(packet.connectionID)
        out.appendUInt32BE(packet.timestamp)
        out.appendUInt32BE(packet.replyMicro)
        out.appendUInt32BE(packet.windowSize)
        out.appendUInt16BE(packet.seqNr)
        out.appendUInt16BE(packet.ackNr)
        out.append(extData)
        out.append(packet.payload)
        return out
    }

    /// Decodes a packet. Returns nil on malformed input.
    public static func decode(_ data: Data) -> Packet? {
        guard data.count >= headerSize else { return nil }
        let versionType = data[0]
        let type = PacketType(rawValue: versionType >> 4)
        guard type != nil else { return nil }
        var offset = 1
        let extFirst = data[offset]; offset += 1
        let connectionID = data.readUInt16BE(at: offset); offset += 2
        let timestamp = data.readUInt32BE(at: offset); offset += 4
        let replyMicro = data.readUInt32BE(at: offset); offset += 4
        let windowSize = data.readUInt32BE(at: offset); offset += 4
        let seqNr = data.readUInt16BE(at: offset); offset += 2
        let ackNr = data.readUInt16BE(at: offset); offset += 2

        var sack: [UInt8]?
        var extensionBits: [UInt8]?
        var ext = extFirst
        while ext != 0 {
            guard offset + 2 <= data.count else { return nil }
            let extType = ext
            let extLen = Int(data[offset + 1])
            guard offset + 2 + extLen <= data.count else { return nil }
            let extPayload = [UInt8](data[(offset + 2)..<(offset + 2 + extLen)])
            switch Extension(rawValue: extType) {
            case .selectiveAck:
                sack = extPayload
            case .extensionBits:
                extensionBits = extPayload
            default:
                break
            }
            ext = data[offset]
            offset += 2 + extLen
        }
        let payload = Data(data[offset...])
        var packet = Packet(type: type!, connectionID: connectionID, timestamp: timestamp, replyMicro: replyMicro, windowSize: windowSize, seqNr: seqNr, ackNr: ackNr, sack: sack, payload: payload)
        packet.extensionBits = extensionBits
        return packet
    }
}
