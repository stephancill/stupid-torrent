import SwiftUI
import TorrentCore

@main
struct stupid_torrent_clientApp: App {
    init() {
        TorrentLog.verbose = true
        // Warm the DHT node's routing table in the background so the first magnet resolve doesn't
        // pay a cold bootstrap inline (the node also starts accumulating its live peer store).
        DHTNode.warmUp()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
