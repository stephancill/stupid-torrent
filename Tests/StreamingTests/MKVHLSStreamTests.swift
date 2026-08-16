import Testing
import Foundation
import AVFoundation
@testable import Streaming
import TorrentCore
import TorrentTestingSupport

@Suite struct MKVHLSStreamTests {
    @Test func preparesCompleteVODIndexFromSparseHeadAndCues() async throws {
        let data = try Fixtures.data(named: "mkv/long30.mkv")
        let source = FakeMKVSource(data)
        let cuesRange = try cueRange(data: data)
        await source.verify(0..<300 * 1024)
        await source.verify(cuesRange)
        let stream = MKVHLSStream(source: source, fileIndex: 0)

        try await stream.prepare()
        let segments = try await stream.segments()
        let playlist = String(decoding: try await stream.playlistData(), as: UTF8.self)

        #expect(segments.count == 4)
        #expect(segments.first?.startTimeTicks == 0)
        #expect(playlist.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(playlist.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        #expect(playlist.components(separatedBy: "#EXT-X-DISCONTINUITY").count - 1 == 3)
        #expect(playlist.contains("#EXT-X-ENDLIST"))
    }

    @Test func generatesFarSegmentWithoutReadingInterveningMedia() async throws {
        let data = try Fixtures.data(named: "mkv/long30.mkv")
        let source = FakeMKVSource(data)
        let cuesRange = try cueRange(data: data)
        await source.verify(0..<300 * 1024)
        await source.verify(cuesRange)
        let stream = MKVHLSStream(source: source, fileIndex: 0)
        try await stream.prepare()
        let segments = try await stream.segments()
        let target = segments[2]
        let skipped = segments[1].sourceRange
        await source.verify(target.sourceRange)

        let media = try await stream.mediaSegment(id: target.id)
        let reads = await source.readRanges

        #expect(!media.isEmpty)
        #expect(reads.contains(target.sourceRange))
        #expect(!reads.contains { range in
            range.overlaps(skipped) && !range.overlaps(0..<300 * 1024) && !range.overlaps(cuesRange)
        })
        let decodeTimes = tfdtValues(data: media)
        #expect(decodeTimes.count >= 2)
        #expect(decodeTimes.prefix(2).allSatisfy { $0 == 0 })
    }

    @Test @MainActor func avFoundationLoadsGlobalTimelineAndSeeks() async throws {
        let data = try Fixtures.data(named: "mkv/long30.mkv")
        let source = FakeMKVSource(data)
        await source.verify(0..<data.count)
        let stream = MKVHLSStream(source: source, fileIndex: 0)
        try await stream.prepare()
        let server = try HLSLoopbackServer(stream: stream)
        server.start()
        defer { server.stop() }

        let asset = AVURLAsset(url: server.playlistURL)
        let duration = try await asset.load(.duration)
        let playable = try await asset.load(.isPlayable)

        #expect(playable)
        #expect(abs(CMTimeGetSeconds(duration) - 30.023) < 0.1)

        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        let itemID = ObjectIdentifier(try #require(player.currentItem))
        await player.seek(
            to: CMTime(seconds: 20, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        #expect(abs(CMTimeGetSeconds(player.currentTime()) - 20) < 0.2)
        player.play()
        #expect(await advancePlaying(player, beyond: 20.5, within: 3))
        player.pause()

        await player.seek(
            to: CMTime(seconds: 8.5, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        #expect(ObjectIdentifier(try #require(player.currentItem)) == itemID)
        #expect(abs(CMTimeGetSeconds(player.currentTime()) - 8.5) < 0.2)
        player.play()
        #expect(await advancePlaying(player, beyond: 9, within: 3))
        player.pause()
    }

    /// Waits (up to `within` wall-clock seconds) for playback to advance past `beyond`. A fixed
    /// sleep is load-sensitive: AVPlayer's segment-fetch + decoder startup eats into it under a
    /// busy test host, so assert on reaching the target rather than on a wall-clock threshold.
    private func advancePlaying(_ player: AVPlayer, beyond: Double, within: Double) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(within)
        while ContinuousClock.now < deadline {
            if CMTimeGetSeconds(player.currentTime()) > beyond { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test func loopbackServerSupportsHeadAndByteRanges() async throws {
        let data = try Fixtures.data(named: "mkv/long30.mkv")
        let source = FakeMKVSource(data)
        await source.verify(0..<data.count)
        let stream = MKVHLSStream(source: source, fileIndex: 0)
        try await stream.prepare()
        let server = try HLSLoopbackServer(stream: stream)
        server.start()
        defer { server.stop() }

        var headRequest = URLRequest(url: server.playlistURL)
        headRequest.httpMethod = "HEAD"
        let (_, headResponse) = try await URLSession.shared.data(for: headRequest)
        let headHTTP = try #require(headResponse as? HTTPURLResponse)
        let expectedLength = try await stream.playlistData().count
        #expect(headHTTP.statusCode == 200)
        #expect(headHTTP.value(forHTTPHeaderField: "Content-Length") == String(expectedLength))

        var rangeRequest = URLRequest(url: server.playlistURL)
        rangeRequest.setValue("bytes=0-15", forHTTPHeaderField: "Range")
        let (rangeData, rangeResponse) = try await URLSession.shared.data(for: rangeRequest)
        let rangeHTTP = try #require(rangeResponse as? HTTPURLResponse)
        let expectedPrefix = Data(try await stream.playlistData().prefix(16))
        #expect(rangeHTTP.statusCode == 206)
        #expect(rangeData == expectedPrefix)
    }

    @Test func preparationCancellationStopsWaitingForCues() async throws {
        let data = try Fixtures.data(named: "mkv/long30.mkv")
        let source = FakeMKVSource(data)
        await source.verify(0..<300 * 1024)
        let info = try MatroskaParser.parseHead(bytes: data)
        let cuesOffset = try #require(info.cuesOffset)
        let stream = MKVHLSStream(source: source, fileIndex: 0)
        let preparation = Task { try await stream.prepare() }

        for _ in 0..<20 {
            if await source.prioritizeRanges.contains(where: { $0.contains(cuesOffset) }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        preparation.cancel()
        do {
            try await preparation.value
            Issue.record("canceled HLS preparation completed successfully")
        } catch is CancellationError {
        } catch {
            Issue.record("unexpected cancellation error: \(error)")
        }
    }

    @Test func cuesLessPartialFileCannotPrepareHLS() async throws {
        var data = try Fixtures.data(named: "mkv/long30.mkv")
        let info = try MatroskaParser.parseHead(bytes: data)
        let cueID = Data([0x1C, 0x53, 0xBB, 0x6B])
        let headEnd = try #require(info.firstClusterOffset)
        let seekIDRange = try #require(data[..<headEnd].range(of: cueID))
        data[seekIDRange.lowerBound] = 0x1D
        let source = FakeMKVSource(data)
        await source.verify(0..<300 * 1024)

        do {
            try await MKVHLSStream(source: source, fileIndex: 0).prepare()
            Issue.record("Cues-less partial MKV prepared HLS")
        } catch MKVHLSStreamError.invalidCues {
        } catch {
            Issue.record("unexpected Cues-less preparation error: \(error)")
        }
    }

    private func cueRange(data: Data) throws -> Range<Int> {
        let info = try MatroskaParser.parseHead(bytes: data)
        let offset = try #require(info.cuesOffset)
        let header = try #require(EBML.readHeader(data, offset: offset))
        let size = try #require(header.size)
        return offset..<offset + EBML.headerLength(header) + Int(size)
    }

    private func tfdtValues(data: Data) -> [UInt64] {
        let marker = Data("tfdt".utf8)
        var values: [UInt64] = []
        var offset = 0
        while let range = data.range(of: marker, in: offset..<data.count) {
            let valueOffset = range.upperBound + 4
            guard valueOffset + 8 <= data.count else { break }
            var value: UInt64 = 0
            for byte in data[valueOffset..<valueOffset + 8] {
                value = (value << 8) | UInt64(byte)
            }
            values.append(value)
            offset = valueOffset + 8
        }
        return values
    }
}
