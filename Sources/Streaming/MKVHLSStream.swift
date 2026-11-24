import Foundation
import TorrentCore

enum MKVHLSStreamError: Error {
    case unavailable
    case invalidCues
    case segmentTooLarge
    case missingKeyframe
    case noPlayableTrack
}

struct MKVHLSSegment: Sendable, Equatable {
    let id: Int
    let startTimeTicks: UInt64
    let durationTicks: Double
    let sourceRange: Range<Int>
}

actor MKVHLSStream {
    static let maximumSegmentSize = 32 * 1024 * 1024
    private static let clusterProbeSize = 16 * 1024

    private struct Prepared: Sendable {
        let remuxer: MKVRemuxer
        let initSegment: Data
        let playlist: Data
        let segments: [MKVHLSSegment]
        let primaryTrackNumber: UInt64
        let primaryTrackIsVideo: Bool
    }

    private struct InFlight {
        let task: Task<Data, Error>
        var waiters: Set<UUID>
    }

    private struct Boundary {
        let time: UInt64
        let offset: Int
    }

    private let source: any TorrentStreamSource
    private let fileIndex: Int
    private var prepared: Prepared?
    private var inFlight: [Int: InFlight] = [:]
    private var lastSegment: (id: Int, data: Data)?

    init(source: any TorrentStreamSource, fileIndex: Int) {
        self.source = source
        self.fileIndex = fileIndex
    }

    func prepare() async throws {
        _ = try await preparedIndex()
    }

    func playlistData() async throws -> Data {
        try await preparedIndex().playlist
    }

    func initializationSegment() async throws -> Data {
        try await preparedIndex().initSegment
    }

    func segments() async throws -> [MKVHLSSegment] {
        try await preparedIndex().segments
    }

    func mediaSegment(id: Int) async throws -> Data {
        let prepared = try await preparedIndex()
        guard prepared.segments.indices.contains(id) else { throw MKVHLSStreamError.unavailable }
        if let lastSegment, lastSegment.id == id { return lastSegment.data }
        let task: Task<Data, Error>
        if let existing = inFlight[id] {
            task = existing.task
        } else {
            let segment = prepared.segments[id]
            task = Task { try await self.generateSegment(prepared: prepared, segment: segment) }
            inFlight[id] = InFlight(task: task, waiters: [])
        }
        let waiter = UUID()
        inFlight[id]?.waiters.insert(waiter)
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            Task { await self.leave(id: id, waiter: waiter, task: task) }
        }
        leave(id: id, waiter: waiter, task: task)
        switch result {
        case .success(let data):
            lastSegment = (id: id, data: data)
            return data
        case .failure(let error):
            TorrentLog.log("HLS segment \(id) failed: \(error)")
            throw error
        }
    }

    private func leave(id: Int, waiter: UUID, task: Task<Data, Error>) {
        guard var entry = inFlight[id], entry.task == task, entry.waiters.remove(waiter) != nil else { return }
        if entry.waiters.isEmpty {
            inFlight[id] = nil
            task.cancel()
        } else {
            inFlight[id] = entry
        }
    }

    private func preparedIndex() async throws -> Prepared {
        if let prepared { return prepared }
        let fileLength = await source.fileLength(fileIndex: fileIndex)
        guard fileLength > 0 else { throw MKVHLSStreamError.unavailable }
        let info = try await loadHead(fileLength: fileLength)
        let selectedTracks = MKVRemuxer.selectedTracks(info: info)
        guard let primaryTrack = selectedTracks.first(where: \.isVideo) ?? selectedTracks.first(where: \.isAudio) else {
            throw MKVHLSStreamError.noPlayableTrack
        }

        let segments: [MKVHLSSegment]
        do {
            segments = try await cueSegments(info: info, primaryTrack: primaryTrack, fileLength: fileLength)
        } catch let error where !(error is CancellationError) {
            guard await source.isComplete(fileIndex: fileIndex) else { throw error }
            TorrentLog.log("HLS: Cues unusable (\(error)), indexing the complete file's clusters")
            segments = try await clusterSegments(info: info, primaryTrack: primaryTrack, fileLength: fileLength)
        }

        let syncframes = try await dolbySyncframes(info: info, firstSegment: segments[0])
        let remuxer = try MKVRemuxer(info: info, audioSyncframes: syncframes)
        let playlist = Self.makePlaylist(segments: segments, timestampScaleNs: info.timestampScaleNs)
        TorrentLog.log("HLS prepared: \(segments.count) segments, last=\(segments.last?.sourceRange.description ?? "-")")
        if let prepared { return prepared }
        let result = Prepared(
            remuxer: remuxer,
            initSegment: remuxer.initSegment(),
            playlist: Data(playlist.utf8),
            segments: segments,
            primaryTrackNumber: primaryTrack.number,
            primaryTrackIsVideo: primaryTrack.isVideo
        )
        prepared = result
        return result
    }

    private func cueSegments(info: MatroskaInfo, primaryTrack: MKVTrack, fileLength: Int) async throws -> [MKVHLSSegment] {
        let cuePoints = info.cuePoints.isEmpty ? try await loadCues(info: info, fileLength: fileLength) : info.cuePoints
        guard let durationTicks = info.durationTicks, durationTicks.isFinite, durationTicks > 0,
              info.seconds(ticks: durationTicks) <= 7 * 24 * 60 * 60,
              let segmentDataStart = info.segmentDataStart else {
            throw MKVHLSStreamError.unavailable
        }
        var seenPositions = Set<Int>()
        let cues = cuePoints
            .filter { $0.trackNumber == primaryTrack.number }
            .sorted { ($0.time, $0.clusterPosition) < ($1.time, $1.clusterPosition) }
            .filter { seenPositions.insert($0.clusterPosition).inserted }
        guard let firstCue = cues.first, info.seconds(ticks: Double(firstCue.time)) < 0.1 else {
            throw MKVHLSStreamError.invalidCues
        }
        return try Self.segments(
            boundaries: cues.map { Boundary(time: $0.time, offset: segmentDataStart + $0.clusterPosition) },
            end: min(info.segmentDataEnd ?? fileLength, fileLength),
            durationTicks: durationTicks
        )
    }

    private func clusterSegments(info: MatroskaInfo, primaryTrack: MKVTrack, fileLength: Int) async throws -> [MKVHLSSegment] {
        guard var offset = info.clustersStart else { throw MKVHLSStreamError.unavailable }
        let end = min(info.segmentDataEnd ?? fileLength, fileLength)
        var boundaries: [Boundary] = []
        var lastCluster: Range<Int>?
        while offset < end {
            try Task.checkCancellation()
            let probe = try await readExact(range: offset..<min(offset + Self.clusterProbeSize, end))
            guard let header = EBML.readHeader(in: probe, offset: 0) else {
                throw MatroskaError.corrupt("element header at \(offset)")
            }
            guard header.id == EBMLID.cluster.rawValue else {
                guard let size = header.size else { throw MatroskaError.undefinedSize("Segment child at \(offset)") }
                offset += header.length + Int(size)
                continue
            }
            let clusterEnd = try await clusterEnd(offset: offset, probe: probe, limit: end)
            let start = try await clusterStart(offset: offset, end: clusterEnd, probe: probe, trackNumber: primaryTrack.number)
            if boundaries.isEmpty {
                boundaries.append(Boundary(time: start.timestamp, offset: offset))
            } else if let block = start.firstBlock, block.isKeyframe || !primaryTrack.isVideo {
                let time = UInt64(max(0, Int64(start.timestamp) + block.relativeTimestamp))
                if let previous = boundaries.last, time > previous.time {
                    boundaries.append(Boundary(time: time, offset: offset))
                }
            }
            lastCluster = offset..<clusterEnd
            offset = clusterEnd
        }
        guard let lastCluster else { throw MKVHLSStreamError.unavailable }

        let durationTicks: Double
        if let declared = info.durationTicks, declared.isFinite, declared > 0 {
            durationTicks = declared
        } else {
            guard lastCluster.count <= Self.maximumSegmentSize else { throw MKVHLSStreamError.segmentTooLarge }
            let bytes = try await readExact(range: lastCluster)
            let cluster = try MatroskaParser.parseCluster(bytes: bytes, range: 0..<bytes.count)
            durationTicks = try Self.endTicks(of: cluster, info: info)
        }
        return try Self.segments(boundaries: boundaries, end: lastCluster.upperBound, durationTicks: durationTicks)
    }

    private func clusterEnd(offset: Int, probe: Data, limit: Int) async throws -> Int {
        var window = probe
        while true {
            if let end = try MatroskaParser.clusterEnd(bytes: window, offset: 0) {
                guard end > 0, offset + end <= limit else { throw MatroskaError.corrupt("Cluster at \(offset) overruns the Segment") }
                return offset + end
            }
            if offset + window.count >= limit { return limit }
            guard window.count < Self.maximumSegmentSize else { throw MKVHLSStreamError.segmentTooLarge }
            window = try await readExact(range: offset..<min(offset + window.count * 4, limit))
        }
    }

    private func clusterStart(
        offset: Int,
        end: Int,
        probe: Data,
        trackNumber: UInt64
    ) async throws -> (timestamp: UInt64, firstBlock: MKVBlock?) {
        var window = probe
        while true {
            do {
                return try MatroskaParser.clusterStart(bytes: window, clusterEnd: end - offset, trackNumber: trackNumber)
            } catch MatroskaError.truncated {
                guard offset + window.count < end else { throw MatroskaError.corrupt("Cluster at \(offset)") }
                guard window.count < Self.maximumSegmentSize else { throw MKVHLSStreamError.segmentTooLarge }
                window = try await readExact(range: offset..<min(offset + window.count * 4, end))
            }
        }
    }

    private static func endTicks(of cluster: MKVCluster, info: MatroskaInfo) throws -> Double {
        var end = Double(cluster.timestamp)
        for block in cluster.blocks {
            let defaultTicks = info.tracks.first { $0.number == block.trackNumber }?.defaultDurationNs
                .map { Double($0) / Double(info.timestampScaleNs) } ?? 0
            for frame in try MatroskaParser.frames(of: block, frameDurationTicks: defaultTicks) {
                let duration = frame.explicitDurationTicks.map(Double.init) ?? defaultTicks
                end = max(end, Double(Int64(cluster.timestamp) + frame.relativeTimestamp) + duration)
            }
        }
        return end
    }

    private static func segments(boundaries: [Boundary], end: Int, durationTicks: Double) throws -> [MKVHLSSegment] {
        var segments: [MKVHLSSegment] = []
        for (index, boundary) in boundaries.enumerated() {
            let next = index + 1 < boundaries.count ? boundaries[index + 1] : nil
            let segmentEnd = next?.offset ?? end
            let duration = (next.map { Double($0.time) } ?? durationTicks) - Double(boundary.time)
            guard boundary.offset >= 0, segmentEnd > boundary.offset, segmentEnd <= end,
                  duration.isFinite, duration > 0 else {
                throw MKVHLSStreamError.invalidCues
            }
            guard segmentEnd - boundary.offset <= maximumSegmentSize else {
                throw MKVHLSStreamError.segmentTooLarge
            }
            segments.append(MKVHLSSegment(
                id: index,
                startTimeTicks: boundary.time,
                durationTicks: duration,
                sourceRange: boundary.offset..<segmentEnd
            ))
        }
        guard !segments.isEmpty else { throw MKVHLSStreamError.invalidCues }
        return segments
    }

    private func dolbySyncframes(info: MatroskaInfo, firstSegment: MKVHLSSegment) async throws -> [UInt64: Data] {
        let needed = Set(MKVRemuxer.dolbyTrackNumbersNeedingSyncframe(info: info))
        guard !needed.isEmpty else { return [:] }
        let bytes = try await readExact(range: firstSegment.sourceRange)
        return try MatroskaParser.firstFrames(of: needed, in: MatroskaParser.clusters(in: bytes, range: 0..<bytes.count))
    }

    private func generateSegment(prepared: Prepared, segment: MKVHLSSegment) async throws -> Data {
        let bytes = try await readExact(range: segment.sourceRange)
        var remuxer = prepared.remuxer.starting(atTimelineTicks: Int64(segment.startTimeTicks))
        let selectedTrackNumbers = Set(prepared.remuxer.selectedTrackNumbers)
        var foundPrimaryKeyframe = !prepared.primaryTrackIsVideo
        var output = Data()
        for (index, var cluster) in try MatroskaParser.clusters(in: bytes, range: 0..<bytes.count).enumerated() {
            try Task.checkCancellation()
            if index == 0 {
                let clusterTimestamp = Int64(cluster.timestamp)
                cluster.blocks = cluster.blocks.filter { block in
                    guard selectedTrackNumbers.contains(block.trackNumber) else { return true }
                    guard clusterTimestamp + block.relativeTimestamp >= Int64(segment.startTimeTicks) else { return false }
                    if block.trackNumber == prepared.primaryTrackNumber, prepared.primaryTrackIsVideo {
                        if block.isKeyframe { foundPrimaryKeyframe = true }
                        return foundPrimaryKeyframe
                    }
                    return true
                }
            }
            if let fragment = try remuxer.consume(cluster) { output.append(fragment) }
        }
        guard foundPrimaryKeyframe, !output.isEmpty else { throw MKVHLSStreamError.missingKeyframe }
        return output
    }

    private func loadHead(fileLength: Int) async throws -> MatroskaInfo {
        let cap = min(4 * 1024 * 1024, fileLength)
        var window = min(256 * 1024, cap)
        while true {
            let data = try await readExact(range: 0..<window)
            do {
                return try MatroskaParser.parseHead(bytes: data)
            } catch MatroskaError.truncated {
                guard window < cap else { throw MKVHLSStreamError.unavailable }
                window = min(window * 2, cap)
            }
        }
    }

    private func loadCues(info: MatroskaInfo, fileLength: Int) async throws -> [MKVCuePoint] {
        guard let cuesOffset = info.cuesOffset, cuesOffset < fileLength else {
            throw MKVHLSStreamError.invalidCues
        }
        let probe = try await readExact(range: cuesOffset..<min(cuesOffset + 16, fileLength))
        guard let header = EBML.readHeader(in: probe, offset: 0), header.id == EBMLID.cues.rawValue,
              let size = header.size, size <= 16 * 1024 * 1024 else {
            throw MKVHLSStreamError.invalidCues
        }
        let totalSize = header.length + Int(size)
        guard cuesOffset + totalSize <= fileLength else { throw MKVHLSStreamError.invalidCues }
        let data = totalSize <= probe.count
            ? probe
            : try await readExact(range: cuesOffset..<cuesOffset + totalSize)
        return try MatroskaParser.parseCues(bytes: data, range: header.length..<totalSize)
    }

    private func readExact(range: Range<Int>) async throws -> Data {
        guard !range.isEmpty else { return Data() }
        var polls = 0
        while true {
            try Task.checkCancellation()
            if await source.availability(fileIndex: fileIndex, offset: range.lowerBound) >= range.count,
               let data = await source.read(fileIndex: fileIndex, offset: range.lowerBound, length: range.count) {
                return data
            }
            if polls % 10 == 0 {
                await source.prioritize(fileIndex: fileIndex, range: range)
            }
            polls += 1
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

actor MKVHLSStreamCache {
    static let shared = MKVHLSStreamCache()
    private static let capacity = 4

    struct Key: Hashable, Sendable {
        let infoHash: Data
        let fileIndex: Int
    }

    private var streams: [Key: MKVHLSStream] = [:]
    private var order: [Key] = []

    func store(_ stream: MKVHLSStream, key: Key) {
        if streams.updateValue(stream, forKey: key) == nil { order.append(key) }
        while order.count > Self.capacity {
            streams[order.removeFirst()] = nil
        }
    }

    func take(key: Key) -> MKVHLSStream? {
        order.removeAll { $0 == key }
        return streams.removeValue(forKey: key)
    }
}
