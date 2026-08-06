import Foundation

public struct PeerAddress: Hashable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public init(ipv4Bytes: [UInt8], port: UInt16) {
        let host = ipv4Bytes.map { String($0) }.joined(separator: ".")
        self.init(host: host, port: port)
    }

    public init(ipv6Bytes: [UInt8], port: UInt16) {
        var components: [String] = []
        var index = 0
        while index < 16 {
            let word = (UInt16(ipv6Bytes[index]) << 8) | UInt16(ipv6Bytes[index + 1])
            components.append(String(format: "%x", word))
            index += 2
        }
        let host = components.joined(separator: ":")
        self.init(host: host, port: port)
    }
}
