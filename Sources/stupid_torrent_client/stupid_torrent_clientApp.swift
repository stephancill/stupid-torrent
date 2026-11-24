import StupidClientCore
import SwiftUI

@main
struct stupid_torrent_clientApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        startTorrentEngine()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
