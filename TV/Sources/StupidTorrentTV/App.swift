import SwiftUI
import TorrentCore

@main
struct StupidTorrentTVApp: App {
    init() {
        #if DEBUG
        TorrentLog.verbose = true
        // Pull with `stupid-app device container --pull Library/Caches/torrent.log`.
        TorrentLog.logToFile(
            at: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("torrent.log"))
        #endif
        DHTNode.warmUp()
    }

    var body: some Scene {
        WindowGroup {
            TVContentView()
        }
    }
}
