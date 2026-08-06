import SwiftUI
import TorrentCore

@main
struct stupid_torrent_clientApp: App {
    init() {
        TorrentLog.verbose = true
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
