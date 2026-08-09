import Foundation
import TorrentCore

/// Shared mutable state for `TorrentSeekableInputStream`, kept in a separate `@unchecked Sendable`
/// class so a background feed task can be created without capturing the `InputStream` itself
/// (Swift 6's sending check rejects capturing `self` of an `InputStream` subclass, since the
/// base `Stream` type isn't Sendable). All access is guarded by `NSCondition`.
private final class TorrentStreamBuffer: @unchecked Sendable {
    let condition = NSCondition()
    private var buffer = Data()
    private var fileOffset: Int64 = 0
    private var fileLength: Int = -1
    private var status: Stream.Status = .notOpen
    private var closed = false
    private var error: Error?

    var streamStatus: Stream.Status {
        condition.lock()
        let value = status
        condition.unlock()
        return value
    }

    var streamError: Error? {
        condition.lock()
        let value = error
        condition.unlock()
        return value
    }

    var currentOffset: Int64 {
        condition.lock()
        let value = fileOffset
        condition.unlock()
        return value
    }

    var hasBytesAvailable: Bool {
        condition.lock()
        let available = !closed && fileOffset < Int64(fileLength >= 0 ? fileLength : .max) && status != .atEnd
        condition.unlock()
        return available
    }

    func open() {
        condition.lock()
        guard status == .notOpen else {
            condition.unlock()
            return
        }
        status = .open
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        status = .closed
        condition.broadcast()
        condition.unlock()
    }

    /// Seek to a byte offset. Returns false if out of range. Blocks briefly until the file
    /// length is known so the range can be validated (the feed task resolves it shortly after
    /// `open()`; reads already wait for the same state).
    func seek(to target: Int64) -> Bool {
        condition.lock()
        while fileLength < 0, !closed {
            condition.wait()
        }
        defer { condition.unlock() }
        guard !closed else { return false }
        let max = Int64(fileLength)
        guard target >= 0, target <= max else { return false }
        fileOffset = target
        buffer.removeAll(keepingCapacity: true)
        status = .open
        condition.broadcast()
        return true
    }

    /// Blocking read (libVLC's input thread). Returns bytes when verified data is available,
    /// 0 only at true EOF, and -1 when closed.
    func read(into destination: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard len > 0 else { return 0 }

        condition.lock()
        while !closed {
            if fileLength >= 0, !buffer.isEmpty { break }
            if fileLength >= 0, fileOffset >= Int64(fileLength) {
                status = .atEnd
                condition.unlock()
                return 0
            }
            condition.wait()
        }
        if closed {
            error = NSError(domain: "stupid-torrent.stream", code: -1, userInfo: [NSLocalizedDescriptionKey: "stream closed"])
            condition.unlock()
            return -1
        }
        let count = min(buffer.count, len)
        buffer.withUnsafeBytes { raw in
            destination.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: count)
        }
        buffer.removeFirst(count)
        fileOffset += Int64(count)
        condition.unlock()
        return count
    }

    // MARK: - Feed task (runs on a background Task; synchronous locked helpers below)

    /// Pulls verified bytes from the source into the buffer, prioritizing a lookahead window.
    func feed(source: any TorrentStreamSource, fileIndex: Int) async {
        let chunkSize = 256 * 1024
        let bufferCap = 2 * 1024 * 1024
        let lookahead = 2 * 1024 * 1024

        if fileLength < 0 {
            let length = await source.fileLength(fileIndex: fileIndex)
            updateFileLength(length)
        }

        while !Task.isCancelled {
            guard let state = currentLoopState() else { break }
            if state.closed { break }
            guard state.lengthKnown else { continue }
            // True EOF: the consumer has drained everything. Stay alive (sleeping) so a
            // backward seek can re-feed the buffer; only `close()` or cancellation ends the task.
            if state.fileOffset >= state.fileLength && state.buffered == 0 {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            if state.fetchOffset >= state.fileLength || state.buffered >= bufferCap {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }

            let end = min(state.fetchOffset + lookahead, state.fileLength)
            await source.prioritize(fileIndex: fileIndex, range: state.fetchOffset..<end)

            let available = await source.availability(fileIndex: fileIndex, offset: state.fetchOffset)
            guard available > 0 else {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            let length = min(available, chunkSize, bufferCap - state.buffered)
            guard length > 0, let data = await source.read(fileIndex: fileIndex, offset: state.fetchOffset, length: length) else {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }

            // If a seek happened (or the consumer drained) while we fetched, the fetch offset
            // no longer matches the buffer tail; discard the stale bytes and restart.
            if !appendIfStillCurrent(data, offset: state.fetchOffset) { break }
        }
    }

    private func updateFileLength(_ length: Int) {
        condition.lock()
        fileLength = length
        condition.broadcast()
        condition.unlock()
    }

    /// Returns the next un-buffered byte offset (the fetch cursor) plus current state.
    private func currentLoopState() -> (closed: Bool, fileOffset: Int, fetchOffset: Int, buffered: Int, lengthKnown: Bool, fileLength: Int)? {
        condition.lock()
        defer { condition.unlock() }
        let read = Int(fileOffset)
        let fetchOffset = read + buffer.count
        guard fileLength >= 0 else { return (closed, read, fetchOffset, buffer.count, false, 0) }
        return (closed, read, fetchOffset, buffer.count, true, fileLength)
    }

    private func appendIfStillCurrent(_ data: Data, offset: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return false }
        if Int(fileOffset) + buffer.count == offset {
            buffer.append(data)
            condition.broadcast()
        }
        return true
    }
}

/// An `NSInputStream` that presents a torrent file's verified bytes to libVLC's callback
/// bridge (`VLCMedia(initWithStream:)`). libVLC reads synchronously and treats a `read`
/// returning 0 as end-of-stream, so reads **block** until the requested bytes are verified
/// by the torrent engine — never returning 0 prematurely. Seeks are supported via the
/// `NSStreamFileCurrentOffsetKey` property and re-prioritize the target range as a picker jump.
///
/// The actual byte plumbing lives in `TorrentStreamBuffer`; this class is a thin facade over the
/// `NSStream` API so the background feed task never captures an `InputStream` (`Stream` isn't
/// Sendable, and Swift 6's sending check rejects capturing such `self` in a `Task`).
public final class TorrentSeekableInputStream: InputStream, @unchecked Sendable {
    private let source: any TorrentStreamSource
    private let fileIndex: Int
    private let buffer = TorrentStreamBuffer()
    private var feedTask: Task<Void, Never>?

    public init(source: any TorrentStreamSource, fileIndex: Int) {
        self.source = source
        self.fileIndex = fileIndex
        super.init()
    }

    // MARK: - NSStream overrides

    public override func open() {
        buffer.open()
        if feedTask == nil {
            let source = self.source
            let buffer = self.buffer
            let fileIndex = self.fileIndex
            feedTask = Task { [buffer, source, fileIndex] in await buffer.feed(source: source, fileIndex: fileIndex) }
        }
    }

    public override func close() {
        buffer.close()
        feedTask?.cancel()
        feedTask = nil
    }

    public override var streamStatus: Stream.Status { buffer.streamStatus }

    public override var streamError: Error? { buffer.streamError }

    public override func property(forKey key: Stream.PropertyKey) -> Any? {
        if key == .fileCurrentOffsetKey {
            return buffer.currentOffset
        }
        return nil
    }

    public override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool {
        guard key == .fileCurrentOffsetKey else { return false }
        guard let raw = property as? NSNumber else { return false }
        return buffer.seek(to: raw.int64Value)
    }

    public override var hasBytesAvailable: Bool { buffer.hasBytesAvailable }

    public override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length: UnsafeMutablePointer<Int>) -> Bool {
        // Return false: the buffer may be reallocated concurrently by the feed task, so handing
        // out a pointer to internal storage is unsafe. libVLC's callback bridge only uses read().
        false
    }

    // MARK: - InputStream

    public override func read(_ destination: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        buffer.read(into: destination, maxLength: len)
    }
}
