import Foundation
import Darwin

public struct PeerAddress: Hashable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    init(ipv4Bytes: some Collection<UInt8>, port: UInt16) {
        self.init(host: ipv4Bytes.map(String.init).joined(separator: "."), port: port)
    }

    init(ipv6Bytes: Data, port: UInt16) {
        let words = stride(from: 0, to: 16, by: 2).map { String(ipv6Bytes.readUInt16BE(at: $0), radix: 16) }
        self.init(host: words.joined(separator: ":"), port: port)
    }

    init(socketAddress: sockaddr_in) {
        self.init(
            ipv4Bytes: Swift.withUnsafeBytes(of: socketAddress.sin_addr.s_addr) { Array($0) },
            port: UInt16(bigEndian: socketAddress.sin_port)
        )
    }

    var ipv4Bytes: Data? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let bytes = parts.compactMap { UInt8($0) }
        guard parts.count == 4, bytes.count == 4 else { return nil }
        return Data(bytes)
    }

    static func parseCompact(_ data: Data) -> [PeerAddress] {
        parseEntries(data, stride: 6) { entry in
            PeerAddress(ipv4Bytes: entry.prefix(4), port: entry.readUInt16BE(at: 4))
        }
    }

    static func parseCompactIPv6(_ data: Data) -> [PeerAddress] {
        parseEntries(data, stride: 18) { entry in
            PeerAddress(ipv6Bytes: Data(entry.prefix(16)), port: entry.readUInt16BE(at: 16))
        }
    }

    static func encodeCompact(_ peers: [PeerAddress]) -> Data {
        peers.reduce(into: Data()) { out, peer in
            guard let bytes = peer.ipv4Bytes else { return }
            out.append(bytes)
            out.appendUInt16BE(peer.port)
        }
    }

    private static func parseEntries(_ data: Data, stride size: Int, parse: (Data) -> PeerAddress) -> [PeerAddress] {
        stride(from: 0, through: data.count - size, by: size).compactMap { offset in
            let start = data.startIndex + offset
            let peer = parse(data[start..<(start + size)])
            return peer.port == 0 ? nil : peer
        }
    }
}
