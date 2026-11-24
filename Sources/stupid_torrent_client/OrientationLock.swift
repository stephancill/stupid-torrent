#if os(iOS)
import UIKit

@MainActor
enum OrientationLock {
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
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    let sceneNow = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
                    sceneNow?.requestGeometryUpdate(.iOS(interfaceOrientations: orientationMask)) { _ in }
                }
            }
        }
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
