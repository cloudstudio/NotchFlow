import Foundation
import UserNotifications
import os

/// Native macOS notifications for the moments you might miss when the
/// island is out of sight: attention requests and failures.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let logger = Logger(subsystem: "app.notchflow", category: "notifier")
    /// UNUserNotificationCenter aborts the process when the executable runs
    /// outside an .app bundle (the dev harness), so it is only touched when
    /// packaged.
    private let available = Bundle.main.bundleURL.pathExtension == "app"

    /// Called with the tapped notification's sessionId so the app can bring that
    /// terminal forward.
    var onTap: ((String) -> Void)?

    override init() {
        super.init()
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { granted, _ in
            if !granted {
                Self.logger.info("notification permission not granted")
            }
        }
    }

    func post(title: String, body: String, sessionId: String? = nil) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let sessionId { content.userInfo = ["sessionId": sessionId] }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    /// Tapping the banner brings that agent's terminal forward.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let sessionId = response.notification.request.content.userInfo["sessionId"] as? String {
            onTap?(sessionId)
        }
        completionHandler()
    }
}
