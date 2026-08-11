import Foundation

enum MKVHLSStreamError: Error {
    case unavailable
    case invalidCues
    case segmentTooLarge
    case missingKeyframe
}

struct MKVHLSSegment: Sendable, Equatable {
    let id: Int
    let startTimeTicks: UInt64
    let durationTicks: Double
    let sourceRange: Range<Int>
}

actor MKVHLSStream {
    private struct Prepared {
        let info: MatroskaInfo
        let initSegment: Data
        let playlist: Data
        let segments: [MKVHLSSegment]
        let selectedTrackNumbers: Set<UInt64>
        let primaryTrackNumber: UInt64
        let primaryTrackIsVideo: Bool
    }

    private let source: any TorrentStreamSource
    private let fileIndex: Int
    private let maximumSegmentSize: Int
    private var prepared: Prepared?
    private var segmentCache: [Int: Data] = [:]
    private var cacheOrder: [Int] = []
    private var isGeneratingSegment = false

    init(
        source: any TorrentStreamSource,
        fileIndex: Int,
        maximumSegmentSize: Int = 32 * 1024 * 1024
    ) {
        self.source = source
        self.fileIndex = fileIndex
        self.maximumSegmentSize = maximumSegmentSize
    }

    func prepare() async throws {
        if prepared != nil { return }
        let fileLength = await source.fileLength(fileIndex: fileIndex)
        guard fileLength > 0 else { throw MKVHLSStreamError.unavailable }
        var info = try await loadHead(fileLength: fileLength)
        try await loadCues(info: &info, fileLength: fileLength)
        guard let durationTicks = info.durationTicks, durationTicks.isFinite, durationTicks > 0,
              let segmentDataStart = info.segmentDataStart else {
            throw MKVHLSStreamError.unavailable
        }
        let durationSeconds = durationTicks * Double(info.timestampScaleNs) / 1e9
        guard durationSeconds.isFinite, durationSeconds <= 7 * 24 * 60 * 60 else {
            throw MKVHLSStreamError.unavailable
        }

        let remuxer = try MKVRemuxer(info: info)
        let selectedTracks = Set(remuxer.selectedMKVTrackNumbers)
        guard let primaryTrack = info.tracks.first(where: {
            selectedTracks.contains($0.number) && $0.trackType == 1
        }) ?? info.tracks.first(where: {
            selectedTracks.contains($0.number) && $0.trackType == 2
        }) else {
            throw MKVHLSStreamError.unavailable
        }

        var cues = info.cuePoints
            .filter { $0.trackNumber == primaryTrack.number }
            .sorted {
                $0.time == $1.time
                    ? $0.clusterPosition < $1.clusterPosition
                    : $0.time < $1.time
            }
        var seenPositions = Set<Int>()
        cues = cues.filter { seenPositions.insert($0.clusterPosition).inserted }
        guard let firstCue = cues.first,
              Double(firstCue.time) * Double(info.timestampScaleNs) / 1e9 < 0.1 else {
            throw MKVHLSStreamError.invalidCues
        }

        var segments: [MKVHLSSegment] = []
        for index in cues.indices {
            let cue = cues[index]
            let (start, startOverflow) = segmentDataStart.addingReportingOverflow(cue.clusterPosition)
            let end: Int
            let endOverflow: Bool
            if index + 1 < cues.count {
                (end, endOverflow) = segmentDataStart.addingReportingOverflow(cues[index + 1].clusterPosition)
            } else {
                end = min(info.segmentDataEnd ?? fileLength, fileLength)
                endOverflow = false
            }
            let endTicks = index + 1 < cues.count ? Double(cues[index + 1].time) : durationTicks
            let segmentDuration = endTicks - Double(cue.time)
            guard !startOverflow, !endOverflow, start >= 0, end > start, end <= fileLength,
                  segmentDuration.isFinite, segmentDuration > 0 else {
                throw MKVHLSStreamError.invalidCues
            }
            guard end - start <= maximumSegmentSize else {
                throw MKVHLSStreamError.segmentTooLarge
            }
            if let previous = segments.last {
                guard cue.time > previous.startTimeTicks,
                      start >= previous.sourceRange.upperBound else {
                    throw MKVHLSStreamError.invalidCues
                }
            }
            segments.append(MKVHLSSegment(
                id: index,
                startTimeTicks: cue.time,
                durationTicks: segmentDuration,
                sourceRange: start..<end
            ))
        }

        let playlist = Self.makePlaylist(segments: segments, timestampScaleNs: info.timestampScaleNs)
        prepared = Prepared(
            info: info,
            initSegment: remuxer.initSegment(),
            playlist: Data(playlist.utf8),
            segments: segments,
            selectedTrackNumbers: selectedTracks,
            primaryTrackNumber: primaryTrack.number,
            primaryTrackIsVideo: primaryTrack.trackType == 1
        )
    }

    func playlistData() async throws -> Data {
        try await prepare()
        guard let prepared else { throw MKVHLSStreamError.unavailable }
        return prepared.playlist
    }

    func initializationSegment() async throws -> Data {
        try await prepare()
        guard let prepared else { throw MKVHLSStreamError.unavailable }
        return prepared.initSegment
    }

    func segments() async throws -> [MKVHLSSegment] {
        try await prepare()
        guard let prepared else { throw MKVHLSStreamError.unavailable }
        return prepared.segments
    }

    func mediaSegment(id: Int) async throws -> Data {
        try await prepare()
        if let cached = segmentCache[id] { return cached }
        while isGeneratingSegment {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        isGeneratingSegment = true
        defer { isGeneratingSegment = false }
        if let cached = segmentCache[id] { return cached }
        guard let prepared, prepared.segments.indices.contains(id) else {
            throw MKVHLSStreamError.unavailable
        }
        let plan = prepared.segments[id]
        let bytes = try await readExact(range: plan.sourceRange)
        let remuxer = try MKVRemuxer(
            info: prepared.info,
            timelineOffsetTicks: Int64(plan.startTimeTicks)
        )
        var output = Data()
        var offset = 0
        var foundPrimaryKeyframe = !prepared.primaryTrackIsVideo
        while offset < bytes.count {
            try Task.checkCancellation()
            guard let range = try MatroskaParser.readClusterRange(bytes: bytes, offset: offset) else {
                guard let header = EBML.readHeader(bytes, offset: offset), let size = header.size else {
                    throw MKVHLSStreamError.unavailable
                }
                let (elementEnd, overflow) = (offset + EBML.headerLength(header)).addingReportingOverflow(Int(size))
                guard !overflow, elementEnd > offset, elementEnd <= bytes.count else {
                    throw MKVHLSStreamError.unavailable
                }
                offset = elementEnd
                continue
            }
            guard range.elementEnd > offset, range.elementEnd <= bytes.count else {
                throw MKVHLSStreamError.unavailable
            }
            var cluster = try MatroskaParser.parseCluster(bytes: range.bytes, segmentDataStart: 0)
            if offset == 0 {
                cluster.blocks = cluster.blocks.filter { block in
                    guard prepared.selectedTrackNumbers.contains(block.trackNumber) else { return true }
                    let timestamp = Int64(cluster.timestamp) + block.relativeTimestamp
                    guard timestamp >= Int64(plan.startTimeTicks) else { return false }
                    if block.trackNumber == prepared.primaryTrackNumber, prepared.primaryTrackIsVideo {
                        if !foundPrimaryKeyframe, block.isKeyframe { foundPrimaryKeyframe = true }
                        return foundPrimaryKeyframe
                    }
                    return true
                }
            }
            if let fragment = try remuxer.consume(cluster) { output.append(fragment) }
            offset = range.elementEnd
        }
        guard foundPrimaryKeyframe, !output.isEmpty else { throw MKVHLSStreamError.missingKeyframe }

        segmentCache[id] = output
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
        while cacheOrder.count > 1 {
            let evicted = cacheOrder.removeFirst()
            segmentCache.removeValue(forKey: evicted)
        }
        return output
    }

    private func loadHead(fileLength: Int) async throws -> MatroskaInfo {
        var window = min(256 * 1024, fileLength)
        let cap = min(4 * 1024 * 1024, fileLength)
        while window <= cap {
            let data = try await readExact(range: 0..<window)
            do {
                return try MatroskaParser.parseHead(bytes: data)
            } catch MatroskaError.truncated {
                if window == cap { throw MKVHLSStreamError.unavailable }
                window = min(window * 2, cap)
            }
        }
        throw MKVHLSStreamError.unavailable
    }

    private func loadCues(info: inout MatroskaInfo, fileLength: Int) async throws {
        if !info.cuePoints.isEmpty { return }
        guard let cuesOffset = info.cuesOffset, cuesOffset < fileLength else {
            throw MKVHLSStreamError.invalidCues
        }
        let probeEnd = min(cuesOffset + 16, fileLength)
        let probe = try await readExact(range: cuesOffset..<probeEnd)
        guard let header = EBML.readHeader(probe, offset: 0),
              header.id == EBMLID.cues.rawValue,
              let size = header.size else {
            throw MKVHLSStreamError.invalidCues
        }
        let totalSize = EBML.headerLength(header) + Int(size)
        guard totalSize <= 16 * 1024 * 1024, cuesOffset + totalSize <= fileLength else {
            throw MKVHLSStreamError.invalidCues
        }
        let data = totalSize <= probe.count
            ? probe.subdata(in: 0..<totalSize)
            : try await readExact(range: cuesOffset..<cuesOffset + totalSize)
        try MatroskaParser.parseCues(
            data,
            dataOffset: EBML.headerLength(header),
            size: Int(size),
            into: &info
        )
    }

    private func readExact(range: Range<Int>) async throws -> Data {
        guard !range.isEmpty else { return Data() }
        await source.prioritize(fileIndex: fileIndex, range: range)
        while true {
            try Task.checkCancellation()
            let available = await source.availability(fileIndex: fileIndex, offset: range.lowerBound)
            if available >= range.count,
               let data = await source.read(
                   fileIndex: fileIndex,
                   offset: range.lowerBound,
                   length: range.count
               ) {
                return data
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func makePlaylist(segments: [MKVHLSSegment], timestampScaleNs: UInt64) -> String {
        let durations = segments.map { $0.durationTicks * Double(timestampScaleNs) / 1e9 }
        let targetDuration = max(1, Int(ceil(durations.max() ?? 1)))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ]
        for (index, duration) in durations.enumerated() {
            if index > 0 { lines.append("#EXT-X-DISCONTINUITY") }
            lines.append(String(format: "#EXTINF:%.6f,", duration))
            lines.append("segments/\(index).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}
