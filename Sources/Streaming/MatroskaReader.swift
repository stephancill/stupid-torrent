import Foundation

enum MatroskaError: LocalizedError, CustomStringConvertible {
    case notMatroska
    case truncated(String)
    case undefinedSize(String)
    case corrupt(String)

    var description: String {
        switch self {
        case .notMatroska: "not a Matroska file"
        case .truncated(let what): "truncated: \(what)"
        case .undefinedSize(let what): "undefined size: \(what)"
        case .corrupt(let what): "corrupt: \(what)"
        }
    }

    var errorDescription: String? { "This file isn't a readable Matroska video (\(description))." }
}

enum MKVLacing: UInt8 {
    case none = 0
    case xiph = 1
    case fixed = 2
    case ebml = 3
}

struct MKVTrack {
    var number: UInt64
    var trackType: UInt64
    var codecID: String?
    var codecPrivate: Data?
    var defaultDurationNs: UInt64?
    var videoWidth: UInt64?
    var videoHeight: UInt64?
    var samplingFrequency: Double?
    var channels: UInt64?
    var bitDepth: UInt64?
    var language: String?
    var isDefault = true
    var isEnabled = true

    var isVideo: Bool { trackType == 1 }
    var isAudio: Bool { trackType == 2 }
}

struct MKVCuePoint: Equatable {
    let time: UInt64
    let clusterPosition: Int
    let trackNumber: UInt64
}

struct MatroskaInfo {
    var timestampScaleNs: UInt64 = 1_000_000
    var durationTicks: Double?
    var tracks: [MKVTrack] = []
    var cuePoints: [MKVCuePoint] = []
    var clustersStart: Int?
    var segmentDataStart: Int?
    var segmentDataEnd: Int?
    var cuesOffset: Int?

    func seconds(ticks: Double) -> Double {
        ticks * Double(timestampScaleNs) / 1e9
    }
}

struct MKVBlock {
    var trackNumber: UInt64
    var relativeTimestamp: Int64
    var isKeyframe: Bool
    var lacing: MKVLacing
    var data: Data
    var explicitDurationTicks: UInt64?
}

struct MKVCluster {
    var timestamp: UInt64
    var blocks: [MKVBlock]
}

enum MatroskaParser {
    static func parseHead(bytes: Data) throws -> MatroskaInfo {
        guard let ebmlHeader = EBML.readHeader(in: bytes, offset: 0), ebmlHeader.id == EBMLID.ebml.rawValue,
              let ebmlSize = ebmlHeader.size else {
            throw MatroskaError.notMatroska
        }
        guard ebmlSize <= UInt64(bytes.count) else { throw MatroskaError.truncated("EBML header") }
        let segmentOffset = ebmlHeader.length + Int(ebmlSize)
        guard let segmentHeader = EBML.readHeader(in: bytes, offset: segmentOffset) else {
            throw MatroskaError.truncated("Segment header")
        }
        guard segmentHeader.id == EBMLID.segment.rawValue else { throw MatroskaError.notMatroska }

        var info = MatroskaInfo()
        let segmentDataStart = segmentOffset + segmentHeader.length
        info.segmentDataStart = segmentDataStart
        info.segmentDataEnd = segmentHeader.size.map { segmentDataStart + Int($0) }

        var foundTracks = false
        var cursor = segmentDataStart
        while true {
            guard let header = EBML.readHeader(in: bytes, offset: cursor) else {
                if foundTracks { break }
                throw MatroskaError.truncated("Segment children")
            }
            if header.id == EBMLID.cluster.rawValue { break }
            guard let size = header.size else {
                throw MatroskaError.undefinedSize("Segment child 0x\(String(header.id, radix: 16))")
            }
            let value = cursor + header.length..<cursor + header.length + Int(size)
            if value.upperBound > bytes.count {
                guard foundTracks else { throw MatroskaError.truncated("Segment head") }
                cursor = value.upperBound
                break
            }
            switch EBMLID(rawValue: header.id) {
            case .info:
                try parseInfo(bytes: bytes, range: value, into: &info)
            case .tracks:
                info.tracks = try parseTracks(bytes: bytes, range: value)
                foundTracks = true
            case .cues:
                info.cuePoints = try parseCues(bytes: bytes, range: value)
            case .seekHead:
                info.cuesOffset = try parseSeekHead(bytes: bytes, range: value).map { segmentDataStart + $0 }
            default:
                break
            }
            cursor = value.upperBound
        }
        guard foundTracks else { throw MatroskaError.corrupt("no Tracks before the first Cluster") }
        info.clustersStart = cursor
        return info
    }

    private static func parseInfo(bytes: Data, range: Range<Int>, into info: inout MatroskaInfo) throws {
        try EBML.forEachChild(in: bytes, range: range) { header, value in
            switch EBMLID(rawValue: header.id) {
            case .timestampScale:
                info.timestampScaleNs = try EBML.readUInt(in: bytes, range: value)
            case .duration:
                info.durationTicks = try EBML.readFloat(in: bytes, range: value)
            default:
                break
            }
        }
        guard info.timestampScaleNs > 0 else { throw MatroskaError.corrupt("zero TimestampScale") }
    }

    private static func parseSeekHead(bytes: Data, range: Range<Int>) throws -> Int? {
        var cuesPosition: Int?
        try EBML.forEachChild(in: bytes, range: range) { header, value in
            guard header.id == EBMLID.seek.rawValue else { return }
            var seekID: UInt64?
            var position: UInt64?
            try EBML.forEachChild(in: bytes, range: value) { child, childValue in
                switch EBMLID(rawValue: child.id) {
                case .seekID: seekID = try EBML.readUInt(in: bytes, range: childValue)
                case .seekPosition: position = try EBML.readUInt(in: bytes, range: childValue)
                default: break
                }
            }
            if seekID == EBMLID.cues.rawValue, let position, position < UInt64(Int.max / 2) {
                cuesPosition = Int(position)
            }
        }
        return cuesPosition
    }

    private static func parseTracks(bytes: Data, range: Range<Int>) throws -> [MKVTrack] {
        var tracks: [MKVTrack] = []
        try EBML.forEachChild(in: bytes, range: range) { header, value in
            guard header.id == EBMLID.trackEntry.rawValue else { return }
            tracks.append(try parseTrackEntry(bytes: bytes, range: value))
        }
        return tracks
    }

    private static func parseTrackEntry(bytes: Data, range: Range<Int>) throws -> MKVTrack {
        var track = MKVTrack(number: 0, trackType: 0)
        try EBML.forEachChild(in: bytes, range: range) { header, value in
            switch EBMLID(rawValue: header.id) {
            case .trackNumber: track.number = try EBML.readUInt(in: bytes, range: value)
            case .trackType: track.trackType = try EBML.readUInt(in: bytes, range: value)
            case .codecID: track.codecID = try EBML.readString(in: bytes, range: value)
            case .codecPrivate: track.codecPrivate = slice(of: bytes, range: value)
            case .defaultDuration: track.defaultDurationNs = try EBML.readUInt(in: bytes, range: value)
            case .language: track.language = try EBML.readString(in: bytes, range: value)
            case .flagDefault: track.isDefault = try EBML.readUInt(in: bytes, range: value) != 0
            case .flagEnabled: track.isEnabled = try EBML.readUInt(in: bytes, range: value) != 0
            case .video:
                try EBML.forEachChild(in: bytes, range: value) { child, childValue in
                    switch EBMLID(rawValue: child.id) {
                    case .pixelWidth: track.videoWidth = try EBML.readUInt(in: bytes, range: childValue)
                    case .pixelHeight: track.videoHeight = try EBML.readUInt(in: bytes, range: childValue)
                    default: break
                    }
                }
            case .audio:
                try EBML.forEachChild(in: bytes, range: value) { child, childValue in
                    switch EBMLID(rawValue: child.id) {
                    case .samplingFrequency: track.samplingFrequency = try EBML.readFloat(in: bytes, range: childValue)
                    case .channels: track.channels = try EBML.readUInt(in: bytes, range: childValue)
                    case .bitDepth: track.bitDepth = try EBML.readUInt(in: bytes, range: childValue)
                    default: break
                    }
                }
            default:
                break
            }
        }
        return track
    }

    static func parseCues(bytes: Data, range: Range<Int>) throws -> [MKVCuePoint] {
        var cuePoints: [MKVCuePoint] = []
        try EBML.forEachChild(in: bytes, range: range) { header, value in
            guard header.id == EBMLID.cuePoint.rawValue else { return }
            cuePoints.append(contentsOf: try parseCuePoint(bytes: bytes, range: value))
        }
        return cuePoints.sorted { $0.time < $1.time }
    }

    private static func parseCuePoint(bytes: Data, range: Range<Int>) throws -> [MKVCuePoint] {
        var time: UInt64?
        var positions: [(trackNumber: UInt64, clusterPosition: Int)] = []
        try EBML.forEachChild(in: bytes, range: range) { header, value in
            switch EBMLID(rawValue: header.id) {
            case .cueTime:
                time = try EBML.readUInt(in: bytes, range: value)
            case .cueTrackPositions:
                if let position = try parseCueTrackPositions(bytes: bytes, range: value) {
                    positions.append(position)
                }
            default:
                break
            }
        }
        guard let time else { return [] }
        return positions.map {
            MKVCuePoint(time: time, clusterPosition: $0.clusterPosition, trackNumber: $0.trackNumber)
        }
    }

    private static func parseCueTrackPositions(
        bytes: Data,
        range: Range<Int>
    ) throws -> (trackNumber: UInt64, clusterPosition: Int)? {
        var trackNumber: UInt64?
        var clusterPosition: UInt64?
        try EBML.forEachChild(in: bytes, range: range) { header, value in
            switch EBMLID(rawValue: header.id) {
            case .cueTrack: trackNumber = try EBML.readUInt(in: bytes, range: value)
            case .cueClusterPosition: clusterPosition = try EBML.readUInt(in: bytes, range: value)
            default: break
            }
        }
        guard let trackNumber, let clusterPosition, clusterPosition < UInt64(Int.max / 2) else { return nil }
        return (trackNumber, Int(clusterPosition))
    }

    static func clusterEnd(bytes: Data, offset: Int) throws -> Int? {
        guard let header = EBML.readHeader(in: bytes, offset: offset), header.id == EBMLID.cluster.rawValue else {
            throw MatroskaError.corrupt("expected a Cluster at \(offset)")
        }
        if let size = header.size { return offset + header.length + Int(size) }
        var cursor = offset + header.length
        while let child = EBML.readHeader(in: bytes, offset: cursor) {
            if EBMLID.isTopLevel(child.id) { return cursor }
            guard let size = child.size else { throw MatroskaError.undefinedSize("Cluster child") }
            cursor += child.length + Int(size)
        }
        return nil
    }

    static func clusters(in bytes: Data, range: Range<Int>) throws -> [MKVCluster] {
        var clusters: [MKVCluster] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard let header = EBML.readHeader(in: bytes, offset: offset) else {
                throw MatroskaError.corrupt("element header at \(offset)")
            }
            let end: Int
            if header.id == EBMLID.cluster.rawValue {
                end = try clusterEnd(bytes: bytes, offset: offset) ?? range.upperBound
                guard end <= range.upperBound else { throw MatroskaError.truncated("Cluster at \(offset)") }
                clusters.append(try parseCluster(bytes: bytes, range: offset..<end))
            } else {
                guard let size = header.size else { throw MatroskaError.undefinedSize("Segment child") }
                end = offset + header.length + Int(size)
                guard end <= range.upperBound else { throw MatroskaError.truncated("element at \(offset)") }
            }
            offset = end
        }
        return clusters
    }

    static func completeLeadingClusters(in bytes: Data) throws -> [MKVCluster] {
        var clusters: [MKVCluster] = []
        var offset = 0
        while offset < bytes.count, let header = EBML.readHeader(in: bytes, offset: offset) {
            let end: Int
            if header.id == EBMLID.cluster.rawValue {
                guard let clusterEnd = try clusterEnd(bytes: bytes, offset: offset), clusterEnd <= bytes.count else { break }
                clusters.append(try parseCluster(bytes: bytes, range: offset..<clusterEnd))
                end = clusterEnd
            } else {
                guard let size = header.size else { throw MatroskaError.undefinedSize("Segment child") }
                end = offset + header.length + Int(size)
                guard end <= bytes.count else { break }
            }
            offset = end
        }
        return clusters
    }

    static func parseCluster(bytes: Data, range: Range<Int>) throws -> MKVCluster {
        guard let header = EBML.readHeader(in: bytes, offset: range.lowerBound),
              header.id == EBMLID.cluster.rawValue else {
            throw MatroskaError.corrupt("expected a Cluster at \(range.lowerBound)")
        }
        var cluster = MKVCluster(timestamp: 0, blocks: [])
        try EBML.forEachChild(in: bytes, range: range.lowerBound + header.length..<range.upperBound) { child, value in
            switch EBMLID(rawValue: child.id) {
            case .clusterTimestamp:
                cluster.timestamp = try EBML.readUInt(in: bytes, range: value)
            case .simpleBlock:
                cluster.blocks.append(try parseBlock(bytes: bytes, range: value, isSimple: true))
            case .blockGroup:
                if let block = try parseBlockGroup(bytes: bytes, range: value) {
                    cluster.blocks.append(block)
                }
            default:
                break
            }
        }
        return cluster
    }

    static func clusterStart(
        bytes: Data,
        clusterEnd: Int,
        trackNumber: UInt64
    ) throws -> (timestamp: UInt64, firstBlock: MKVBlock?) {
        guard let header = EBML.readHeader(in: bytes, offset: 0), header.id == EBMLID.cluster.rawValue else {
            throw MatroskaError.corrupt("expected a Cluster")
        }
        let isWindow = bytes.count < clusterEnd
        var timestamp: UInt64 = 0
        var cursor = header.length
        while cursor < clusterEnd {
            guard let child = EBML.readHeader(in: bytes, offset: cursor) else {
                throw isWindow ? MatroskaError.truncated("Cluster window") : MatroskaError.corrupt("Cluster child")
            }
            guard let size = child.size else { throw MatroskaError.undefinedSize("Cluster child") }
            let value = cursor + child.length..<cursor + child.length + Int(size)
            guard value.upperBound <= clusterEnd else { throw MatroskaError.corrupt("Cluster child overruns") }
            switch EBMLID(rawValue: child.id) {
            case .clusterTimestamp:
                guard value.upperBound <= bytes.count else { throw MatroskaError.truncated("Cluster window") }
                timestamp = try EBML.readUInt(in: bytes, range: value)
            case .simpleBlock:
                let headerEnd = min(value.upperBound, value.lowerBound + 12)
                guard headerEnd <= bytes.count else { throw MatroskaError.truncated("Cluster window") }
                let block = try parseBlock(bytes: bytes, range: value.lowerBound..<headerEnd, isSimple: true)
                if block.trackNumber == trackNumber { return (timestamp, block) }
            case .blockGroup:
                guard value.upperBound <= bytes.count else { throw MatroskaError.truncated("Cluster window") }
                if let block = try parseBlockGroup(bytes: bytes, range: value), block.trackNumber == trackNumber {
                    return (timestamp, block)
                }
            default:
                break
            }
            cursor = value.upperBound
        }
        return (timestamp, nil)
    }

    private static func parseBlock(bytes: Data, range: Range<Int>, isSimple: Bool) throws -> MKVBlock {
        guard let track = EBML.readVarInt(in: bytes, offset: range.lowerBound),
              range.lowerBound + track.length + 3 <= range.upperBound else {
            throw MatroskaError.corrupt("block header")
        }
        let timestampOffset = range.lowerBound + track.length
        let flags = bytes[bytes.startIndex + timestampOffset + 2]
        return MKVBlock(
            trackNumber: track.value,
            relativeTimestamp: try EBML.readInt(in: bytes, range: timestampOffset..<timestampOffset + 2),
            isKeyframe: isSimple ? flags & 0x80 != 0 : true,
            lacing: MKVLacing(rawValue: (flags >> 1) & 0x3) ?? .none,
            data: slice(of: bytes, range: timestampOffset + 3..<range.upperBound)
        )
    }

    private static func parseBlockGroup(bytes: Data, range: Range<Int>) throws -> MKVBlock? {
        var block: MKVBlock?
        var hasReference = false
        var duration: UInt64?
        try EBML.forEachChild(in: bytes, range: range) { header, value in
            switch EBMLID(rawValue: header.id) {
            case .block: block = try parseBlock(bytes: bytes, range: value, isSimple: false)
            case .referenceBlock: hasReference = true
            case .blockDuration: duration = try EBML.readUInt(in: bytes, range: value)
            default: break
            }
        }
        block?.isKeyframe = !hasReference
        block?.explicitDurationTicks = duration
        return block
    }

    static func frames(of block: MKVBlock, frameDurationTicks: Double) throws -> [MKVBlock] {
        guard block.lacing != .none else { return [block] }
        let payload = [UInt8](block.data)
        guard let first = payload.first else { throw MatroskaError.corrupt("empty laced block") }
        let frameCount = Int(first) + 1
        var cursor = 1
        var sizes: [Int] = []
        switch block.lacing {
        case .xiph:
            for _ in 0..<frameCount - 1 {
                var size = 0
                while true {
                    guard cursor < payload.count else { throw MatroskaError.corrupt("Xiph lacing") }
                    let byte = payload[cursor]
                    cursor += 1
                    size += Int(byte)
                    if byte != 255 { break }
                }
                sizes.append(size)
            }
        case .fixed:
            let remaining = payload.count - cursor
            guard remaining % frameCount == 0 else { throw MatroskaError.corrupt("fixed lacing") }
            sizes = Array(repeating: remaining / frameCount, count: frameCount - 1)
        case .ebml:
            var size = 0
            for index in 0..<frameCount - 1 {
                guard let (value, width) = EBML.readVarInt(in: block.data, offset: cursor) else {
                    throw MatroskaError.corrupt("EBML lacing")
                }
                cursor += width
                size = index == 0 ? Int(value) : size + Int(value) - ((1 << (7 * width - 1)) - 1)
                guard size >= 0 else { throw MatroskaError.corrupt("EBML lacing") }
                sizes.append(size)
            }
        case .none:
            return [block]
        }
        let lastSize = payload.count - cursor - sizes.reduce(0, +)
        guard lastSize >= 0 else { throw MatroskaError.corrupt("lacing sizes exceed the block") }
        sizes.append(lastSize)

        let frameDuration: Double = if let explicit = block.explicitDurationTicks, explicit > 0 {
            Double(explicit) / Double(frameCount)
        } else {
            max(0, frameDurationTicks)
        }
        var frames: [MKVBlock] = []
        for (index, size) in sizes.enumerated() {
            frames.append(MKVBlock(
                trackNumber: block.trackNumber,
                relativeTimestamp: block.relativeTimestamp + Int64((frameDuration * Double(index)).rounded()),
                isKeyframe: block.isKeyframe && index == 0,
                lacing: .none,
                data: Data(payload[cursor..<cursor + size]),
                explicitDurationTicks: frameDuration > 0 ? UInt64(frameDuration.rounded()) : nil
            ))
            cursor += size
        }
        return frames
    }

    static func firstFrames(of trackNumbers: Set<UInt64>, in clusters: [MKVCluster]) throws -> [UInt64: Data] {
        var frames: [UInt64: Data] = [:]
        for cluster in clusters {
            for block in cluster.blocks where trackNumbers.contains(block.trackNumber) && frames[block.trackNumber] == nil {
                frames[block.trackNumber] = try self.frames(of: block, frameDurationTicks: 0).first?.data
            }
            if frames.count == trackNumbers.count { break }
        }
        return frames
    }

    private static func slice(of bytes: Data, range: Range<Int>) -> Data {
        Data(bytes[bytes.startIndex + range.lowerBound..<bytes.startIndex + range.upperBound])
    }
}
