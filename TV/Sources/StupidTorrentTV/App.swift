import StupidClientCore
import SwiftUI

@main
struct StupidTorrentTVApp: App {
    init() {
        startTorrentEngine()
    }

    var body: some Scene {
        WindowGroup {
            TVContentView()
        }
    }
}
