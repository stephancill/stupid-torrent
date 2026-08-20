import SwiftUI
import TorrentCore

@main
struct stupid_torrent_clientApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
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
