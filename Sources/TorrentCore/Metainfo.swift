import Foundation
import CryptoKit
import Bencode

public struct TorrentFile: Sendable, Equatable {
    public let pathComponents: [String]
    public let length: Int

    public var name: String { pathComponents.last ?? "" }
    public var pathString: String { pathComponents.joined(separator: "/") }
}

public enum MetainfoError: Error, Sendable, Equatable {
    case notATorrent
    case missingKey(String)
    case invalidValue(String)
}

public struct Metainfo: Sendable, Equatable {
    public let infoHash: Data
    public let infoDict: Data
    public let name: String
    public let displayName: String
    public let pieceLength: Int
    public let pieceHashes: [Data]
    public let files: [TorrentFile]
    public let trackerTiers: [[URL]]
    public let isPrivate: Bool

    public var pieceCount: Int { pieceHashes.count }

    public var totalLength: Int {
        files.reduce(0) { $0 + $1.length }
    }

    public func verifiedByteCount(pieceCount: Int) -> Int64 {
        let verifiedPieces = min(max(pieceCount, 0), self.pieceCount)
        return min(Int64(totalLength), Int64(verifiedPieces) * Int64(pieceLength))
    }

    public var fileOffsets: [Int] {
        var offsets: [Int] = []
        var offset = 0
        for file in files {
            offsets.append(offset)
            offset += file.length
        }
        return offsets
    }

    public var flattenedTrackers: [URL] {
        trackerTiers.flatMap { $0 }
    }

    /// Re-encodes this metainfo as a `.torrent` file (info dict + trackers), for persistence.
    public func torrentData() throws -> Data {
        var dict: [String: BValue] = ["info": try Bencode.decode(infoDict)]
        if !trackerTiers.isEmpty {
            let tiers = trackerTiers.map { tier in
                BValue.list(tier.map { .string(Data($0.absoluteString.utf8)) })
            }
            dict["announce-list"] = .list(tiers)
        }
        if displayName != name {
            dict["stupid-torrent-display-name"] = .string(Data(displayName.utf8))
        }
        return Bencode.encode(.dictionary(dict))
    }

    public func byteRange(ofFileAt index: Int) -> Range<Int> {
        let offset = fileOffsets[index]
        return offset..<(offset + files[index].length)
    }

    public func pieceRange(forByteRange range: Range<Int>) -> Range<Int> {
        let first = range.lowerBound / pieceLength
        let last = (range.upperBound - 1) / pieceLength
        return first..<(last + 1)
    }

    public func location(piece: Int, pieceOffset: Int) -> (fileIndex: Int, fileOffset: Int)? {
        let absolute = piece * pieceLength + pieceOffset
        guard absolute >= 0, absolute < totalLength else { return nil }
        let offsets = fileOffsets
        for index in offsets.indices {
            if absolute < offsets[index] + files[index].length {
                return (index, absolute - offsets[index])
            }
        }
        return nil
    }

    public func location(piece: Int) -> (fileIndex: Int, fileOffset: Int)? {
        location(piece: piece, pieceOffset: 0)
    }
}

extension Metainfo {
    public init(data: Data) throws {
        let root = try Bencode.decode(data)
        guard case .dictionary(let dict) = root else {
            throw MetainfoError.notATorrent
        }
        guard case .dictionary(let info) = dict["info"] else {
            throw MetainfoError.invalidValue("info")
        }
        try self.init(
            info: info,
            infoRaw: Bencode.rawValue(forKey: "info", in: data),
            trackers: Self.parseTrackerTiers(from: dict),
            displayName: dict["stupid-torrent-display-name"]?.stringValueUTF8
        )
    }

    /// Builds metainfo from a raw bencoded info dict (e.g. fetched via ut_metadata from a magnet link).
    public init(infoDict: Data, trackers: [[URL]] = [], displayName: String? = nil) throws {
        let root = try Bencode.decode(infoDict)
        guard case .dictionary(let info) = root else {
            throw MetainfoError.notATorrent
        }
        try self.init(info: info, infoRaw: infoDict, trackers: trackers, displayName: displayName)
    }

    private init(info: [String: BValue], infoRaw: Data, trackers: [[URL]], displayName: String?) throws {
        self.infoHash = Data(Insecure.SHA1.hash(data: infoRaw))
        self.infoDict = infoRaw

        func stringValue(_ key: String) throws -> String {
            guard let value = info[key]?.stringValue, let string = String(data: value, encoding: .utf8) else {
                throw MetainfoError.missingKey(key)
            }
            return string
        }
        func intValue(_ key: String) throws -> Int {
            guard let value = info[key]?.intValue else {
                throw MetainfoError.missingKey(key)
            }
            return value
        }

        let name: String
        if let utf8Name = try? stringValue("name.utf-8") {
            name = utf8Name
        } else {
            name = try stringValue("name")
        }
        self.name = name
        self.displayName = displayName ?? name
        self.pieceLength = try intValue("piece length")
        guard pieceLength > 0 else { throw MetainfoError.invalidValue("piece length") }

        guard let piecesData = info["pieces"]?.stringValue else {
            throw MetainfoError.missingKey("pieces")
        }
        guard piecesData.count % 20 == 0 else { throw MetainfoError.invalidValue("pieces") }
        var hashes: [Data] = []
        hashes.reserveCapacity(piecesData.count / 20)
        var cursor = 0
        while cursor < piecesData.count {
            hashes.append(piecesData[cursor..<(cursor + 20)])
            cursor += 20
        }
        self.pieceHashes = hashes

        self.isPrivate = (info["private"]?.intValue ?? 0) != 0

        let files: [TorrentFile]
        if let filesValue = info["files"]?.listValue, !filesValue.isEmpty {
            var parsed: [TorrentFile] = []
            for case .dictionary(let fileDict) in filesValue {
                guard let length = fileDict["length"]?.intValue else {
                    throw MetainfoError.invalidValue("file length")
                }
                let path = Self.pathComponents(from: fileDict, fallbackName: name)
                parsed.append(TorrentFile(pathComponents: path, length: length))
            }
            files = parsed
        } else if let singleLength = info["length"]?.intValue {
            files = [TorrentFile(pathComponents: [name], length: singleLength)]
        } else {
            throw MetainfoError.invalidValue("files")
        }
        guard !files.isEmpty else { throw MetainfoError.invalidValue("files") }
        self.files = files

        self.trackerTiers = trackers
    }

    private static func pathComponents(from dict: [String: BValue], fallbackName: String) -> [String] {
        let pathValue = dict["path.utf-8"] ?? dict["path"]
        guard let list = pathValue?.listValue else { return [fallbackName] }
        let components = list.compactMap { $0.stringValueUTF8 }
        return components.isEmpty ? [fallbackName] : components
    }

    private static func parseTrackerTiers(from dict: [String: BValue]) -> [[URL]] {
        if let announceList = dict["announce-list"]?.listValue {
            var tiers: [[URL]] = []
            var hasAny = false
            for case .list(let tier) in announceList {
                var urls: [URL] = []
                for case .string(let data) in tier {
                    if let string = String(data: data, encoding: .utf8), let url = URL(string: string) {
                        urls.append(url)
                        hasAny = true
                    }
                }
                if !urls.isEmpty { tiers.append(urls) }
            }
            if hasAny || dict["announce"] == nil {
                return tiers
            }
        }
        if let announce = dict["announce"]?.stringValueUTF8, let url = URL(string: announce) {
            return [[url]]
        }
        return []
    }
}
