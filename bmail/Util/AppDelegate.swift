import UIKit

/// Minimal UIKit AppDelegate, wired in via `UIApplicationDelegateAdaptor`
/// in `bmailApp`. Its only job today is funnelling APNs registration
/// callbacks into `PushCenter`.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushCenter.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        Task { @MainActor in
            PushCenter.shared.didFailToRegister(error: error)
        }
    }
}
