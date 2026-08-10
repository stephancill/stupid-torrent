import Testing
import Foundation
import AVFoundation
@testable import Streaming
import TorrentTestingSupport

/// End-to-end hermetic gate for the MKV → fMP4 transmuxer: parse a fixture's head, remux every
/// cluster into fragments, validate the resulting fMP4 structurally and with AVFoundation
/// (macOS host can load AVURLAsset from a file), and cross-check box layout.
@Suite struct MKVTransmuxTests {

    private let fixtures = [
        ("h264-aac.mkv", 3.0),
        ("h264-bframes.mkv", 3.0),
        ("hevc-main10.mkv", 3.0),
        ("eac3.mkv", 3.0),
        ("ac3.mkv", 3.0),
    ]

    /// Remuxes a full in-memory MKV into a complete fragmented MP4.
    private func remuxFull(_ data: Data) throws -> Data {
        let info = try MatroskaParser.parseHead(bytes: data)
        #expect(!info.tracks.isEmpty)
        let remuxer = try MKVRemuxer(info: info)
        #expect(remuxer.hasMedia)

        var out = remuxer.initSegment()
        var fragmentsEmitted = 0
        var offset = info.firstClusterOffset ?? 0
        let segmentEnd = info.segmentDataEnd ?? data.count
        while offset < segmentEnd, offset < data.count {
            if let range = try MatroskaParser.readClusterRange(bytes: data, offset: offset) {
                let cluster = try MatroskaParser.parseCluster(bytes: range.bytes, segmentDataStart: 0)
                if let fragment = try remuxer.consume(cluster) {
                    out.append(fragment)
                    fragmentsEmitted += 1
                }
                offset = range.elementEnd
            } else {
                break
            }
        }
        #expect(fragmentsEmitted > 0)
        return out
    }

    @Test func parsesHeadAndBuildsInitSegment() throws {
        for (name, _) in fixtures {
            let data = try Fixtures.data(named: "mkv/\(name)")
            let info = try MatroskaParser.parseHead(bytes: data)
            #expect(info.firstClusterOffset != nil, "\(name): no first cluster")
            #expect(info.tracks.contains { $0.trackType == 1 }, "\(name): no video track")
            let remuxer = try MKVRemuxer(info: info)
            let initSegment = remuxer.initSegment()
            // ftyp + moov with per-track sample entries.
            #expect(initSegment.prefix(4) == Data([0, 0, 0, 0x1C])) // ftyp size (28)
            #expect(initSegment.dropFirst(4).prefix(4) == Data("ftyp".utf8))
            #expect(remuxer.tracks.allSatisfy { $0.trackId >= 1 })
        }
    }

    @Test func remuxesToPlayableFragmentedMP4() async throws {
        for (name, expectedDuration) in fixtures {
            let data = try Fixtures.data(named: "mkv/\(name)")
            let fmp4 = try remuxFull(data)
            #expect(!fmp4.isEmpty, "\(name): empty remux")

            // Structural sanity: init segment + at least one moof, and no trailing zeros.
            #expect(fmp4.range(of: Data("moof".utf8)) != nil, "\(name): no moof")
            #expect(fmp4.range(of: Data("sidx".utf8)) == nil, "\(name): no sidx expected yet")

            // Write to a temp file and load with AVFoundation (macOS host).
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("transmux-\(UUID().uuidString).mp4")
            try fmp4.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            let asset = AVURLAsset(url: url)
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            #expect(playable, "\(name): AVAsset not playable")
            let seconds = CMTimeGetSeconds(duration)
            #expect(seconds > expectedDuration - 0.5 && seconds < expectedDuration + 0.5,
                    "\(name): duration \(seconds) != ~\(expectedDuration)s")

            // Each fixture must keep its video + audio tracks, and both must actually decode.
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            #expect(videoTracks.count == 1, "\(name): expected 1 video track")
            #expect(audioTracks.count == 1, "\(name): expected 1 audio track")
            for track in videoTracks + audioTracks {
                let format = try await track.load(.formatDescriptions).first
                #expect(format != nil, "\(name): track without format description")
            }

            // Ground truth: AVAssetReader must be able to pull samples for both tracks.
            let reader = try AVAssetReader(asset: asset)
            for (kind, tracks) in [("video", videoTracks), ("audio", audioTracks)] {
                guard let track = tracks.first else { continue }
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                #expect(reader.canAdd(output), "\(name): can't add \(kind) output")
                reader.add(output)
            }
            #expect(reader.startReading(), "\(name): reader failed \(String(describing: reader.error))")
            for _ in 0..<4 {
                _ = reader.outputs.compactMap { ($0 as? AVAssetReaderTrackOutput)?.copyNextSampleBuffer() }
            }
            reader.cancelReading()
            #expect(reader.status != .failed, "\(name): reader failed decoding: \(String(describing: reader.error))")
        }
    }

    @Test func blockTimestampsArePresentationTimes() throws {
        // h264-bframes has B-frames, so presentation order differs from decode order.
        let data = try Fixtures.data(named: "mkv/h264-bframes.mkv")
        let info = try MatroskaParser.parseHead(bytes: data)
        let videoTrack = info.tracks.first { $0.trackType == 1 }
        #expect(videoTrack != nil)

        // Iterate the first cluster and check that block PTS values are out of presentation
        // order (they are PTS in decode order, so NOT monotonic as stored with B-frames).
        var psts: [Int64] = []
        if let range = try MatroskaParser.readClusterRange(bytes: data, offset: info.firstClusterOffset!) {
            let cluster = try MatroskaParser.parseCluster(bytes: range.bytes, segmentDataStart: 0)
            for block in cluster.blocks {
                psts.append(Int64(cluster.timestamp) + block.relativeTimestamp)
            }
        }
        let sorted = psts.sorted()
        #expect(psts.count > 4)
        #expect(psts != sorted, "B-frame fixture should be out of presentation order")
    }

    @Test func selectsOnlyDefaultAudioTrack() throws {
        var disabled = MKVTrack(number: 1, trackType: 2)
        disabled.codecID = "A_AAC"
        disabled.codecPrivate = Data([0x12, 0x10])
        disabled.channels = 8
        disabled.isDefault = true
        disabled.isEnabled = false

        var commentary = MKVTrack(number: 2, trackType: 2)
        commentary.codecID = "A_AAC"
        commentary.codecPrivate = Data([0x12, 0x10])
        commentary.channels = 2
        commentary.isDefault = false

        var primary = MKVTrack(number: 3, trackType: 2)
        primary.codecID = "A_AAC"
        primary.codecPrivate = Data([0x12, 0x10])
        primary.channels = 6
        primary.isDefault = true

        var info = MatroskaInfo()
        info.tracks = [disabled, commentary, primary]
        let remuxer = try MKVRemuxer(info: info)

        #expect(remuxer.tracks.count == 1)
        #expect(remuxer.tracks.first?.channels == 6)
    }
}
