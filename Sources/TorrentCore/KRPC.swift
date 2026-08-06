import Foundation
import Bencode

public enum KRPCError: Error, Sendable {
    case malformed(String)
    case errorResponse(code: Int, message: String)
    case timeout
    case closed
}

/// A single KRPC message on the wire (BEP 5). `args`/`reply` are the `a`/`r` dictionaries;
/// binary fields (id, info_hash, target, token, nodes, values) are `.string(Data)` values.
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

/// Compact node info (BEP 5): 20-byte node id + 4-byte IPv4 + 2-byte port.
public enum CompactNode {
    public static func encode(_ nodes: [KRPCNodeInfo]) -> Data {
        var out = Data()
        for node in nodes {
            out.append(node.id)
            if let bytes = ipv4Bytes(node.host) {
                out.append(bytes)
                out.appendUInt16BE(node.port)
            }
        }
        return out
    }

    public static func parse(_ data: Data) -> [KRPCNodeInfo] {
        var nodes: [KRPCNodeInfo] = []
        var offset = 0
        while offset + 26 <= data.count {
            let id = Data(data[offset..<(offset + 20)])
            let ip = [UInt8](data[(offset + 20)..<(offset + 24)])
            let port = data.readUInt16BE(at: offset + 24)
            if port != 0 {
                nodes.append(KRPCNodeInfo(id: id, host: ipv4String(ip), port: port))
            }
            offset += 26
        }
        return nodes
    }
}

/// Compact peer info (BEP 5): 4-byte IPv4 + 2-byte port.
public enum CompactPeer {
    public static func encode(_ peers: [PeerAddress]) -> Data {
        var out = Data()
        for peer in peers {
            if let bytes = ipv4Bytes(peer.host) {
                out.append(bytes)
                out.appendUInt16BE(peer.port)
            }
        }
        return out
    }

    public static func parse(_ data: Data) -> [PeerAddress] {
        var peers: [PeerAddress] = []
        var offset = 0
        while offset + 6 <= data.count {
            let ip = [UInt8](data[offset..<(offset + 4)])
            let port = data.readUInt16BE(at: offset + 4)
            if port != 0 {
                peers.append(PeerAddress(ipv4Bytes: ip, port: port))
            }
            offset += 6
        }
        return peers
    }
}

private func ipv4Bytes(_ host: String) -> Data? {
    var parts: [UInt8] = []
    for part in host.split(separator: ".") {
        guard let value = UInt8(part) else { return nil }
        parts.append(value)
    }
    guard parts.count == 4 else { return nil }
    return Data(parts)
}

private func ipv4String(_ bytes: [UInt8]) -> String {
    bytes.map(String.init).joined(separator: ".")
}
