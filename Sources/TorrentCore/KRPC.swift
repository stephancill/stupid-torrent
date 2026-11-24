import Foundation
import Bencode

public enum KRPCError: Error, Sendable {
    case malformed(String)
    case errorResponse(code: Int, message: String)
}

public enum KRPC: Sendable {
    case query(transaction: Data, name: String, args: [String: BValue])
    case response(transaction: Data, reply: [String: BValue])
    case error(transaction: Data, code: Int, message: String)
}

public enum KRPCQuery: Sendable {
    case ping(id: Data)
    case findNode(id: Data, target: Data)
    case getPeers(id: Data, infoHash: Data)
    case announcePeer(id: Data, infoHash: Data, port: UInt16, token: Data)

    var name: String {
        switch self {
        case .ping: "ping"
        case .findNode: "find_node"
        case .getPeers: "get_peers"
        case .announcePeer: "announce_peer"
        }
    }

    var args: BValue {
        switch self {
        case .ping(let id):
            return .dictionary(["id": .string(id)])
        case .findNode(let id, let target):
            return .dictionary(["id": .string(id), "target": .string(target)])
        case .getPeers(let id, let infoHash):
            return .dictionary(["id": .string(id), "info_hash": .string(infoHash)])
        case .announcePeer(let id, let infoHash, let port, let token):
            return .dictionary([
                "id": .string(id),
                "info_hash": .string(infoHash),
                "port": .int(Int(port)),
                "token": .string(token),
            ])
        }
    }
}

public enum KRPCWire {
    public static func encode(query: KRPCQuery, transaction: Data) -> Data {
        Bencode.encode(.dictionary([
            "t": .string(transaction),
            "y": .string(Data("q".utf8)),
            "q": .string(Data(query.name.utf8)),
            "a": query.args,
        ]))
    }

    public static func encodeResponse(transaction: Data, reply: [String: BValue]) -> Data {
        Bencode.encode(.dictionary([
            "t": .string(transaction),
            "y": .string(Data("r".utf8)),
            "r": .dictionary(reply),
        ]))
    }

    public static func encodeError(transaction: Data, code: Int, message: String) -> Data {
        Bencode.encode(.dictionary([
            "t": .string(transaction),
            "y": .string(Data("e".utf8)),
            "e": .list([.int(code), .string(Data(message.utf8))]),
        ]))
    }

    public static func decode(_ data: Data) throws -> KRPC {
        let value: BValue
        do {
            value = try Bencode.decode(data)
        } catch {
            throw KRPCError.malformed("bencode: \(error)")
        }
        guard case .dictionary(let dict) = value else {
            throw KRPCError.malformed("not a dictionary")
        }
        guard let t = dict["t"]?.stringValue else {
            throw KRPCError.malformed("missing t")
        }
        guard let y = dict["y"]?.stringValueUTF8 else {
            throw KRPCError.malformed("missing y")
        }
        switch y {
        case "q":
            guard let name = dict["q"]?.stringValueUTF8, case .dictionary(let args)? = dict["a"] else {
                throw KRPCError.malformed("missing q/a")
            }
            return .query(transaction: t, name: name, args: args)
        case "r":
            guard case .dictionary(let reply)? = dict["r"] else {
                throw KRPCError.malformed("missing r")
            }
            return .response(transaction: t, reply: reply)
        case "e":
            guard case .list(let items)? = dict["e"], items.count >= 2,
                  let code = items[0].intValue, let message = items[1].stringValueUTF8 else {
                throw KRPCError.malformed("missing e")
            }
            return .error(transaction: t, code: code, message: message)
        default:
            throw KRPCError.malformed("unknown y \(y)")
        }
    }
}

public enum CompactNode {
    public static func encode(_ nodes: [KRPCNodeInfo]) -> Data {
        nodes.reduce(into: Data()) { out, node in
            guard let bytes = node.address.ipv4Bytes else { return }
            out.append(node.id)
            out.append(bytes)
            out.appendUInt16BE(node.port)
        }
    }

    public static func parse(_ data: Data) -> [KRPCNodeInfo] {
        stride(from: 0, through: data.count - 26, by: 26).compactMap { offset in
            let start = data.startIndex + offset
            guard let peer = PeerAddress.parseCompact(data[(start + 20)..<(start + 26)]).first else { return nil }
            return KRPCNodeInfo(id: Data(data[start..<(start + 20)]), host: peer.host, port: peer.port)
        }
    }
}
