#if os(iOS)
import UIKit

/// App-wide supported-orientation mask. The plist advertises portrait + landscape so the
/// full-screen player can rotate, but the app otherwise stays portrait: `OrientationLock`
/// flips the mask to allow landscape only while the player is presented. A `forced`
/// orientation pins the screen regardless of the device's physical rotation (e.g. when the
/// user's Rotation Lock is enabled), which the player uses to always present landscape.
@MainActor
enum OrientationLock {
    static var playerPresented = false
    static var forced: UIInterfaceOrientation?

    static func mask() -> UIInterfaceOrientationMask {
        if let forced {
            switch forced {
            case .landscapeLeft: return .landscapeLeft
            case .landscapeRight: return .landscapeRight
            default: return .portrait
            }
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .all
        }
        return playerPresented ? .allButUpsideDown : .portrait
    }

    /// Pin the screen to `orientation` regardless of the device's rotation. Uses the modern
    /// `UIWindowScene.requestGeometryUpdate`, which works with Rotation Lock enabled and on
    /// the simulator (the interface genuinely rotates), independent of free rotation.
    static func force(_ orientation: UIInterfaceOrientation) {
        forced = orientation
        requestGeometry(mask())
    }

    /// Release a pinned orientation so the screen follows the device again.
    static func clearForce() {
        forced = nil
        requestGeometry(mask())
    }

    private static func requestGeometry(_ orientationMask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientationMask)) { error in
            // A rejected request (e.g. an activity view controller active) is not fatal: the
            // mask above still gates what the app supports once the device rotates.
            NSLog("OrientationLock.requestGeometryUpdate failed: \(error)")
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated {
            OrientationLock.mask()
        }
    }
}
#endif
