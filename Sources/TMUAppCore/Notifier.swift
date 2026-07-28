import Foundation
import UserNotifications

/// Threshold notifications.
///
/// Whether to fire is `AlertPolicy`'s decision — once per threshold per window, re-arming
/// when the value falls. This only phrases it.
public enum Notifier {

    public static func post(_ alert: InstanceReadingResult.Alert) {
        let content = UNMutableNotificationContent()
        content.title =
            alert.value >= 100
            ? "\(alert.account): \(alert.metric.displayName) exhausted"
            : "\(alert.account): \(alert.metric.displayName) at \(Int(alert.value))%"

        // Name the alternative in the notification itself. An alert that only reports a
        // problem makes the reader go and find the answer; one that carries it is actionable
        // from the lock screen.
        if let target = alert.recommendation, target != alert.account {
            content.body = "\(target) has more headroom."
        }
        // Sound only when there is nothing left. A chime at 80% for each of several accounts
        // teaches people to turn notifications off, and then the 100% one never arrives.
        content.sound = alert.value >= 100 ? .default : nil

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "\(alert.account).\(alert.metric.code).\(Int(alert.value))",
                content: content, trigger: nil))
    }

    public static func requestPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
