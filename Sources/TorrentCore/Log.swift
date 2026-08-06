import Foundation

public enum TorrentLog {
    nonisolated(unsafe) public static var verbose = false

    public static func log(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        FileHandle.standardError.write(Data((message() + "\n").utf8))
    }
}
