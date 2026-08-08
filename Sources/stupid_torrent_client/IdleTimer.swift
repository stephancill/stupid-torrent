#if os(iOS)
import UIKit
#endif
import TorrentCore

/// Controls `UIApplication.isIdleTimerDisabled`: keeping the screen from auto-locking keeps the
/// app foregrounded, and an auto-lock would background + suspend the app — killing the DHT node
/// and any active downloads (the engine only runs while foregrounded). Follows Apple's guidance of
/// disabling the idle timer only while it's actually needed: we hold it while anything is actively
/// downloading or resolving, and re-enable it otherwise.
@MainActor
enum IdleTimer {
    static func update(isDownloading: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = isDownloading
        TorrentLog.log("idle timer \(isDownloading ? "disabled" : "enabled") (auto-lock \(isDownloading ? "off" : "on"))")
        #endif
    }
}
