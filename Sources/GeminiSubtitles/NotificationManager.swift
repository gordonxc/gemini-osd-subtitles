import Foundation
import UserNotifications

/// Thin wrapper around `UNUserNotificationCenter` used for *critical* errors
/// only (invalid API key, permission revoked, reconnect exhausted). Reconnects
/// and transient network blips are intentionally silent — see plan §Error handling.
final class NotificationManager {

    static let shared = NotificationManager()

    private var requestedAuthorization = false

    func requestAuthorizationIfNeeded() {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted {
                NSLog("[NotificationManager] user declined notifications")
            }
        }
    }

    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
