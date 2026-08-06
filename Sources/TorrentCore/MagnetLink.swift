import Foundation

public enum MagnetError: Error, Sendable, Equatable {
    case notAMagnet
    case missingInfoHash
}

public struct MagnetLink: Sendable, Equatable {
    public let infoHash: Data
    public let displayName: String?
    public let trackers: [URL]
    public let exactSources: [URL]

    public init(infoHash: Data, displayName: String? = nil, trackers: [URL] = [], exactSources: [URL] = []) {
        self.infoHash = infoHash
        self.displayName = displayName
        self.trackers = trackers
        self.exactSources = exactSources
    }
}

public enum MagnetLinkParser {
    public static func parse(_ string: String) throws -> MagnetLink {
        guard let components = URLComponents(string: string), components.scheme?.lowercased() == "magnet" else {
            throw MagnetError.notAMagnet
        }

        var infoHash: Data?
        var displayName: String?
        var trackers: [URL] = []
        var exactSources: [URL] = []

        for item in components.queryItems ?? [] {
            let value = decoded(item.value)
            switch item.name.lowercased() {
            case "xt":
                if infoHash == nil,
                   let value,
                   value.lowercased().hasPrefix("urn:btih:") {
                    infoHash = decodeV1InfoHash(String(value.dropFirst("urn:btih:".count)))
                }
            case "dn":
                if displayName == nil {
                    displayName = value
                }
            case "tr":
                if let value, let url = URL(string: value) {
                    trackers.append(url)
                }
            case "xs":
                if let value, let url = URL(string: value) {
                    exactSources.append(url)
                }
            default:
                break
            }
        }

        guard let infoHash else { throw MagnetError.missingInfoHash }
        return MagnetLink(infoHash: infoHash, displayName: displayName, trackers: trackers, exactSources: exactSources)
    }

    private static func decoded(_ raw: String?) -> String? {
        // Mirrors Go's url.ParseQuery semantics (golden: anacrolix/torrent): '+' decodes to space.
        raw?.replacingOccurrences(of: "+", with: " ")
    }

    static func decodeV1InfoHash(_ encoded: String) -> Data? {
        switch encoded.count {
        case 40:
            var bytes: [UInt8] = []
            bytes.reserveCapacity(20)
            var index = encoded.startIndex
            while index < encoded.endIndex {
                let next = encoded.index(index, offsetBy: 2)
                guard let byte = UInt8(encoded[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            return Data(bytes)
        case 32:
            return decodeBase32(encoded)
        default:
            return nil
        }
    }

    static func decodeBase32(_ string: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var lookup: [Character: UInt8] = [:]
        for (index, char) in alphabet.enumerated() {
            lookup[char] = UInt8(index)
        }
        var result: [UInt8] = []
        var buffer: UInt32 = 0
        var bitsInBuffer = 0
        for char in string.uppercased() {
            guard let value = lookup[char] else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bitsInBuffer += 5
            if bitsInBuffer >= 8 {
                bitsInBuffer -= 8
                result.append(UInt8((buffer >> bitsInBuffer) & 0xFF))
            }
        }
        return Data(result)
    }
}
