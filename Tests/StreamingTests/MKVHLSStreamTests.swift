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
        #expect(!playlist.contains("#EXT-X-DISCONTINUITY"))
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
        let info = try MatroskaParser.parseHead(bytes: data)
        let videoStart = UInt64((Double(target.startTimeTicks) * Double(info.timestampScaleNs) * 16000 / 1e9).rounded())
        #expect(decodeTimes.count >= 2)
        #expect(decodeTimes.first == videoStart)
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
        player.isMuted = true
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
        let headEnd = try #require(info.clustersStart)
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

    @Test @MainActor func completeCuelessFilePlaysThroughSession() async throws {
        let data = try cuelessWithoutDuration(try Fixtures.data(named: "mkv/long30.mkv"))
        let source = FakeMKVSource(data)
        await source.verify(0..<data.count)

        let stream = MKVHLSStream(source: source, fileIndex: 0)
        let segments = try await stream.segments()
        #expect(segments.count > 1)
        #expect(segments.first?.startTimeTicks == 0)
        let totalSeconds = segments.reduce(0) { $0 + $1.durationTicks } / 1000
        #expect(abs(totalSeconds - 30.0) < 0.1)

        let session = TorrentStreamSession(source: source, fileIndex: 0, fileName: "long30.mkv", cacheKey: nil)
        defer { session.stop() }
        let player = try await session.preparePlayer()
        player.isMuted = true
        let item = try #require(player.currentItem)
        let duration = try await item.asset.load(.duration)
        #expect(abs(CMTimeGetSeconds(duration) - 30.0) < 0.1)

        await player.seek(
            to: CMTime(seconds: 20, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        #expect(abs(CMTimeGetSeconds(player.currentTime()) - 20) < 0.2)
        player.play()
        #expect(await advancePlaying(player, beyond: 20.5, within: 3))
        player.pause()
    }

    @Test @MainActor func partialCuelessFileFailsToPreparePlayer() async throws {
        let data = try cuelessWithoutDuration(try Fixtures.data(named: "mkv/long30.mkv"))
        let source = FakeMKVSource(data)
        await source.verify(0..<300 * 1024)
        let session = TorrentStreamSession(source: source, fileIndex: 0, fileName: "long30.mkv", cacheKey: nil)
        defer { session.stop() }

        let error = await #expect(throws: MKVHLSStreamError.invalidCues) {
            _ = try await session.preparePlayer()
        }
        #expect(error?.localizedDescription.contains("once the download finishes") == true)
    }

    @Test func dolbyConfigReadsOnlyTheStartOfTheFirstSegment() async throws {
        let data = try Fixtures.data(named: "mkv/eac3-long.mkv")
        let source = FakeMKVSource(data)
        await source.verify(0..<data.count)
        let stream = MKVHLSStream(source: source, fileIndex: 0)
        let first = try #require(try await stream.segments().first)
        #expect(first.sourceRange.count > 512 * 1024)

        try await stream.prepare()

        let firstSegmentReads = await source.readRanges.filter { $0.lowerBound == first.sourceRange.lowerBound }
        #expect(!firstSegmentReads.isEmpty)
        #expect(firstSegmentReads.allSatisfy { $0.count <= 256 * 1024 })
    }

    @Test @MainActor func eac3SurroundPlaysThroughSession() async throws {
        let data = try Fixtures.data(named: "mkv/eac3-long.mkv")
        let source = FakeMKVSource(data)
        await source.verify(0..<data.count)
        let session = TorrentStreamSession(source: source, fileIndex: 0, fileName: "eac3-long.mkv", cacheKey: nil)
        defer { session.stop() }
        let player = try await session.preparePlayer()
        player.isMuted = true
        let item = try #require(player.currentItem)
        let tracks = try await item.asset.load(.tracks)
        #expect(tracks.contains { $0.mediaType == .audio } || item.status != .failed)
        player.play()
        #expect(await advancePlaying(player, beyond: 2, within: 6))
        #expect(item.status == .readyToPlay)
        let audioTracks = item.tracks.compactMap(\.assetTrack).filter { $0.mediaType == .audio }
        #expect(!audioTracks.isEmpty)
        player.pause()
    }

    @Test func segmentsKeepAudioMuxedAfterTheNextKeyframe() async throws {
        let data = try Fixtures.data(named: "mkv/eac3-long.mkv")
        let info = try MatroskaParser.parseHead(bytes: data)
        let audioTrack = try #require(info.tracks.first { $0.isAudio })
        let clustersStart = try #require(info.clustersStart)
        let clustersEnd = info.cuesOffset.flatMap { $0 > clustersStart ? $0 : nil } ?? data.count
        let fileAudioFrames = try MatroskaParser.clusters(in: data, range: clustersStart..<clustersEnd)
            .flatMap(\.blocks)
            .filter { $0.trackNumber == audioTrack.number }
            .count
        let source = FakeMKVSource(data)
        await source.verify(0..<data.count)
        let stream = MKVHLSStream(source: source, fileIndex: 0)
        let segments = try await stream.segments()
        #expect(segments.count > 1)

        var segmentAudioFrames = 0
        for segment in segments {
            segmentAudioFrames += sampleCount(data: try await stream.mediaSegment(id: segment.id), trackID: 2)
        }

        #expect(segmentAudioFrames == fileAudioFrames)
    }

    @Test func concurrentSegmentRequestsShareOneGeneration() async throws {
        let data = try Fixtures.data(named: "mkv/long30.mkv")
        let source = FakeMKVSource(data)
        await source.verify(0..<data.count)
        let stream = MKVHLSStream(source: source, fileIndex: 0)
        let target = try await stream.segments()[1]
        let readsBefore = await source.readRanges.filter { $0 == target.sourceRange }.count

        async let first = stream.mediaSegment(id: target.id)
        async let second = stream.mediaSegment(id: target.id)
        let (a, b) = try await (first, second)
        let cached = try await stream.mediaSegment(id: target.id)
        let readsAfter = await source.readRanges.filter { $0 == target.sourceRange }.count

        #expect(a == b)
        #expect(a == cached)
        #expect(readsAfter - readsBefore == 1)
    }

    private func cuelessWithoutDuration(_ original: Data) throws -> Data {
        var data = original
        let info = try MatroskaParser.parseHead(bytes: data)
        let headEnd = try #require(info.clustersStart)
        let cuesOffset = try #require(info.cuesOffset)
        let seekID = try #require(data[..<headEnd].range(of: Data([0x1C, 0x53, 0xBB, 0x6B])))
        data[seekID.lowerBound] = 0x1D
        #expect(data[cuesOffset] == 0x1C)
        data[cuesOffset] = 0x1D
        let durationID = try #require(childOffset(data: data, id: 0x4489, inChildWithID: 0x1549A966))
        data[durationID + 1] = 0x88
        let mutated = try MatroskaParser.parseHead(bytes: data)
        #expect(mutated.cuesOffset == nil)
        #expect(mutated.durationTicks == nil)
        return data
    }

    private func childOffset(data: Data, id: UInt64, inChildWithID parentID: UInt64) -> Int? {
        guard let info = try? MatroskaParser.parseHead(bytes: data), let start = info.segmentDataStart,
              let end = info.clustersStart else { return nil }
        var offset = start
        while offset < end, let header = EBML.readHeader(in: data, offset: offset), let size = header.size {
            if header.id == parentID {
                var child = offset + header.length
                while child < offset + header.length + Int(size),
                      let childHeader = EBML.readHeader(in: data, offset: child), let childSize = childHeader.size {
                    if childHeader.id == id { return child }
                    child += childHeader.length + Int(childSize)
                }
                return nil
            }
            offset += header.length + Int(size)
        }
        return nil
    }

    private func cueRange(data: Data) throws -> Range<Int> {
        let info = try MatroskaParser.parseHead(bytes: data)
        let offset = try #require(info.cuesOffset)
        let header = try #require(EBML.readHeader(in: data, offset: offset))
        let size = try #require(header.size)
        return offset..<offset + header.length + Int(size)
    }

    private func sampleCount(data: Data, trackID: UInt32) -> Int {
        var total = 0
        for moof in boxes(in: data, range: 0..<data.count) where moof.type == "moof" {
            for traf in boxes(in: data, range: moof.payload) where traf.type == "traf" {
                let children = boxes(in: data, range: traf.payload)
                guard let tfhd = children.first(where: { $0.type == "tfhd" }),
                      uint32(data, at: tfhd.payload.lowerBound + 4) == trackID else { continue }
                for trun in children where trun.type == "trun" {
                    total += Int(uint32(data, at: trun.payload.lowerBound + 4))
                }
            }
        }
        return total
    }

    private func boxes(in data: Data, range: Range<Int>) -> [(type: String, payload: Range<Int>)] {
        var result: [(type: String, payload: Range<Int>)] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            let size = Int(uint32(data, at: offset))
            guard size >= 8, offset + size <= range.upperBound else { break }
            let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
            result.append((type, offset + 8..<offset + size))
            offset += size
        }
        return result
    }

    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
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
