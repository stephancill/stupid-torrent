import Foundation

/// Converts parsed Matroska structure into muxed fMP4 fragments, one fragment per MKV cluster.
/// Sample decode order = MKV block order; block timestamps are presentation times, so the muxer
/// derives a monotonic DTS (running sum of durations) and emits composition offsets (PTS - DTS).
public final class MKVRemuxer: @unchecked Sendable {
    public let info: MatroskaInfo
    public let tracks: [TransmuxTrack]
    public let selectedMKVTrackNumbers: [UInt64]
    /// MKV track number → index into `tracks`.
    private let indexByMKVNumber: [UInt64: Int]
    private var states: [UInt64: TrackState] = [:]
    private var sequence = 0

    public init(info: MatroskaInfo, timelineOffsetTicks: Int64 = 0) throws {
        self.info = info
        var tracks: [TransmuxTrack] = []
        var indexByMKVNumber: [UInt64: Int] = [:]
        var trackId = 1
        let supportedTracks = info.tracks.filter {
            $0.isEnabled && $0.isTransmuxable && Self.codec(for: $0) != nil
        }
        let selectedTracks = [UInt64(1), UInt64(2)].compactMap { trackType in
            supportedTracks.first { $0.trackType == trackType && $0.isDefault }
                ?? supportedTracks.first { $0.trackType == trackType }
        }
        for mkvTrack in selectedTracks {
            guard let codec = Self.codec(for: mkvTrack) else { continue }
            // Per-track timescale. Video uses a standard 16,000; audio uses its sample rate so
            // fixed-duration codec frames remain exact (AAC = 1024 samples).
            let timescale = mkvTrack.trackType == 1
                ? 16000
                : Int((mkvTrack.samplingFrequency ?? 48000).rounded())
            var audioConfig: Data?
            if codec == .eac3, let privateData = mkvTrack.codecPrivate {
                audioConfig = MP4Muxer.eac3Config(fromSyncframe: privateData)
            }
            if codec == .ac3, let privateData = mkvTrack.codecPrivate {
                audioConfig = MP4Muxer.ac3Config(fromSyncframe: privateData)
            }
            let track = TransmuxTrack(
                trackId: trackId,
                timescale: timescale,
                codec: codec,
                codecPrivate: mkvTrack.codecPrivate,
                audioConfig: audioConfig,
                width: mkvTrack.videoWidth.map { Int($0) },
                height: mkvTrack.videoHeight.map { Int($0) },
                channels: Int(mkvTrack.channels ?? 2),
                sampleRate: mkvTrack.samplingFrequency ?? 48000,
                bitDepth: Int(mkvTrack.bitDepth ?? 16),
                language: mkvTrack.language,
                durationTicks: 0 // Fragmented MP4: the fragments define the timeline.
            )
            tracks.append(track)
            indexByMKVNumber[mkvTrack.number] = trackId
            states[mkvTrack.number] = TrackState(
                timescale: timescale,
                mkvTrack: mkvTrack,
                nextDecodeTime: 0,
                presentationTimeOffset: Int64(
                    (Double(timelineOffsetTicks) * Double(info.timestampScaleNs) * Double(timescale) / 1e9).rounded()
                )
            )
            trackId += 1
        }
        self.tracks = tracks
        self.indexByMKVNumber = indexByMKVNumber
        self.selectedMKVTrackNumbers = selectedTracks.map(\.number)
    }

    /// Whether at least one track was carried into the fMP4.
    public var hasMedia: Bool { !tracks.isEmpty }

    /// The init segment (ftyp + moov), valid once the head is parsed.
    public func initSegment() -> Data {
        MP4Muxer.initSegment(tracks: tracks)
    }

    /// One sidx reference: a fragment's exact byte size and its duration in the sidx timescale.
    public struct SidxReference: Sendable {
        public let size: Int
        public let durationTicks: Int64
        public init(size: Int, durationTicks: Int64) {
            self.size = size
            self.durationTicks = durationTicks
        }
    }

    /// Walks an in-memory MKV's clusters and computes each fragment's exact fMP4 byte size and
    /// presentation span (for the sidx / deterministic layout).
    public func sidxReferences(mkvBytes: Data) -> [SidxReference]? {
        var references: [SidxReference] = []
        var offset = info.firstClusterOffset ?? 0
        // MKV ticks → sidx timescale (1000): 1:1 for the standard 1 ms timestamp scale.
        let factor = Double(1000) * Double(info.timestampScaleNs) / 1e9
        while offset < mkvBytes.count {
            guard let range = try? MatroskaParser.readClusterRange(bytes: mkvBytes, offset: offset) else { break }
            guard let clusterLayout = try? MatroskaParser.scanClusterLayout(bytes: range.bytes) else { break }
            if let size = fragmentSizeForKeptTracks(clusterLayout) {
                let duration = fragmentDurationForKeptTracks(clusterLayout)
                references.append(SidxReference(
                    size: size,
                    durationTicks: Int64(Double(duration) * factor)
                ))
            }
            offset = range.elementEnd
        }
        return references
    }

    /// Init segment with a `sidx` listing `references` (precise seeks for complete files).
    public func initSegment(withSidx references: [SidxReference]) -> Data {
        var data = MP4Muxer.initSegment(tracks: tracks)
        data.append(MP4Muxer.sidx(
            timescale: 1000,
            references: references.map { (size: $0.size, durationTicks: $0.durationTicks) }
        ))
        return data
    }

    /// Exact byte size of the fMP4 fragment a cluster muxes to: moof + mdat. Deterministic since
    /// every trun carries per-sample duration/size/flags/composition-offset (16 B/sample).
    public static func fragmentSize(_ layout: MatroskaParser.MKVClusterLayout) -> Int {
        let moof = 8 + 16 + layout.tracks.values.reduce(0) { $0 + (64 + 16 * $1.sampleCount) }
        let mdat = 8 + layout.tracks.values.reduce(0) { $0 + $1.mdatSize }
        return moof + mdat
    }

    /// Presentation span of a cluster's samples in MKV ticks (max end − min start), used for the
    /// sidx subsegment duration.
    public static func fragmentDuration(_ layout: MatroskaParser.MKVClusterLayout, info: MatroskaInfo) -> Int64 {
        fragmentDuration(layout.tracks, info: info)
    }

    func fragmentSizeForKeptTracks(_ layout: MatroskaParser.MKVClusterLayout) -> Int? {
        let tracks = layout.tracks.filter { indexByMKVNumber[$0.key] != nil }
        guard !tracks.isEmpty else { return nil }
        let moof = 8 + 16 + tracks.values.reduce(0) { $0 + (64 + 16 * $1.sampleCount) }
        let mdat = 8 + tracks.values.reduce(0) { $0 + $1.mdatSize }
        return moof + mdat
    }

    func fragmentDurationForKeptTracks(_ layout: MatroskaParser.MKVClusterLayout) -> Int64 {
        let tracks = layout.tracks.filter { indexByMKVNumber[$0.key] != nil }
        return Self.fragmentDuration(tracks, info: info)
    }

    private static func fragmentDuration(
        _ tracks: [UInt64: MatroskaParser.MKVClusterTrackLayout],
        info: MatroskaInfo
    ) -> Int64 {
        let scale = Int64(max(1, info.timestampScaleNs))
        var minStart = Int64.max
        var maxEnd = Int64.min
        for (trackNumber, track) in tracks {
            let mkvTrack = info.track(trackNumber)
            let defaultDur: Int64
            if let ns = mkvTrack?.defaultDurationNs {
                defaultDur = (Int64(ns) + scale / 2) / scale
            } else {
                defaultDur = 0
            }
            let lastDur = defaultDur > 0 ? defaultDur : track.lastDelta
            minStart = min(minStart, track.firstPTS)
            maxEnd = max(maxEnd, track.lastPTS + lastDur)
        }
        guard minStart != Int64.max, maxEnd != Int64.min else { return 0 }
        return max(0, maxEnd - minStart)
    }

    /// Consumes one cluster, returning the fragment (moof + mdat) it muxes, or nil if the cluster
    /// carried no samples for any kept track. Emits a sequence number per emitted fragment.
    public func consume(_ cluster: MKVCluster) throws -> Data? {
        var fragments: [TransmuxFragment] = []
        var byMKVNumber: [UInt64: [MKVBlock]] = [:]
        for block in cluster.blocks {
            byMKVNumber[block.trackNumber, default: []].append(block)
        }
        for mkvNumber in byMKVNumber.keys.sorted() {
            guard let state = states[mkvNumber], let trackId = indexByMKVNumber[mkvNumber] else { continue }
            let samples = try state.samples(from: byMKVNumber[mkvNumber]!, clusterTimestamp: cluster.timestamp, info: info)
            if !samples.isEmpty {
                fragments.append(TransmuxFragment(trackId: trackId, samples: samples))
            }
        }
        guard !fragments.isEmpty else { return nil }
        sequence += 1
        return MP4Muxer.fragment(sequenceNumber: sequence, tracks: tracks, fragments: fragments)
    }

    private static func codec(for mkvTrack: MKVTrack) -> TransmuxCodec? {
        switch mkvTrack.codecID {
        case "V_MPEG4/ISO/AVC": .h264
        case "V_MPEGH/ISO/HEVC": .hevc
        case "A_AAC": .aac
        case "A_EAC3": .eac3
        case "A_AC3": .ac3
        case "A_ALAC": .alac
        default: nil
        }
    }

    /// MKV timestamps are in `timestampScaleNs` ticks; using that as the fMP4 timescale makes
    /// segment ticks map 1:1 into track ticks (no rounding drift).
    static func timescale(timestampScaleNs: UInt64) -> Int {
        Int(1_000_000_000 / max(1, timestampScaleNs))
    }

    /// Per-track running mux state. Timestamps are accumulated in MKV tick units and scaled to
    /// the track timescale at emit time.
    private final class TrackState: @unchecked Sendable {
        let timescale: Int
        let mkvTrack: MKVTrack
        let presentationTimeOffset: Int64
        private var nextDecodeTime: Int64
        private var lastDelta: Int64?
        /// True once a negative decode-order PTS delta is seen (video with B-frames); such tracks
        /// need a constant frame duration for their DTS instead of PTS deltas.
        private var hasReorder: Bool?

        init(timescale: Int, mkvTrack: MKVTrack, nextDecodeTime: Int64, presentationTimeOffset: Int64) {
            self.timescale = timescale
            self.mkvTrack = mkvTrack
            self.nextDecodeTime = nextDecodeTime
            self.presentationTimeOffset = presentationTimeOffset
        }

        private func defaultDurationTicks(info: MatroskaInfo) -> Int64? {
            guard let ns = mkvTrack.defaultDurationNs else { return nil }
            return Int64((Double(ns) * Double(timescale) / 1e9).rounded())
        }

        private func presentationTicks(_ mkvTicks: Int64, info: MatroskaInfo) -> Int64 {
            Int64(
                (Double(mkvTicks) * Double(info.timestampScaleNs) * Double(timescale) / 1e9).rounded()
            ) - presentationTimeOffset
        }

        func samples(from blocks: [MKVBlock], clusterTimestamp: UInt64, info: MatroskaInfo) throws -> [TransmuxSample] {
            var frames: [(pts: Int64, data: Data, isKeyframe: Bool)] = []
            for block in blocks {
                let expanded = MatroskaParser.expandLacing(block) ?? [block]
                for frame in expanded {
                    frames.append((
                        presentationTicks(Int64(clusterTimestamp) + frame.relativeTimestamp, info: info),
                        frame.data,
                        frame.isKeyframe
                    ))
                }
            }
            guard !frames.isEmpty else { return [] }

            // Detect reordering (B-frames): a decode-order PTS step backwards within this batch.
            if hasReorder == nil {
                for i in 1..<frames.count where frames[i].pts < frames[i - 1].pts {
                    hasReorder = true
                    break
                }
                if hasReorder == nil { hasReorder = false }
            }
            let isVideo = mkvTrack.trackType == 1
            let defaultDur = defaultDurationTicks(info: info)
            let codecFrameDuration = mkvTrack.codecID == "A_AAC" ? Int64(1024) : nil

            var result: [TransmuxSample] = []
            result.reserveCapacity(frames.count)
            for (index, frame) in frames.enumerated() {
                let duration: Int64
                if let codecFrameDuration {
                    duration = codecFrameDuration
                } else if hasReorder == true && isVideo {
                    // B-frame video: constant frame duration keeps DTS monotonic; composition
                    // offsets preserve the exact PTS. Prefer the track's declared duration.
                    duration = defaultDur ?? (lastDelta ?? 0)
                } else if index + 1 < frames.count {
                    let delta = frames[index + 1].pts - frame.pts
                    duration = delta > 0 ? delta : (defaultDur ?? 0)
                } else {
                    duration = lastDelta ?? defaultDur ?? 0
                }
                if duration > 0 { lastDelta = duration }
                // Audio frames are always independently decodable even if the container didn't
                // set the keyframe bit (mirrors mediabunny/ffmpeg).
                let isKeyframe = isVideo ? frame.isKeyframe : true
                result.append(TransmuxSample(
                    data: frame.data,
                    durationTicks: duration,
                    decodeTimeTicks: nextDecodeTime,
                    compositionOffsetTicks: frame.pts - nextDecodeTime,
                    isKeyframe: isKeyframe
                ))
                nextDecodeTime += duration
            }
            return result
        }
    }
}
