import Foundation
import Observation
import UIKit
import UserNotifications
import os.log

/// In-app surface for incoming APNs notifications.
///
/// Responsibilities:
///  - Register for remote notifications when the user is authenticated.
///  - Hold the most recent device token (hex) so it can be uploaded to the
///    backend once a push-registration endpoint lands.
///  - Receive UNUserNotificationCenter delegate callbacks and expose the
///    *foreground* arrivals as a `currentToast` for views to render.
///
/// The backend at `https://mail.middleseat.vc` does not have an APNs
/// register endpoint today (see README "Not yet implemented"). The
/// app-side machinery is wired up so that when the endpoint lands, only
/// `uploadTokenIfNeeded` needs to be implemented.
@Observable
@MainActor
final class PushCenter: NSObject {
    static let shared = PushCenter()

    /// Hex-encoded APNs device token. Cleared on logout.
    private(set) var deviceToken: String?

    /// Most recent foreground notification, surfaced as a non-blocking toast.
    /// Set to `nil` when the toast is dismissed.
    var currentToast: ToastPayload?

    /// Permission state. `.notDetermined` until the system answers.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    struct ToastPayload: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let body: String
        /// Optional thread id surfaced in the payload's userInfo so a future
        /// tap-to-open handler can route to the right ThreadView.
        let threadID: String?
    }

    private static let log = Logger(subsystem: "com.bmail", category: "PushCenter")

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Bootstrap

    /// Request the system push permission and, on success, ask iOS to
    /// register with APNs. Safe to call multiple times; UNUserNotificationCenter
    /// only prompts the first time.
    func requestAuthorizationAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { [weak self] granted, error in
            if let error {
                Self.log.error("APNs auth request failed: \(error, privacy: .public)")
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshAuthorizationStatus()
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }

    func refreshAuthorizationStatus() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        self.authorization = s.authorizationStatus
    }

    // MARK: - APNs token plumbing

    /// Called from the AppDelegate APNs callback.
    func didRegister(deviceToken raw: Data) {
        let hex = raw.map { String(format: "%02x", $0) }.joined()
        self.deviceToken = hex
        Self.log.info("APNs token registered (\(hex.count, privacy: .public) hex chars)")
        Task { await uploadTokenIfNeeded() }
    }

    func didFailToRegister(error: Error) {
        Self.log.error("APNs registration failed: \(error, privacy: .public)")
    }

    /// Placeholder for the eventual backend upload.
    ///
    /// Backend work is required first: there's no `/api/push/register`
    /// endpoint today (README, "Not yet implemented"). When that endpoint
    /// lands, fill this in with an `APIClient.shared.post(...)` call.
    private func uploadTokenIfNeeded() async {
        // No-op until the backend supports it. The token is kept in memory
        // and re-uploaded on next launch when the system delivers it again.
    }

    /// Clear in-memory state and tell iOS to forget about us. Called from
    /// `AppModel.logout()`.
    func unregister() {
        deviceToken = nil
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    // MARK: - Toast presentation

    func dismissToast() {
        currentToast = nil
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushCenter: UNUserNotificationCenterDelegate {
    /// Called when a push arrives while the app is in the foreground.
    ///
    /// We return `[]` to suppress the system banner — the in-app toast
    /// takes over so the surface the user is on isn't covered by a
    /// system-drawn banner that they can't dismiss without leaving
    /// their current task.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        let title = content.title.isEmpty ? "New message" : content.title
        let body = content.body
        let threadID = content.userInfo["thread_id"] as? String
        Task { @MainActor in
            PushCenter.shared.currentToast = ToastPayload(
                title: title,
                body: body,
                threadID: threadID
            )
        }
        completionHandler([])
    }

    /// Background tap-through. Not wired to navigation yet — when a tap
    /// lands we just publish a toast so the user can see what arrived.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let title = content.title.isEmpty ? "New message" : content.title
        let body = content.body
        let threadID = content.userInfo["thread_id"] as? String
        Task { @MainActor in
            PushCenter.shared.currentToast = ToastPayload(
                title: title,
                body: body,
                threadID: threadID
            )
        }
        completionHandler()
    }
}
