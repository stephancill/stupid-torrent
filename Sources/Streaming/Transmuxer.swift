import Foundation

/// Converts parsed Matroska structure into muxed fMP4 fragments, one fragment per MKV cluster.
/// Sample decode order = MKV block order; block timestamps are presentation times, so the muxer
/// derives a monotonic DTS (running sum of durations) and emits composition offsets (PTS - DTS).
public final class MKVRemuxer: @unchecked Sendable {
    public let info: MatroskaInfo
    public let tracks: [TransmuxTrack]
    /// MKV track number → index into `tracks`.
    private let indexByMKVNumber: [UInt64: Int]
    private var states: [UInt64: TrackState] = [:]
    private var sequence = 0

    public init(info: MatroskaInfo) throws {
        self.info = info
        var tracks: [TransmuxTrack] = []
        var indexByMKVNumber: [UInt64: Int] = [:]
        var trackId = 1
        for mkvTrack in info.tracks where mkvTrack.isTransmuxable {
            guard let codec = Self.codec(for: mkvTrack) else { continue }
            // Per-track timescale. Video uses a standard 16,000 (AVAsset's duration computation
            // mis-estimates with a coarse 1000-scale; timestamps map exactly since it's ×1000·16).
            // Audio keeps the MKV tick scale (sample-rate conversion would re-introduce rounding
            // drift on the frame durations).
            let timescale = mkvTrack.trackType == 1 ? 16000 : Self.timescale(timestampScaleNs: info.timestampScaleNs)
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
            let baseTimescale = Self.timescale(timestampScaleNs: info.timestampScaleNs)
            states[mkvTrack.number] = TrackState(
                timescale: timescale,
                scale: Int64(timescale) / Int64(max(1, baseTimescale)),
                mkvTrack: mkvTrack
            )
            trackId += 1
        }
        self.tracks = tracks
        self.indexByMKVNumber = indexByMKVNumber
    }

    /// Whether at least one track was carried into the fMP4.
    public var hasMedia: Bool { !tracks.isEmpty }

    /// The init segment (ftyp + moov), valid once the head is parsed.
    public func initSegment() -> Data {
        MP4Muxer.initSegment(tracks: tracks)
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
        /// Multiplier from MKV ticks to the track's timescale (video 16, audio 1).
        private let scale: Int64
        let mkvTrack: MKVTrack
        private var nextDecodeTime: Int64 = 0
        private var lastDelta: Int64?
        /// True once a negative decode-order PTS delta is seen (video with B-frames); such tracks
        /// need a constant frame duration for their DTS instead of PTS deltas.
        private var hasReorder: Bool?

        init(timescale: Int, scale: Int64, mkvTrack: MKVTrack) {
            self.timescale = timescale
            self.scale = scale
            self.mkvTrack = mkvTrack
        }

        private func defaultDurationTicks(info: MatroskaInfo) -> Int64? {
            guard let ns = mkvTrack.defaultDurationNs else { return nil }
            let scale = Int64(max(1, info.timestampScaleNs))
            return (Int64(ns) + scale / 2) / scale
        }

        func samples(from blocks: [MKVBlock], clusterTimestamp: UInt64, info: MatroskaInfo) throws -> [TransmuxSample] {
            var frames: [(pts: Int64, data: Data, isKeyframe: Bool)] = []
            for block in blocks {
                let expanded = MatroskaParser.expandLacing(block) ?? [block]
                for frame in expanded {
                    frames.append((Int64(clusterTimestamp) + frame.relativeTimestamp, frame.data, frame.isKeyframe))
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

            var result: [TransmuxSample] = []
            result.reserveCapacity(frames.count)
            for (index, frame) in frames.enumerated() {
                let duration: Int64
                if hasReorder == true && isVideo {
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
                    durationTicks: duration * scale,
                    decodeTimeTicks: nextDecodeTime * scale,
                    compositionOffsetTicks: (frame.pts - nextDecodeTime) * scale,
                    isKeyframe: isKeyframe
                ))
                nextDecodeTime += duration
            }
            return result
        }
    }
}
