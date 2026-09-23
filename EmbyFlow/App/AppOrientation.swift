import SwiftUI
import UIKit

/// 播放时锁横屏、退出恢复竖屏。
///
/// iOS 14/15 没有 `setNeedsUpdateOfSupportedInterfaceOrientations`，
/// 只能用 AppDelegate 的方向掩码 + 强制转屏（自娱自乐不上架，这里允许用这招）。
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}

enum OrientationController {
    /// 进入播放器
    static func enterLandscape() {
        apply(mask: .landscape, orientation: .landscapeRight)
    }

    /// 退出播放器
    static func exitToPortrait() {
        apply(mask: .portrait, orientation: .portrait)
    }

    private static func apply(mask: UIInterfaceOrientationMask, orientation: UIInterfaceOrientation) {
        AppDelegate.orientationLock = mask

        if #available(iOS 16.0, *) {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            scenes.first?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        } else {
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            UINavigationController.attemptRotationToDeviceOrientation()
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}
