import Foundation

enum UTP {
    static let version: UInt8 = 1
    static let headerSize = 20
    static let maxPacketSize = 1400

    enum PacketType: UInt8, Sendable {
        case data = 0
        case fin = 1
        case state = 2
        case reset = 3
        case syn = 4
    }

    enum ConnectionState: Sendable {
        case synSent
        case synRecv
        case connected
        case reset
    }

    private static let noExtension: UInt8 = 0
    private static let selectiveAckExtension: UInt8 = 1

    struct Packet: Sendable {
        var type: PacketType
        var connectionID: UInt16
        var timestamp: UInt32
        var replyMicro: UInt32
        var windowSize: UInt32
        var seqNr: UInt16
        var ackNr: UInt16
        var sack: [UInt8]? = nil
        var payload = Data()
    }

    static func encode(_ packet: Packet) -> Data {
        var out = Data()
        out.append(packet.type.rawValue << 4 | version)
        out.append(packet.sack == nil ? noExtension : selectiveAckExtension)
        out.appendUInt16BE(packet.connectionID)
        out.appendUInt32BE(packet.timestamp)
        out.appendUInt32BE(packet.replyMicro)
        out.appendUInt32BE(packet.windowSize)
        out.appendUInt16BE(packet.seqNr)
        out.appendUInt16BE(packet.ackNr)
        if let sack = packet.sack {
            out.append(noExtension)
            out.append(UInt8(sack.count))
            out.append(contentsOf: sack)
        }
        out.append(packet.payload)
        return out
    }

    static func decode(_ data: Data) -> Packet? {
        guard data.count >= headerSize, let type = PacketType(rawValue: data[data.startIndex] >> 4) else { return nil }
        var packet = Packet(
            type: type,
            connectionID: data.readUInt16BE(at: 2),
            timestamp: data.readUInt32BE(at: 4),
            replyMicro: data.readUInt32BE(at: 8),
            windowSize: data.readUInt32BE(at: 12),
            seqNr: data.readUInt16BE(at: 16),
            ackNr: data.readUInt16BE(at: 18)
        )
        var offset = headerSize
        var ext = data[data.startIndex + 1]
        while ext != noExtension {
            guard offset + 2 <= data.count else { return nil }
            let start = data.startIndex + offset
            let length = Int(data[start + 1])
            guard offset + 2 + length <= data.count else { return nil }
            if ext == selectiveAckExtension {
                packet.sack = [UInt8](data[(start + 2)..<(start + 2 + length)])
            }
            ext = data[start]
            offset += 2 + length
        }
        packet.payload = Data(data.dropFirst(offset))
        return packet
    }
}
