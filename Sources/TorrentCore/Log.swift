import Foundation

public enum TorrentLog {
    nonisolated(unsafe) public static var verbose = false
    /// Optional file that also receives every emitted line, for devices whose unified log is
    /// hard to reach (the Apple TV app pulls it from its container). Capped at `maxFileBytes`.
    nonisolated(unsafe) private static var fileHandle: FileHandle?
    nonisolated(unsafe) private static var fileBytes = 0
    private static let maxFileBytes = 20_000_000

    /// Starts a fresh log file at `url` (replacing any previous one).
    public static func logToFile(at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        fileBytes = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var windowStart = ContinuousClock.now
    nonisolated(unsafe) private static var windowCount = 0
    /// Caps per-second emission so engine hot loops (per-refill "requesting N blocks", streaming
    /// serve logs) cannot flood the process the way the pre-2026-08-20 stderr bursts did.
    private static let maxPerSecond = 200

    public static func log(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        let text = message()
        lock.lock()
        let now = ContinuousClock.now
        if now - windowStart >= .seconds(1) {
            windowStart = now
            windowCount = 0
        }
        guard windowCount < maxPerSecond else {
            lock.unlock()
            return
        }
        windowCount += 1
        if let fileHandle, fileBytes < maxFileBytes {
            let line = Data("\(Date().ISO8601Format(.iso8601.time(includingFractionalSeconds: true))) \(text)\n".utf8)
            fileHandle.write(line)
            fileBytes += line.count
        }
        lock.unlock()
        FileHandle.standardError.write(Data((text + "\n").utf8))
        // Unified logging (Foundation-only, preserves TorrentCore's dependency light
        // footprint): captured on device/simulator and retrievable via log show/Console,
        // unlike raw stderr which is lost when a process is killed.
        NSLog("torrent: %@", text)
    }
}