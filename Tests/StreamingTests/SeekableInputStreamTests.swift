import Testing
import Foundation
import TorrentCore
import Streaming

/// Controllable `TorrentStreamSource` whose verified ranges are revealed incrementally,
/// letting tests exercise the "wait for verified bytes" behavior deterministically.
actor FakeStreamSource: TorrentStreamSource {
    let data: Data
    private var verified = Set<Int>()
    private(set) var prioritizeRanges: [Range<Int>] = []

    init(bytes: [UInt8]) {
        self.data = Data(bytes)
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

    func prioritizeSnapshot() async -> [Range<Int>] { prioritizeRanges }
}

@Suite struct TorrentSeekableInputStreamTests {
    private let bytes: [UInt8] = Array(0..<128).map { UInt8($0 % 251) }

    /// Reads `length` bytes from the stream (blocking), returning what `read` returns.
    private func asyncRead(_ stream: TorrentSeekableInputStream, length: Int) async -> Int {
        await Task.detached(priority: .userInitiated) {
            var buf = [UInt8](repeating: 0, count: length)
            return stream.read(&buf, maxLength: length)
        }.value
    }

    @Test func readsVerifiedBytesSequentially() async {
        let source = FakeStreamSource(bytes: bytes)
        await source.verify(0..<bytes.count)
        let stream = TorrentSeekableInputStream(source: source, fileIndex: 0)
        stream.open()
        defer { stream.close() }

        var out = [UInt8](repeating: 0, count: 32)
        let n1 = stream.read(&out, maxLength: 32)
        #expect(n1 == 32)
        #expect(Array(out) == Array(bytes[0..<32]))
        let n2 = stream.read(&out, maxLength: 32)
        #expect(n2 == 32)
        #expect(Array(out) == Array(bytes[32..<64]))
    }

    @Test func returnsZeroOnlyAtEndOfFile() async {
        let source = FakeStreamSource(bytes: bytes)
        await source.verify(0..<bytes.count)
        let stream = TorrentSeekableInputStream(source: source, fileIndex: 0)
        stream.open()
        defer { stream.close() }

        var total = 0
        var out = [UInt8](repeating: 0, count: 512)
        // The feed task fills the buffer incrementally, so drain in whatever chunk sizes arrive.
        while total < bytes.count {
            let n = stream.read(&out, maxLength: 512)
            #expect(n > 0)
            total += n
        }
        #expect(total == bytes.count)
        let atEnd = stream.read(&out, maxLength: 512)
        #expect(atEnd == 0)
        #expect(stream.streamStatus == .atEnd)
    }

    @Test func blocksUntilBytesVerify() async {
        let source = FakeStreamSource(bytes: bytes)
        let stream = TorrentSeekableInputStream(source: source, fileIndex: 0)
        stream.open()

        // Nothing verified yet: a read must block, not return 0 (which would fake EOF).
        // We prove it's blocked by closing the stream — a blocked read then returns -1,
        // whereas a premature-EOF read would already have returned 0.
        let readTask = Task { await self.asyncRead(stream, length: 16) }
        try? await Task.sleep(for: .milliseconds(300))
        stream.close()
        #expect(await readTask.value == -1)

        // A fresh stream, verifying the first 16 bytes: the read returns them.
        let stream2 = TorrentSeekableInputStream(source: source, fileIndex: 0)
        stream2.open()
        await source.verify(0..<16)
        let readTask2 = Task { await self.asyncRead(stream2, length: 16) }
        let n = await readTask2.value
        stream2.close()
        #expect(n == 16)
    }

    @Test func seekMovesCursorAndDropsBuffer() async {
        let source = FakeStreamSource(bytes: bytes)
        await source.verify(0..<bytes.count)
        let stream = TorrentSeekableInputStream(source: source, fileIndex: 0)
        stream.open()
        defer { stream.close() }

        // Read a few bytes so the buffer is ahead of the logical cursor.
        var out = [UInt8](repeating: 0, count: 8)
        _ = stream.read(&out, maxLength: 8)

        let didSeek = stream.setProperty(NSNumber(value: 64), forKey: .fileCurrentOffsetKey)
        #expect(didSeek)
        #expect((stream.property(forKey: .fileCurrentOffsetKey) as? NSNumber)?.intValue == 64)

        var seeked = [UInt8](repeating: 0, count: 8)
        let n = stream.read(&seeked, maxLength: 8)
        #expect(n == 8)
        #expect(Array(seeked) == Array(bytes[64..<72]))
    }

    @Test func rejectsSeekPastEnd() async {
        let source = FakeStreamSource(bytes: bytes)
        await source.verify(0..<bytes.count)
        let stream = TorrentSeekableInputStream(source: source, fileIndex: 0)
        stream.open()
        defer { stream.close() }

        let didSeek = stream.setProperty(NSNumber(value: bytes.count + 10), forKey: .fileCurrentOffsetKey)
        #expect(!didSeek)
        #expect((stream.property(forKey: .fileCurrentOffsetKey) as? NSNumber)?.intValue == 0)
    }

    @Test func closeUnblocksPendingRead() async {
        let source = FakeStreamSource(bytes: bytes)
        let stream = TorrentSeekableInputStream(source: source, fileIndex: 0)
        stream.open()

        let readTask = Task { await self.asyncRead(stream, length: 16) }
        try? await Task.sleep(for: .milliseconds(300))
        stream.close()
        let result = await readTask.value
        #expect(result == -1)
        #expect(stream.streamStatus == .closed)
    }

    @Test func prioritizesLookaheadWindow() async {
        let source = FakeStreamSource(bytes: bytes)
        let stream = TorrentSeekableInputStream(source: source, fileIndex: 0)
        stream.open()
        defer { stream.close() }

        try? await Task.sleep(for: .milliseconds(400))
        let ranges = await source.prioritizeSnapshot()
        #expect(!ranges.isEmpty)
        #expect(ranges.first!.lowerBound == 0)
        #expect(ranges.first!.upperBound <= bytes.count)
    }

    @Test func seekPrioritizesNewOffset() async {
        let source = FakeStreamSource(bytes: bytes)
        await source.verify(0..<bytes.count)
        let stream = TorrentSeekableInputStream(source: source, fileIndex: 0)
        stream.open()
        defer { stream.close() }

        _ = stream.setProperty(NSNumber(value: 80), forKey: .fileCurrentOffsetKey)
        try? await Task.sleep(for: .milliseconds(400))
        let ranges = await source.prioritizeSnapshot()
        #expect(ranges.contains { $0.lowerBound == 80 })
    }
}
