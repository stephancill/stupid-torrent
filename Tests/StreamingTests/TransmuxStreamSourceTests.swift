import Testing
import Foundation
import AVFoundation
@testable import Streaming
import TorrentTestingSupport

private final class DeclaredDurationPlayerItem: AVPlayerItem, @unchecked Sendable {
    private let declaredDuration: CMTime

    init(asset: AVAsset, declaredDuration: CMTime) {
        self.declaredDuration = declaredDuration
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var duration: CMTime {
        declaredDuration
    }
}

/// Controllable `TorrentStreamSource` whose verified ranges are revealed incrementally.
actor FakeMKVSource: TorrentStreamSource {
    let data: Data
    private var verified = Set<Int>()
    private(set) var prioritizeRanges: [Range<Int>] = []

    init(_ data: Data) {
        self.data = data
    }

    func fileLength(fileIndex: Int) async -> Int { data.count }

    func availability(fileIndex: Int, offset: Int) async -> Int {
        guard offset >= 0, offset < data.count else { return 0 }
        var position = offset
        while position < data.count, verified.contains(position) { position += 1 }
        return position - offset
    }

    func read(fileIndex: Int, offset: Int, length: Int) async -> Data? {
        guard offset >= 0, offset + length <= data.count,
              (offset..<(offset + length)).allSatisfy({ verified.contains($0) }) else { return nil }
        return data.subdata(in: offset..<(offset + length))
    }

    func prioritize(fileIndex: Int, range: Range<Int>) async {
        prioritizeRanges.append(range)
    }
    func reachesEOF(fileIndex: Int, offset: Int) async -> Bool {
        offset >= data.count
    }


    func verify(_ range: Range<Int>) {
        for byte in range { verified.insert(byte) }
    }
}

@Suite struct TransmuxStreamSourceTests {
    private let fixtureNames = ["h264-aac.mkv", "h264-bframes.mkv", "eac3.mkv"]

    /// Reads the entire virtual file through the source, with the whole MKV verified.
    private func readVirtualFile(_ source: TransmuxStreamSource, fileIndex: Int = 0) async -> Data? {
        let length = await source.fileLength(fileIndex: fileIndex)
        var out = Data()
        var offset = 0
        while offset < length {
            let available = await source.availability(fileIndex: fileIndex, offset: offset)
            guard available > 0 else { return out }
            guard let chunk = await source.read(fileIndex: fileIndex, offset: offset, length: available) else { return out }
            out.append(chunk)
            offset += chunk.count
        }
        return out
    }

    /// Remuxes the fixture fully in memory (the reference output). `includeSidx` matches the
    /// transmuxer's complete-file init (which carries a sidx).
    private func referenceRemux(_ data: Data, includeSidx: Bool) throws -> Data {
        let info = try MatroskaParser.parseHead(bytes: data)
        let remuxer = try MKVRemuxer(info: info)
        var out = includeSidx && (try remuxer.sidxReferences(mkvBytes: data)) != nil
            ? remuxer.initSegment(withSidx: try remuxer.sidxReferences(mkvBytes: data)!)
            : remuxer.initSegment()
        var offset = info.firstClusterOffset ?? 0
        while offset < data.count {
            if let range = try MatroskaParser.readClusterRange(bytes: data, offset: offset) {
                let cluster = try MatroskaParser.parseCluster(bytes: range.bytes, segmentDataStart: 0)
                if let fragment = try remuxer.consume(cluster) { out.append(fragment) }
                offset = range.elementEnd
            } else { break }
        }
        return out
    }

    @Test func virtualFileMatchesFullRemux() async throws {
        for name in fixtureNames {
            let data = try Fixtures.data(named: "mkv/\(name)")
            let source = FakeMKVSource(data)
            await source.verify(0..<data.count)
            let transmux = TransmuxStreamSource(realSource: source, fileIndex: 0)

            let virtual = await readVirtualFile(transmux) ?? Data()
            let reference = try referenceRemux(data, includeSidx: true)
            #expect(virtual == reference, "\(name): virtual file != full remux (with sidx)")
        }
    }

    @Test func streamsSequentiallyAsBytesVerify() async throws {
        // long30.mkv is big enough that the initial reveal is partial, exercising the streaming
        // (sequential, no sidx) path: the head parses but the file isn't complete yet.
        let data = try Fixtures.data(named: "mkv/long30.mkv")
        let source = FakeMKVSource(data)
        // Verify the head (256 KB head window) + a bit more; the rest comes later.
        await source.verify(0..<300 * 1024)
        let transmux = TransmuxStreamSource(realSource: source, fileIndex: 0)

        let initLen = await transmux.fileLength(fileIndex: 0) // reports content length
        #expect(initLen > 0)

        // The init segment must be available immediately after the head verifies.
        let initAvailable = await transmux.availability(fileIndex: 0, offset: 0)
        #expect(initAvailable >= 1000, "init segment should be served from the head")

        // Read what's available now, then reveal the rest and confirm we can continue to EOF.
        let virtualLength = await transmux.fileLength(fileIndex: 0)
        var offset = 0
        var received = Data()
        var allRevealed = false
        while offset < virtualLength {
            let available = await transmux.availability(fileIndex: 0, offset: offset)
            if available == 0 {
                if !allRevealed {
                    // Reveal more of the file (simulate pieces verifying during playback).
                    let next = min(offset * 2 + 256 * 1024, data.count)
                    await source.verify(0..<next)
                    allRevealed = next >= data.count
                    try? await Task.sleep(for: .milliseconds(20))
                } else {
                    break // all verified and nothing more available → virtual EOF
                }
                continue
            }
            guard let chunk = await transmux.read(fileIndex: 0, offset: offset, length: available) else {
                await source.verify(0..<data.count)
                continue
            }
            received.append(chunk)
            offset += chunk.count
        }
        let reference = try referenceRemux(data, includeSidx: false)
        #expect(received.count == reference.count, "received \(received.count) vs reference \(reference.count)")
        if received.count == reference.count {
            #expect(received == reference)
        }
    }

    @Test func farSeekServesOnceTargetVerifies() async throws {
        // long30 is big enough to seek beyond an initial partial verify; the target's bytes come
        // later, and the virtual read must then return the fragment at the requested offset.
        let data = try Fixtures.data(named: "mkv/long30.mkv")
        let reference = try referenceRemux(data, includeSidx: false)
        let source = FakeMKVSource(data)
        // Only the head + a bit verified initially.
        await source.verify(0..<300 * 1024)
        let transmux = TransmuxStreamSource(realSource: source, fileIndex: 0)

        // A seek far beyond the downloaded frontier has no bytes yet.
        let seekTarget = Int(Double(reference.count) * 0.8)
        #expect(await transmux.availability(fileIndex: 0, offset: seekTarget) == 0,
                "far seek target should not be available before its bytes verify")

        // Once the rest verifies, the target fragment must serve the exact reference bytes.
        await source.verify(0..<data.count)
        // Let the transmuxer catch up (sequential generation walks to the target).
        var available = 0
        for _ in 0..<20 {
            available = await transmux.availability(fileIndex: 0, offset: seekTarget)
            if available > 0 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(available > 0, "far seek target should become available after verification")
        if let chunk = await transmux.read(fileIndex: 0, offset: seekTarget, length: 4096) {
            let expected = reference.subdata(in: seekTarget..<min(seekTarget + 4096, reference.count))
            #expect(chunk == expected, "served bytes must match the reference at the seek target")
        } else {
            Issue.record("read at far seek target returned nil")
        }
    }

    @Test @MainActor func partialDurationProbeFinishesAtCurrentFrontier() async throws {
        let data = try Fixtures.data(named: "mkv/long30.mkv")
        let source = FakeMKVSource(data)
        await source.verify(0..<300 * 1024)
        let transmux = TransmuxStreamSource(realSource: source, fileIndex: 0)
        let delegate = TorrentResourceLoaderDelegate(
            source: transmux,
            fileIndex: 0,
            contentType: "public.mpeg-4",
            finishesAllToEndAtFrontier: true
        )
        let asset = delegate.makeAsset()
        let clock = ContinuousClock()
        let started = clock.now
        let duration = try await asset.load(.duration)
        let declaredDuration = try MatroskaParser.parseHead(bytes: data).durationSeconds ?? 0
        let item = DeclaredDurationPlayerItem(
            asset: asset,
            declaredDuration: CMTime(seconds: declaredDuration, preferredTimescale: 600)
        )

        #expect(CMTimeGetSeconds(duration) > 0)
        #expect(started.duration(to: clock.now) < .seconds(2))
        #expect(abs(CMTimeGetSeconds(item.duration) - declaredDuration) < 0.01)
    }

    @Test func precomputedLayoutIgnoresDroppedTracks() throws {
        let data = try Fixtures.data(named: "mkv/long30.mkv")
        let info = try MatroskaParser.parseHead(bytes: data)
        let remuxer = try MKVRemuxer(info: info)
        let keptTrack = info.tracks.first(where: \.isTransmuxable)!.number
        let kept = MatroskaParser.MKVClusterTrackLayout(
            sampleCount: 2,
            mdatSize: 200,
            firstPTS: 0,
            lastPTS: 40,
            lastDelta: 40
        )
        let dropped = MatroskaParser.MKVClusterTrackLayout(
            sampleCount: 10,
            mdatSize: 1_000,
            firstPTS: 0,
            lastPTS: 90,
            lastDelta: 10
        )
        let mixed = MatroskaParser.MKVClusterLayout(
            timestamp: 0,
            tracks: [keptTrack: kept, 999: dropped]
        )
        let droppedOnly = MatroskaParser.MKVClusterLayout(timestamp: 0, tracks: [999: dropped])

        #expect(remuxer.fragmentSizeForKeptTracks(mixed) == 8 + 16 + 64 + 32 + 8 + 200)
        #expect(remuxer.fragmentSizeForKeptTracks(droppedOnly) == nil)
    }

}
