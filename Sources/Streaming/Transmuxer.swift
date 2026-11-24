import Foundation

enum TransmuxError: LocalizedError, CustomStringConvertible {
    case missingAudioConfig(trackNumber: UInt64)
    case invalidSampleRate(trackNumber: UInt64)

    var description: String {
        switch self {
        case .missingAudioConfig(let trackNumber): "no valid Dolby syncframe to configure track \(trackNumber)"
        case .invalidSampleRate(let trackNumber): "invalid sampling frequency on track \(trackNumber)"
        }
    }

    var errorDescription: String? { "This file's audio can't be converted for playback (\(description))." }
}

struct MKVRemuxer {
    let tracks: [TransmuxTrack]
    let selectedTrackNumbers: [UInt64]
    private let initialStates: [UInt64: TrackState]
    private var states: [UInt64: TrackState]
    private var sequence = 0

    init(info: MatroskaInfo, audioSyncframes: [UInt64: Data] = [:]) throws {
        var tracks: [TransmuxTrack] = []
        var states: [UInt64: TrackState] = [:]
        let selected = Self.selectedTracks(info: info)
        for (index, mkvTrack) in selected.enumerated() {
            guard let codec = Self.codec(for: mkvTrack) else { continue }
            let trackId = index + 1
            let sampleRate = mkvTrack.samplingFrequency ?? 48000
            guard sampleRate.isFinite, (1...768_000).contains(sampleRate) else {
                throw TransmuxError.invalidSampleRate(trackNumber: mkvTrack.number)
            }
            let timescale = mkvTrack.isVideo ? 16000 : Int(sampleRate.rounded())
            var audioConfig: Data?
            if codec == .eac3 || codec == .ac3 {
                guard let syncframe = mkvTrack.codecPrivate ?? audioSyncframes[mkvTrack.number],
                      let config = codec == .eac3
                          ? DolbyAudioConfig.dec3(syncframe: syncframe)
                          : DolbyAudioConfig.dac3(syncframe: syncframe) else {
                    throw TransmuxError.missingAudioConfig(trackNumber: mkvTrack.number)
                }
                audioConfig = config
            }
            tracks.append(TransmuxTrack(
                trackId: trackId,
                timescale: timescale,
                codec: codec,
                codecPrivate: mkvTrack.codecPrivate,
                audioConfig: audioConfig,
                width: mkvTrack.videoWidth.map { Int(clamping: $0) },
                height: mkvTrack.videoHeight.map { Int(clamping: $0) },
                channels: Int(clamping: mkvTrack.channels ?? 2),
                sampleRate: sampleRate,
                bitDepth: Int(clamping: mkvTrack.bitDepth ?? 16),
                language: mkvTrack.language
            ))
            states[mkvTrack.number] = TrackState(
                trackId: trackId,
                timescale: timescale,
                timestampScaleNs: info.timestampScaleNs,
                defaultDurationNs: mkvTrack.defaultDurationNs,
                isVideo: mkvTrack.isVideo,
                codec: codec
            )
        }
        self.tracks = tracks
        selectedTrackNumbers = selected.map(\.number)
        initialStates = states
        self.states = states
    }

    static func dolbyTrackNumbersNeedingSyncframe(info: MatroskaInfo) -> [UInt64] {
        selectedTracks(info: info)
            .filter { $0.codecPrivate == nil && ($0.codecID == "A_EAC3" || $0.codecID == "A_AC3") }
            .map(\.number)
    }

    func initSegment() -> Data {
        MP4Muxer.initSegment(tracks: tracks)
    }

    func starting(atTimelineTicks ticks: Int64) -> MKVRemuxer {
        var remuxer = self
        remuxer.sequence = 0
        remuxer.states = initialStates.mapValues { state in
            var state = state
            state.nextDecodeTime = Int64(
                (Double(ticks) * Double(state.timestampScaleNs) * Double(state.timescale) / 1e9).rounded()
            )
            return state
        }
        return remuxer
    }

    mutating func consume(_ cluster: MKVCluster) throws -> Data? {
        var blocksByTrack: [UInt64: [MKVBlock]] = [:]
        for block in cluster.blocks {
            blocksByTrack[block.trackNumber, default: []].append(block)
        }
        var fragments: [TransmuxFragment] = []
        for trackNumber in blocksByTrack.keys.sorted() {
            guard var state = states[trackNumber], let blocks = blocksByTrack[trackNumber] else { continue }
            let samples = try state.samples(from: blocks, clusterTimestamp: cluster.timestamp)
            states[trackNumber] = state
            if !samples.isEmpty {
                fragments.append(TransmuxFragment(trackId: state.trackId, samples: samples))
            }
        }
        guard !fragments.isEmpty else { return nil }
        sequence += 1
        return MP4Muxer.fragment(sequenceNumber: sequence, tracks: tracks, fragments: fragments)
    }

    static func selectedTracks(info: MatroskaInfo) -> [MKVTrack] {
        let supported = info.tracks.filter { $0.isEnabled && codec(for: $0) != nil }
        return [UInt64(1), UInt64(2)].compactMap { trackType in
            supported.first { $0.trackType == trackType && $0.isDefault }
                ?? supported.first { $0.trackType == trackType }
        }
    }

    private static func codec(for track: MKVTrack) -> TransmuxCodec? {
        switch (track.trackType, track.codecID) {
        case (1, "V_MPEG4/ISO/AVC"): .h264
        case (1, "V_MPEGH/ISO/HEVC"): .hevc
        case (2, "A_AAC"): .aac
        case (2, "A_EAC3"): .eac3
        case (2, "A_AC3"): .ac3
        case (2, "A_ALAC"): .alac
        default: nil
        }
    }

    private struct TrackState {
        let trackId: Int
        let timescale: Int
        let timestampScaleNs: UInt64
        let defaultDurationNs: UInt64?
        let isVideo: Bool
        let codec: TransmuxCodec
        var nextDecodeTime: Int64 = 0
        var lastDelta: Int64?
        var hasReorder: Bool?
        var hasStarted = false

        private var defaultDurationTicks: Int64? {
            defaultDurationNs.map { Int64((Double($0) * Double(timescale) / 1e9).rounded()) }
        }

        private func bitstreamDuration(of frame: Data) -> Int64? {
            switch codec {
            case .aac: 1024
            case .ac3, .eac3: DolbyAudioConfig.sampleCount(frame: frame).map(Int64.init)
            case .h264, .hevc, .alac: nil
            }
        }

        private func presentationTicks(_ mkvTicks: Int64) -> Int64 {
            Int64((Double(mkvTicks) * Double(timestampScaleNs) * Double(timescale) / 1e9).rounded())
        }

        mutating func samples(from blocks: [MKVBlock], clusterTimestamp: UInt64) throws -> [TransmuxSample] {
            let lacingFrameTicks = defaultDurationNs.map { Double($0) / Double(timestampScaleNs) } ?? 0
            var frames: [(pts: Int64, data: Data, isKeyframe: Bool)] = []
            for block in blocks {
                for frame in try MatroskaParser.frames(of: block, frameDurationTicks: lacingFrameTicks) {
                    frames.append((
                        pts: presentationTicks(Int64(clusterTimestamp) + frame.relativeTimestamp),
                        data: frame.data,
                        isKeyframe: frame.isKeyframe
                    ))
                }
            }
            guard !frames.isEmpty else { return [] }

            if hasReorder == nil {
                hasReorder = frames.indices.dropFirst().contains { frames[$0].pts < frames[$0 - 1].pts }
            }
            if !isVideo, !hasStarted {
                let start = max(0, frames[0].pts)
                if let frameTicks = bitstreamDuration(of: frames[0].data), frameTicks > 0 {
                    nextDecodeTime = (start + frameTicks / 2) / frameTicks * frameTicks
                } else {
                    nextDecodeTime = start
                }
            }
            hasStarted = true
            let defaultDuration = defaultDurationTicks
            var result: [TransmuxSample] = []
            result.reserveCapacity(frames.count)
            for (index, frame) in frames.enumerated() {
                let duration: Int64
                if let bitstreamDuration = bitstreamDuration(of: frame.data) {
                    duration = bitstreamDuration
                } else if hasReorder == true && isVideo {
                    duration = defaultDuration ?? lastDelta ?? 0
                } else if index + 1 < frames.count {
                    let delta = frames[index + 1].pts - frame.pts
                    duration = delta > 0 ? delta : defaultDuration ?? 0
                } else {
                    duration = lastDelta ?? defaultDuration ?? 0
                }
                if duration > 0 { lastDelta = duration }
                result.append(TransmuxSample(
                    data: frame.data,
                    durationTicks: duration,
                    decodeTimeTicks: nextDecodeTime,
                    compositionOffsetTicks: isVideo ? frame.pts - nextDecodeTime : 0,
                    isKeyframe: isVideo ? frame.isKeyframe : true
                ))
                nextDecodeTime += duration
            }
            return result
        }
    }
}
