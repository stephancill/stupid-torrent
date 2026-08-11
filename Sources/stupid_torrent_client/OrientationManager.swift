#if os(iOS)
import UIKit

/// App-wide supported-orientation mask. The plist advertises portrait + landscape so the
/// full-screen player can rotate, but the app otherwise stays portrait: `OrientationLock`
/// flips the mask to allow landscape only while the player is presented.
@MainActor
enum OrientationLock {
    static var playerPresented = false

    static func mask() -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .all
        }
        return playerPresented ? .allButUpsideDown : .portrait
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
