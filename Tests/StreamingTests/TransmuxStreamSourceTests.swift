import Testing
import Foundation
import AVFoundation
import Streaming
import TorrentTestingSupport

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

    /// Remuxes the fixture fully in memory (the reference output).
    private func referenceRemux(_ data: Data) throws -> Data {
        let info = try MatroskaParser.parseHead(bytes: data)
        let remuxer = try MKVRemuxer(info: info)
        var out = remuxer.initSegment()
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
            let reference = try referenceRemux(data)
            #expect(virtual == reference, "\(name): virtual file != full remux")
        }
    }

    @Test func streamsSequentiallyAsBytesVerify() async throws {
        let data = try Fixtures.data(named: "mkv/h264-aac.mkv")
        let source = FakeMKVSource(data)
        // Verify the head + the first ~half; the rest comes later.
        let headEnd = min(200 * 1024, data.count)
        await source.verify(0..<headEnd)
        let transmux = TransmuxStreamSource(realSource: source, fileIndex: 0)

        let initLen = await transmux.fileLength(fileIndex: 0) // reports content length
        #expect(initLen > 0)

        // The init segment must be available immediately after the head verifies.
        let initAvailable = await transmux.availability(fileIndex: 0, offset: 0)
        #expect(initAvailable >= 1000, "init segment should be served from the head")

        // Read what's available now, then reveal the rest and confirm we can continue to EOF.
        var offset = 0
        var received = Data()
        var allRevealed = false
        while !allRevealed {
            let available = await transmux.availability(fileIndex: 0, offset: offset)
            if available == 0 {
                // Reveal more of the file (simulate pieces verifying during playback); once
                // everything is verified and nothing is available, the virtual EOF is reached.
                let next = min(offset * 2 + 256 * 1024, data.count)
                await source.verify(0..<next)
                allRevealed = next >= data.count
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            guard let chunk = await transmux.read(fileIndex: 0, offset: offset, length: available) else {
                await source.verify(0..<data.count)
                continue
            }
            received.append(chunk)
            offset += chunk.count
        }
        let reference = try referenceRemux(data)
        #expect(received == reference)
    }

    @Test func seekWithinDownloadedRegionIsExact() async throws {
        let data = try Fixtures.data(named: "mkv/h264-aac.mkv")
        let source = FakeMKVSource(data)
        await source.verify(0..<data.count)
        let transmux = TransmuxStreamSource(realSource: source, fileIndex: 0)

        let reference = try referenceRemux(data)
        // Seek into the middle of the virtual file and read a chunk; it must equal the
        // reference bytes at that offset.
        let target = reference.count / 2
        _ = await transmux.availability(fileIndex: 0, offset: target)
        if let chunk = await transmux.read(fileIndex: 0, offset: target, length: 4096) {
            let expected = reference.subdata(in: target..<min(target + 4096, reference.count))
            #expect(chunk == expected)
        } else {
            Issue.record("read at seek target returned nil")
        }
    }
}
