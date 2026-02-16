import Foundation
import UserNotifications

enum NotificationScheduler {
    static let reminderIdentifier = "daily_weight_reminder"

    static func updateDailyReminder(enabled: Bool, hour: Int, minute: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderIdentifier])

        guard enabled else { return }

        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }

            var date = DateComponents()
            date.hour = hour
            date.minute = minute

            let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
            let content = UNMutableNotificationContent()
            content.title = "Log your weight"
            content.body = "Add today's weigh-in and quick health notes."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: reminderIdentifier,
                content: content,
                trigger: trigger
            )

            center.add(request)
        }
    }
}
