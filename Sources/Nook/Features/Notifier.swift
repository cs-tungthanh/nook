import Foundation
import UserNotifications

enum Notifier {
    static func post(title: String, body: String, identifier: String = UUID().uuidString, category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category = category {
            content.categoryIdentifier = category
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("Nook: failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    /// Shows the macOS prompt the first time a feature that notifies is used.
    /// Until then, and after a "Don't Allow", posts are silently dropped.
    /// `completion` runs on the main thread once the prompt is answered, or right
    /// away when it was answered before.
    static func requestAuthorizationIfNeeded(_ completion: (() -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                DispatchQueue.main.async { completion?() }
                return
            }
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error = error {
                    NSLog("Nook: notification authorization failed: \(error.localizedDescription)")
                } else if !granted {
                    NSLog("Nook: notifications not allowed")
                }
                DispatchQueue.main.async { completion?() }
            }
        }
    }

    /// Whether posts can be shown: false only once the user said no. "Not asked
    /// yet" counts as allowed, since the prompt comes on first use.
    /// Calls back on the main thread.
    static func checkAllowed(_ completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus != .denied
            DispatchQueue.main.async { completion(allowed) }
        }
    }

    static func registerPomodoroCategory() {
        let actions = [
            UNNotificationAction(identifier: Constants.Pomodoro.Action.start, title: "Start break", options: []),
            UNNotificationAction(identifier: Constants.Pomodoro.Action.snooze, title: "Snooze \(Constants.Pomodoro.snoozeMinutes)m", options: []),
            UNNotificationAction(identifier: Constants.Pomodoro.Action.skip, title: "Skip", options: [])
        ]
        let category = UNNotificationCategory(identifier: Constants.Pomodoro.categoryID, actions: actions, intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
