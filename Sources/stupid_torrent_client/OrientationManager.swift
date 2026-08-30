#if os(iOS)
import UIKit

/// App-wide supported-orientation mask. The plist advertises portrait + landscape so the
/// full-screen player can lock landscape, but the app otherwise stays portrait: while the
/// player is presented the mask pins landscape; on dismissal it returns to portrait.
@MainActor
enum OrientationLock {
    /// `true` only while the full-screen player is on screen. Switching it triggers a geometry
    /// request so the interface actually rotates (works with Rotation Lock enabled).
    static var playerPresented = false {
        didSet { rotate(to: playerPresented ? .landscapeRight : .portrait) }
    }

    static func mask() -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .all
        }
        return playerPresented ? .landscape : .portrait
    }

    private static func rotate(to orientation: UIInterfaceOrientation) {
        let orientationMask = mask()
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientationMask)) { [orientationMask] error in
                // A rejected request (e.g. AVPlayer teardown while the player dismisses) can
                // leave the UI stuck in the old orientation. Retry once shortly after.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    let sceneNow = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
                    sceneNow?.requestGeometryUpdate(.iOS(interfaceOrientations: orientationMask)) { _ in }
                }
            }
        }
        // Legacy rotation triggers that many in-market apps rely on to force the interface to
        // follow even when the geometry request is rejected because a presented view controller
        // only claims one orientation. Both log a deprecation/unsupported notice but still work.
        UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
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
