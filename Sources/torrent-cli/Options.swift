import Foundation
import TorrentCore

struct OptionError: Error, CustomStringConvertible {
    let description: String
}

struct CommonOptions {
    var dir = FileManager.default.currentDirectoryPath + "/downloads"
    var peer: PeerAddress?
    var stopAt: Int64?

    init(parsing arguments: ArraySlice<String>, allowed: Set<String>) throws {
        var remaining = arguments[...]
        while let flag = remaining.popFirst() {
            guard allowed.contains(flag) else { throw OptionError(description: "unknown option \(flag)") }
            if flag == "--verbose" {
                TorrentLog.verbose = true
                continue
            }
            guard let value = remaining.popFirst() else { throw OptionError(description: "\(flag) needs a value") }
            switch flag {
            case "--dir":
                dir = value
            case "--peer":
                peer = try Self.peerAddress(value)
            case "--stop-at":
                guard let bytes = Int64(value) else { throw OptionError(description: "invalid --stop-at \(value)") }
                stopAt = bytes
            default:
                throw OptionError(description: "unknown option \(flag)")
            }
        }
    }

    private static func peerAddress(_ value: String) throws -> PeerAddress {
        let parts = value.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else {
            throw OptionError(description: "invalid --peer \(value), expected host:port")
        }
        return PeerAddress(host: String(parts[0]), port: port)
    }
}
