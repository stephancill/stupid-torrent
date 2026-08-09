import Foundation

enum MatroskaError: Error, CustomStringConvertible {
    case notMatroska
    case truncated(String)
    case undefinedSize(String)
    case unsupported(String)
    case corrupt(String)

    var description: String {
        switch self {
        case .notMatroska: "not a Matroska file"
        case .truncated(let s): "truncated: \(s)"
        case .undefinedSize(let s): "undefined size: \(s)"
        case .unsupported(let s): "unsupported: \(s)"
        case .corrupt(let s): "corrupt: \(s)"
        }
    }
}

/// Matroska lacing kinds (per the Block flags byte).
public enum MKVLacing: Int {
    case none = 0
    case xiph = 1
    case fixed = 2
    case ebml = 3
}

/// One parsed track from the `Tracks` element.
public struct MKVTrack {
    public var number: UInt64
    public var trackType: UInt64
    public var codecID: String?
    public var codecPrivate: Data?
    public var defaultDurationNs: UInt64?
    public var codecDelayNs: UInt64 = 0
    public var seekPreRollNs: UInt64 = 0
    public var videoWidth: UInt64?
    public var videoHeight: UInt64?
    public var samplingFrequency: Double?
    public var channels: UInt64?
    public var bitDepth: UInt64?
    public var language: String?
    public var isDefault: Bool = true
    public var isEnabled: Bool = true

    /// Whether the transmuxer can carry this track into fMP4 (video/audio only).
    public var isTransmuxable: Bool {
        trackType == 1 || trackType == 2
    }
}

/// The parsed MKV head: segment-level facts plus the track table.
public struct MatroskaInfo {
    public var isWebM = false
    /// Nanoseconds per segment timestamp tick (default 1,000,000 → 1 ms).
    public var timestampScaleNs: UInt64 = 1_000_000
    /// Duration in segment timestamp ticks.
    public var durationTicks: Double?
    public var tracks: [MKVTrack] = []
    /// Sorted cue points: (segment time ticks, absolute cluster byte offset).
    public var cuePoints: [(time: UInt64, clusterPosition: Int)] = []
    /// Byte offset of the first Cluster element (absolute in the file).
    public var firstClusterOffset: Int?
    /// Absolute file offset where the Segment element's data begins.
    public var segmentDataStart: Int?
    /// Absolute file offset where the Segment element ends (nil if undefined size).
    public var segmentDataEnd: Int?

    public var durationSeconds: Double? {
        guard let ticks = durationTicks else { return nil }
        return ticks * Double(timestampScaleNs) / 1e9
    }

    /// Track by Matroska track number.
    public func track(_ number: UInt64) -> MKVTrack? {
        tracks.first { $0.number == number }
    }
}

/// A single block (or laced block) inside a cluster.
public struct MKVBlock {
    public var trackNumber: UInt64
    /// Decode time relative to the cluster timestamp, in segment ticks (signed).
    public var relativeTimestamp: Int64
    public var isKeyframe: Bool
    public var lacing: MKVLacing
    /// Raw block payload (frame data including any lacing header), excluding track/timecode/flags.
    public var data: Data
    /// `BlockDuration` in segment ticks, if the BlockGroup carried one.
    public var explicitDurationTicks: UInt64?
}

/// A slice of a cluster element plus the absolute offset where the next element begins.
public struct MKVClusterRange {
    public let elementEnd: Int
    public let bytes: Data
}

public struct MKVCluster {
    /// Cluster timestamp in segment ticks.
    public var timestamp: UInt64
    /// Absolute byte offset of the Cluster element header.
    public var elementOffset: Int
    /// Absolute byte offset where the element following this cluster begins (end of cluster).
    public var elementEnd = 0
    public var blocks: [MKVBlock]
}

/// Parses the Matroska structure out of fetched byte slices. All parsing is synchronous over
/// bounded `Data`; a driver (e.g. `TransmuxStreamSource`) is responsible for fetching the
/// verified bytes. Parsing a bounded slice never performs unbounded reads.
public enum MatroskaParser {

    /// Parses the EBML header + Segment head (Info/Tracks) out of `bytes`, which must start at
    /// the very beginning of the file. Throws `truncated` if `bytes` doesn't contain the whole
    /// head (the caller should fetch more and retry).
    public static func parseHead(bytes: Data) throws -> MatroskaInfo {
        var info = MatroskaInfo()

        guard let ebmlHeader = EBML.readHeader(bytes, offset: 0) else {
            throw MatroskaError.notMatroska
        }
        guard ebmlHeader.id == EBMLID.ebml.rawValue else { throw MatroskaError.notMatroska }

        // Walk the EBML header's children for the doc type.
        var pos = EBML.headerLength(ebmlHeader)
        if let size = ebmlHeader.size {
            let end = pos + Int(size)
            guard end <= bytes.count else { throw MatroskaError.truncated("EBML header") }
            while pos < end {
                guard let header = EBML.readHeader(bytes, offset: pos) else { throw MatroskaError.truncated("EBML header child") }
                guard let childSize = header.size else { throw MatroskaError.undefinedSize("EBML header child") }
                let dataOffset = pos + EBML.headerLength(header)
                if header.id == EBMLID.docType.rawValue {
                    if let doc = EBML.readString(bytes, offset: dataOffset, length: Int(childSize)) {
                        info.isWebM = doc == "webm"
                    }
                }
                pos = dataOffset + Int(childSize)
            }
        } else {
            // Rare: undefined-size EBML header. Scan forward for the Segment id.
            pos += 1
            var foundSegment = false
            while pos + 4 <= bytes.count {
                if let header = EBML.readHeader(bytes, offset: pos), header.id == EBMLID.segment.rawValue {
                    foundSegment = true
                    break
                }
                pos += 1
            }
            guard foundSegment else { throw MatroskaError.truncated("segment header") }
        }

        // Segment element.
        guard let segmentHeader = EBML.readHeader(bytes, offset: pos) else { throw MatroskaError.truncated("segment header") }
        guard segmentHeader.id == EBMLID.segment.rawValue else { throw MatroskaError.notMatroska }
        let segmentDataStart = pos + EBML.headerLength(segmentHeader)
        info.segmentDataStart = segmentDataStart
        if let segmentSize = segmentHeader.size {
            info.segmentDataEnd = segmentDataStart + Int(segmentSize)
        }
        var cursor = segmentDataStart

        var foundTracks = false
        var scanGuard = 0

        // Walk top-level segment children, skipping clusters (potentially huge) via their sizes,
        // until the Tracks element (and Info, which precedes it in practice) is found.
        while !foundTracks {
            guard scanGuard < 100 else { throw MatroskaError.corrupt("segment head walk") }
            scanGuard += 1
            guard let header = EBML.readHeader(bytes, offset: cursor) else {
                throw MatroskaError.truncated("segment children")
            }
            guard let elementSize = header.size else {
                throw MatroskaError.undefinedSize("segment child 0x\(String(header.id, radix: 16))")
            }
            let dataOffset = cursor + EBML.headerLength(header)
            let elementEnd = dataOffset + Int(elementSize)
            guard elementEnd <= bytes.count else {
                throw MatroskaError.truncated("segment child 0x\(String(header.id, radix: 16))")
            }

            switch header.id {
            case EBMLID.info.rawValue:
                try parseInfo(bytes, dataOffset: dataOffset, size: Int(elementSize), into: &info)
            case EBMLID.tracks.rawValue:
                foundTracks = true
                try parseTracks(bytes, dataOffset: dataOffset, size: Int(elementSize), into: &info)
            case EBMLID.cluster.rawValue:
                // First cluster encountered; the head parse is done.
                info.firstClusterOffset = cursor
                return info
            case EBMLID.cues.rawValue:
                try parseCues(bytes, dataOffset: dataOffset, size: Int(elementSize), into: &info)
            case EBMLID.seekHead.rawValue, EBMLID.chapters.rawValue, EBMLID.tags.rawValue,
                 EBMLID.attachments.rawValue, EBMLID.void.rawValue, EBMLID.crc32.rawValue:
                break // Skipped.
            default:
                break // Unknown level-1 element: skip.
            }
            cursor = elementEnd
        }
        if !foundTracks {
            throw MatroskaError.truncated("Tracks")
        }

        // Locate the first cluster after Tracks, skipping other level-1 elements (Void/Cues/...).
        if info.firstClusterOffset == nil {
            var scan = cursor
            var guardCount = 0
            while scan + 1 < bytes.count, guardCount < 100 {
                guardCount += 1
                guard let header = EBML.readHeader(bytes, offset: scan) else { break }
                if header.id == EBMLID.cluster.rawValue {
                    info.firstClusterOffset = scan
                    break
                }
                guard let elementSize = header.size else { break }
                scan += EBML.headerLength(header) + Int(elementSize)
            }
        }
        return info
    }

    /// Parses the `Info` element children.
    private static func parseInfo(_ bytes: Data, dataOffset: Int, size: Int, into info: inout MatroskaInfo) throws {
        var cursor = dataOffset
        let end = dataOffset + size
        while cursor < end {
            guard let header = EBML.readHeader(bytes, offset: cursor) else { throw MatroskaError.truncated("Info") }
            guard let elementSize = header.size else { throw MatroskaError.undefinedSize("Info child") }
            let valueOffset = cursor + EBML.headerLength(header)
            switch header.id {
            case EBMLID.timestampScale.rawValue:
                info.timestampScaleNs = EBML.readUInt(bytes, offset: valueOffset, length: Int(elementSize))
            case EBMLID.duration.rawValue:
                info.durationTicks = EBML.readFloat(bytes, offset: valueOffset, length: Int(elementSize))
            default:
                break
            }
            cursor = valueOffset + Int(elementSize)
        }
    }

    /// Parses the `Tracks` element into `info.tracks`.
    private static func parseTracks(_ bytes: Data, dataOffset: Int, size: Int, into info: inout MatroskaInfo) throws {
        var cursor = dataOffset
        let end = dataOffset + size
        while cursor < end {
            guard let header = EBML.readHeader(bytes, offset: cursor) else { throw MatroskaError.truncated("Tracks") }
            guard let elementSize = header.size else { throw MatroskaError.undefinedSize("Tracks child") }
            if header.id == EBMLID.trackEntry.rawValue {
                let track = try parseTrackEntry(bytes, dataOffset: cursor + EBML.headerLength(header), size: Int(elementSize))
                info.tracks.append(track)
            }
            cursor = cursor + EBML.headerLength(header) + Int(elementSize)
        }
    }

    /// Parses a single `TrackEntry`.
    private static func parseTrackEntry(_ bytes: Data, dataOffset: Int, size: Int) throws -> MKVTrack {
        var track = MKVTrack(number: 0, trackType: 0)
        var cursor = dataOffset
        let end = dataOffset + size
        while cursor < end {
            guard let header = EBML.readHeader(bytes, offset: cursor) else { throw MatroskaError.truncated("TrackEntry") }
            guard let elementSize = header.size else { throw MatroskaError.undefinedSize("TrackEntry child") }
            let valueOffset = cursor + EBML.headerLength(header)
            let size = Int(elementSize)
            switch header.id {
            case EBMLID.trackNumber.rawValue: track.number = EBML.readUInt(bytes, offset: valueOffset, length: size)
            case EBMLID.trackType.rawValue: track.trackType = EBML.readUInt(bytes, offset: valueOffset, length: size)
            case EBMLID.codecID.rawValue: track.codecID = EBML.readString(bytes, offset: valueOffset, length: size)
            case EBMLID.codecPrivate.rawValue: track.codecPrivate = bytes.subdata(in: valueOffset..<valueOffset + size)
            case EBMLID.defaultDuration.rawValue: track.defaultDurationNs = EBML.readUInt(bytes, offset: valueOffset, length: size)
            case EBMLID.codecDelay.rawValue: track.codecDelayNs = EBML.readUInt(bytes, offset: valueOffset, length: size)
            case EBMLID.seekPreRoll.rawValue: track.seekPreRollNs = EBML.readUInt(bytes, offset: valueOffset, length: size)
            case EBMLID.language.rawValue: track.language = EBML.readString(bytes, offset: valueOffset, length: size)
            case EBMLID.flagDefault.rawValue: track.isDefault = EBML.readUInt(bytes, offset: valueOffset, length: size) != 0
            case EBMLID.flagEnabled.rawValue: track.isEnabled = EBML.readUInt(bytes, offset: valueOffset, length: size) != 0
            case EBMLID.video.rawValue:
                try parseVideo(bytes, dataOffset: valueOffset, size: size, into: &track)
            case EBMLID.audio.rawValue:
                try parseAudio(bytes, dataOffset: valueOffset, size: size, into: &track)
            default:
                break
            }
            cursor = valueOffset + size
        }
        return track
    }

    private static func parseVideo(_ bytes: Data, dataOffset: Int, size: Int, into track: inout MKVTrack) throws {
        var cursor = dataOffset
        let end = dataOffset + size
        while cursor < end {
            guard let header = EBML.readHeader(bytes, offset: cursor) else { throw MatroskaError.truncated("Video") }
            guard let elementSize = header.size else { throw MatroskaError.undefinedSize("Video child") }
            let valueOffset = cursor + EBML.headerLength(header)
            switch header.id {
            case EBMLID.pixelWidth.rawValue: track.videoWidth = EBML.readUInt(bytes, offset: valueOffset, length: Int(elementSize))
            case EBMLID.pixelHeight.rawValue: track.videoHeight = EBML.readUInt(bytes, offset: valueOffset, length: Int(elementSize))
            default: break
            }
            cursor = valueOffset + Int(elementSize)
        }
    }

    private static func parseAudio(_ bytes: Data, dataOffset: Int, size: Int, into track: inout MKVTrack) throws {
        var cursor = dataOffset
        let end = dataOffset + size
        while cursor < end {
            guard let header = EBML.readHeader(bytes, offset: cursor) else { throw MatroskaError.truncated("Audio") }
            guard let elementSize = header.size else { throw MatroskaError.undefinedSize("Audio child") }
            let valueOffset = cursor + EBML.headerLength(header)
            switch header.id {
            case EBMLID.samplingFrequency.rawValue:
                track.samplingFrequency = EBML.readFloat(bytes, offset: valueOffset, length: Int(elementSize))
            case EBMLID.channels.rawValue:
                track.channels = EBML.readUInt(bytes, offset: valueOffset, length: Int(elementSize))
            case EBMLID.bitDepth.rawValue:
                track.bitDepth = EBML.readUInt(bytes, offset: valueOffset, length: Int(elementSize))
            default: break
            }
            cursor = valueOffset + Int(elementSize)
        }
    }

    /// Parses the `Cues` element into a sorted list of (time, clusterOffset).
    public static func parseCues(_ bytes: Data, dataOffset: Int, size: Int, into info: inout MatroskaInfo) throws {
        var cursor = dataOffset
        let end = dataOffset + size

        while cursor < end {
            guard let header = EBML.readHeader(bytes, offset: cursor) else { throw MatroskaError.truncated("Cues") }
            guard let elementSize = header.size else { throw MatroskaError.undefinedSize("Cues child") }
            let valueOffset = cursor + EBML.headerLength(header)
            switch header.id {
            case EBMLID.cuePoint.rawValue:
                var time: UInt64?
                var clusterPosition: Int?
                try parseCuePoint(bytes, dataOffset: valueOffset, size: Int(elementSize), time: &time, clusterPosition: &clusterPosition)
                if let time, let clusterPosition {
                    info.cuePoints.append((time: time, clusterPosition: clusterPosition))
                }

            default:
                break
            }
            cursor = valueOffset + Int(elementSize)
        }
        info.cuePoints.sort { $0.time < $1.time }
    }

    private static func parseCuePoint(_ bytes: Data, dataOffset: Int, size: Int, time: inout UInt64?, clusterPosition: inout Int?) throws {
        var cursor = dataOffset
        let end = dataOffset + size
        while cursor < end {
            guard let header = EBML.readHeader(bytes, offset: cursor) else { throw MatroskaError.truncated("CuePoint") }
            guard let elementSize = header.size else { throw MatroskaError.undefinedSize("CuePoint child") }
            let valueOffset = cursor + EBML.headerLength(header)
            switch header.id {
            case EBMLID.cueTime.rawValue:
                time = EBML.readUInt(bytes, offset: valueOffset, length: Int(elementSize))
            case EBMLID.cueTrackPositions.rawValue:
                // CueClusterPosition is relative to the Segment data start.
                var cp: Int?
                try parseCueTrackPositions(bytes, dataOffset: valueOffset, size: Int(elementSize), clusterPosition: &cp)
                if let cp { clusterPosition = cp }
            default:
                break
            }
            cursor = valueOffset + Int(elementSize)
        }
    }

    private static func parseCueTrackPositions(_ bytes: Data, dataOffset: Int, size: Int, clusterPosition: inout Int?) throws {
        var cursor = dataOffset
        let end = dataOffset + size
        while cursor < end {
            guard let header = EBML.readHeader(bytes, offset: cursor) else { throw MatroskaError.truncated("CueTrackPositions") }
            guard let elementSize = header.size else { throw MatroskaError.undefinedSize("CueTrackPositions child") }
            let valueOffset = cursor + EBML.headerLength(header)
            if header.id == EBMLID.cueClusterPosition.rawValue {
                clusterPosition = Int(EBML.readUInt(bytes, offset: valueOffset, length: Int(elementSize)))
            }
            cursor = valueOffset + Int(elementSize)
        }
    }

    /// Parses one cluster element. `bytes` must start at the cluster element header.
    /// Returns the cluster plus the absolute offset where the next element begins.
    public static func parseCluster(bytes: Data, segmentDataStart: Int) throws -> MKVCluster {
        guard let header = EBML.readHeader(bytes, offset: 0) else { throw MatroskaError.truncated("cluster header") }
        guard header.id == EBMLID.cluster.rawValue else { throw MatroskaError.corrupt("expected cluster") }

        let dataStart = EBML.headerLength(header)
        let elementStart = 0
        let elementEnd: Int
        if let size = header.size {
            elementEnd = elementStart + EBML.headerLength(header) + Int(size)
            guard elementEnd <= bytes.count else { throw MatroskaError.truncated("cluster data") }
        } else {
            // Undefined-size cluster: its data runs until the next level-0/1 element.
            var cursor = dataStart
            var found = false
            var end = bytes.count
            while cursor + 1 < bytes.count {
                if let next = EBML.readHeader(bytes, offset: cursor),
                   isTopLevelID(next.id) {
                    end = cursor
                    found = true
                    break
                }
                cursor += 1
            }
            guard found else { throw MatroskaError.truncated("cluster end") }
            elementEnd = end
        }

        var timestamp: UInt64 = 0
        var blocks: [MKVBlock] = []
        var cursor = dataStart
        while cursor < elementEnd {
            guard let blockHeader = EBML.readHeader(bytes, offset: cursor) else { break }
            guard let blockSize = blockHeader.size else { throw MatroskaError.undefinedSize("cluster child") }
            let valueOffset = cursor + EBML.headerLength(blockHeader)
            guard valueOffset + Int(blockSize) <= bytes.count else { throw MatroskaError.truncated("cluster child") }

            switch blockHeader.id {
            case EBMLID.clusterTimestamp.rawValue:
                timestamp = EBML.readUInt(bytes, offset: valueOffset, length: Int(blockSize))
            case EBMLID.simpleBlock.rawValue:
                if let block = try? parseBlock(bytes, valueOffset: valueOffset, size: Int(blockSize), isSimple: true) {
                    blocks.append(block)
                }
            case EBMLID.blockGroup.rawValue:
                if let block = try? parseBlockGroup(bytes, dataOffset: valueOffset, size: Int(blockSize)) {
                    blocks.append(block)
                }
            default:
                break
            }
            cursor = valueOffset + Int(blockSize)
        }

        return MKVCluster(timestamp: timestamp, elementOffset: elementStart, elementEnd: elementEnd, blocks: blocks)
    }

    private static func isTopLevelID(_ id: UInt64) -> Bool {
        switch id {
        case EBMLID.segment.rawValue, EBMLID.info.rawValue, EBMLID.tracks.rawValue,
             EBMLID.cluster.rawValue, EBMLID.cues.rawValue, EBMLID.seekHead.rawValue,
             EBMLID.chapters.rawValue, EBMLID.tags.rawValue, EBMLID.attachments.rawValue,
             EBMLID.void.rawValue:
            return true
        default:
            return false
        }
    }

    /// The slice of `bytes` covering the cluster element at `offset` and the absolute offset
    /// where the following element begins. Returns nil if there's no cluster at `offset`.
    /// When the cluster is larger than `bytes`, `elementEnd` is still the true end (so callers
    /// can detect truncation and grow their window); the returned slice covers only what fits.
    public static func readClusterRange(bytes: Data, offset: Int) throws -> MKVClusterRange? {
        guard let header = EBML.readHeader(bytes, offset: offset), header.id == EBMLID.cluster.rawValue else { return nil }
        let headerLen = EBML.headerLength(header)
        let elementEnd: Int
        if let size = header.size {
            elementEnd = offset + headerLen + Int(size)
        } else {
            var end = offset + headerLen
            while end + 1 < bytes.count {
                if let next = EBML.readHeader(bytes, offset: end), isTopLevelID(next.id) { break }
                end += 1
            }
            elementEnd = end
        }
        let sliceEnd = min(elementEnd, bytes.count)
        return MKVClusterRange(elementEnd: elementEnd, bytes: bytes.subdata(in: offset..<sliceEnd))
    }

    /// Parses a SimpleBlock/Block payload (track number, timecode, flags, frame data).
    /// `valueOffset` points at the block's data (after the element ID + size).
    private static func parseBlock(_ bytes: Data, valueOffset: Int, size: Int, isSimple: Bool) throws -> MKVBlock {
        guard let trackInfo = EBML.readVarInt(bytes, offset: valueOffset) else {
            throw MatroskaError.truncated("block track number")
        }
        let trackNumber = trackInfo.value
        var cursor = valueOffset + trackInfo.length
        guard cursor + 3 <= valueOffset + size else { throw MatroskaError.truncated("block header") }

        let relativeTimestamp = EBML.readInt(bytes, offset: cursor, length: 2)
        cursor += 2
        let flags = bytes[bytes.startIndex + cursor]
        cursor += 1

        let isKeyframe: Bool
        if isSimple {
            isKeyframe = flags & 0x80 != 0
        } else {
            // Block: keyframe iff the BlockGroup carries no ReferenceBlock. The caller
            // resolves that; default to non-keyframe here.
            isKeyframe = true
        }
        let lacing = MKVLacing(rawValue: (Int(flags) >> 1) & 0x3) ?? .none
        let payload = bytes.subdata(in: cursor..<valueOffset + size)
        return MKVBlock(trackNumber: trackNumber, relativeTimestamp: relativeTimestamp, isKeyframe: isKeyframe, lacing: lacing, data: payload)
    }

    /// Parses a BlockGroup element into a single block (resolving ReferenceBlock for keyframes).
    private static func parseBlockGroup(_ bytes: Data, dataOffset: Int, size: Int) throws -> MKVBlock? {
        var block: MKVBlock?
        var hasReference = false
        var explicitDuration: UInt64?
        var cursor = dataOffset
        let end = dataOffset + size
        while cursor < end {
            guard let header = EBML.readHeader(bytes, offset: cursor) else { throw MatroskaError.truncated("BlockGroup") }
            guard let elementSize = header.size else { throw MatroskaError.undefinedSize("BlockGroup child") }
            let valueOffset = cursor + EBML.headerLength(header)
            switch header.id {
            case EBMLID.block.rawValue:
                var candidate = try parseBlock(bytes, valueOffset: valueOffset, size: Int(elementSize), isSimple: false)
                // Non-simple Blocks are keyframes only without a ReferenceBlock.
                candidate.isKeyframe = !hasReference
                block = candidate
            case EBMLID.referenceBlock.rawValue:
                hasReference = true
                block?.isKeyframe = false
            case EBMLID.blockDuration.rawValue:
                explicitDuration = EBML.readUInt(bytes, offset: valueOffset, length: Int(elementSize))
            default:
                break
            }
            cursor = valueOffset + Int(elementSize)
        }
        if var block {
            block.explicitDurationTicks = explicitDuration
            return block
        }
        return nil
    }

    /// Per-track sample stats for one cluster, used to size the resulting fMP4 fragment without
    /// retaining payload bytes (for the sidx / deterministic layout).
    public struct MKVClusterTrackLayout: Sendable {
        public let sampleCount: Int
        public let mdatSize: Int
        public let firstPTS: Int64
        public let lastPTS: Int64
        public let lastDelta: Int64
    }

    public struct MKVClusterLayout: Sendable {
        public let timestamp: UInt64
        public let tracks: [UInt64: MKVClusterTrackLayout]
    }

    /// Parses a cluster's structure (block headers + frame sizes) without materializing sample
    /// data, so the transmuxer can compute each fragment's exact fMP4 byte size up front.
    public static func scanClusterLayout(bytes: Data) throws -> MKVClusterLayout {
        guard let header = EBML.readHeader(bytes, offset: 0), header.id == EBMLID.cluster.rawValue else {
            throw MatroskaError.corrupt("expected cluster")
        }
        let dataStart = EBML.headerLength(header)
        let elementEnd: Int
        if let size = header.size {
            elementEnd = dataStart + Int(size)
            guard elementEnd <= bytes.count else { throw MatroskaError.truncated("cluster data") }
        } else {
            var cursor = dataStart
            var found = false
            var end = bytes.count
            while cursor + 1 < bytes.count {
                if let next = EBML.readHeader(bytes, offset: cursor), isTopLevelID(next.id) {
                    end = cursor
                    found = true
                    break
                }
                cursor += 1
            }
            guard found else { throw MatroskaError.truncated("cluster end") }
            elementEnd = end
        }

        var timestamp: UInt64 = 0
        var counts: [UInt64: Int] = [:]
        var mdat: [UInt64: Int] = [:]
        var firstPTS: [UInt64: Int64] = [:]
        var lastPTS: [UInt64: Int64] = [:]
        var lastDelta: [UInt64: Int64] = [:]
        var lastCount: [UInt64: Int] = [:]

        var cursor = dataStart
        while cursor < elementEnd {
            guard let blockHeader = EBML.readHeader(bytes, offset: cursor), let blockSize = blockHeader.size else { break }
            let valueOffset = cursor + EBML.headerLength(blockHeader)
            guard valueOffset + Int(blockSize) <= bytes.count else { break }
            switch blockHeader.id {
            case EBMLID.clusterTimestamp.rawValue:
                timestamp = EBML.readUInt(bytes, offset: valueOffset, length: Int(blockSize))
            case EBMLID.simpleBlock.rawValue, EBMLID.block.rawValue:
                if let block = try? parseBlock(bytes, valueOffset: valueOffset, size: Int(blockSize), isSimple: blockHeader.id == EBMLID.simpleBlock.rawValue) {
                    let frames = expandLacing(block) ?? [block]
                    let pts = Int64(timestamp) + block.relativeTimestamp
                    counts[block.trackNumber, default: 0] += frames.count
                    for frame in frames {
                        mdat[block.trackNumber, default: 0] += frame.data.count
                    }
                    if lastPTS[block.trackNumber] != nil {
                        let delta = pts - lastPTS[block.trackNumber]!
                        if delta > 0 { lastDelta[block.trackNumber] = delta }
                    } else {
                        firstPTS[block.trackNumber] = pts
                    }
                    lastPTS[block.trackNumber] = pts
                    lastCount[block.trackNumber] = frames.count
                }
            case EBMLID.blockGroup.rawValue:
                if let block = try? parseBlockGroup(bytes, dataOffset: valueOffset, size: Int(blockSize)) {
                    let frames = expandLacing(block) ?? [block]
                    let pts = Int64(timestamp) + block.relativeTimestamp
                    counts[block.trackNumber, default: 0] += frames.count
                    for frame in frames {
                        mdat[block.trackNumber, default: 0] += frame.data.count
                    }
                    if lastPTS[block.trackNumber] != nil {
                        let delta = pts - lastPTS[block.trackNumber]!
                        if delta > 0 { lastDelta[block.trackNumber] = delta }
                    } else {
                        firstPTS[block.trackNumber] = pts
                    }
                    lastPTS[block.trackNumber] = pts
                    lastCount[block.trackNumber] = frames.count
                }
            default:
                break
            }
            cursor = valueOffset + Int(blockSize)
        }

        var result: [UInt64: MKVClusterTrackLayout] = [:]
        for (track, count) in counts {
            result[track] = MKVClusterTrackLayout(
                sampleCount: count,
                mdatSize: mdat[track] ?? 0,
                firstPTS: firstPTS[track] ?? 0,
                lastPTS: lastPTS[track] ?? 0,
                lastDelta: lastDelta[track] ?? 0
            )
        }
        _ = lastCount
        return MKVClusterLayout(timestamp: timestamp, tracks: result)
    }

    /// Expands a laced block into its constituent frames (one sample per frame), distributing
    /// timestamps evenly across the block's duration. Returns nil if the block is not laced.
    public static func expandLacing(_ block: MKVBlock) -> [MKVBlock]? {
        guard block.lacing != .none else { return nil }

        var cursor = 0
        let payload = block.data
        var frames: [Data] = []
        let frameCount = Int(payload[payload.startIndex]) + 1
        cursor += 1

        switch block.lacing {
        case .xiph:
            var sizes: [Int] = []
            var running = 0
            for _ in 0..<(frameCount - 1) {
                var size = 0
                var byte: UInt8
                repeat {
                    guard cursor < payload.count else { return nil }
                    byte = payload[payload.startIndex + cursor]
                    cursor += 1
                    size += Int(byte)
                    if byte == 255 { continue }
                    sizes.append(size)
                    break
                } while true
                running += size
            }
            let remaining = payload.count - cursor - running
            guard remaining >= 0 else { return nil }
            sizes.append(remaining)
            for size in sizes {
                guard cursor + size <= payload.count else { return nil }
                frames.append(payload.subdata(in: cursor..<cursor + size))
                cursor += size
            }
        case .fixed:
            guard frameCount > 0 else { return nil }
            let remaining = payload.count - cursor
            guard remaining % frameCount == 0 else { return nil }
            let frameSize = remaining / frameCount
            for _ in 0..<frameCount {
                frames.append(payload.subdata(in: cursor..<cursor + frameSize))
                cursor += frameSize
            }
        case .ebml:
            guard frameCount >= 1 else { return nil }
            var sizes: [Int] = []
            var size = 0
            for i in 0..<(frameCount - 1) {
                var value = 0
                var width = 0
                var byte: UInt8
                repeat {
                    guard cursor < payload.count else { return nil }
                    byte = payload[payload.startIndex + cursor]
                    cursor += 1
                    value = (value << 7) | Int(byte & 0x7F)
                    width += 1
                } while byte & 0x80 == 0 && width < 4
                if i == 0 {
                    size = value
                } else {
                    size = size + (value - (1 << (7 * width - 1)) - 1)
                }
                sizes.append(size)
            }
            let remaining = payload.count - cursor
            var used = 0
            for size in sizes {
                used += size
            }
            let lastSize = remaining - used
            guard lastSize >= 0 else { return nil }
            sizes.append(lastSize)
            for size in sizes {
                guard cursor + size <= payload.count else { return nil }
                frames.append(payload.subdata(in: cursor..<cursor + size))
                cursor += size
            }
        case .none:
            return nil
        }

        guard frames.count == frameCount else { return nil }
        let duration = block.explicitDurationTicks ?? 0
        return frames.enumerated().map { index, frame in
            let frameDuration = duration > 0 ? duration / UInt64(frameCount) : 0
            let offset = duration > 0 ? Int64(frameDuration) * Int64(index) : 0
            return MKVBlock(
                trackNumber: block.trackNumber,
                relativeTimestamp: block.relativeTimestamp + offset,
                isKeyframe: block.isKeyframe && index == 0,
                lacing: .none,
                data: frame,
                explicitDurationTicks: duration > 0 ? frameDuration : nil
            )
        }
    }
}
