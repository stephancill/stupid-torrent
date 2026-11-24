import Foundation
import TorrentCore

public func startTorrentEngine() {
    #if DEBUG
    TorrentLog.verbose = true
    #if os(tvOS)
    TorrentLog.logToFile(
        at: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("torrent.log")
    )
    #endif
    #endif
    DHTNode.warmUp()
}
