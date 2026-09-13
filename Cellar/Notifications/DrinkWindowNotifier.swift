import Foundation
import UserNotifications

/// Local notifications for a bottle's drink window. Two per bottle, both
/// future-dated (never noisy about the past):
///   • "ready"     — Jan 1 of `drinkFrom` (enters its window this year)
///   • "last call" — Jan 1 of `drinkTo + 1` (now past peak, drink soon)
///
/// Identifiers are derived from the bottle id so rescheduling replaces cleanly.
enum DrinkWindowNotifier {
    private static let prefix = "drinkwindow."

    @discardableResult
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }

    /// Full rebuild: drop our pending requests and reschedule from scratch.
    static func rescheduleAll(for wines: [Wine]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        for wine in wines { schedule(for: wine, using: center) }
    }

    /// Add (or refresh) reminders for one wine's in-stock bottles.
    static func schedule(for wine: Wine, using center: UNUserNotificationCenter = .current()) {
        let title = wine.displayTitle
        for bottle in wine.inStockBottles {
            if let from = bottle.drinkFrom {
                addReminder(id: prefix + bottle.id.uuidString + ".ready",
                            year: from,
                            title: "🍷 Ready to drink",
                            body: "\(title) enters its drink window this year.",
                            center: center)
            }
            if let to = bottle.drinkTo {
                addReminder(id: prefix + bottle.id.uuidString + ".last",
                            year: to + 1,
                            title: "🍷 Last call",
                            body: "\(title) is past its peak window — drink soon.",
                            center: center)
            }
        }
    }

    static func cancel(bottleID: UUID, center: UNUserNotificationCenter = .current()) {
        center.removePendingNotificationRequests(withIdentifiers: [
            prefix + bottleID.uuidString + ".ready",
            prefix + bottleID.uuidString + ".last"
        ])
    }

    // MARK: - Private

    private static func addReminder(id: String, year: Int, title: String, body: String,
                                    center: UNUserNotificationCenter) {
        var comps = DateComponents()
        comps.year = year
        comps.month = 1
        comps.day = 1
        comps.hour = 9
        guard let fireDate = Calendar.current.date(from: comps), fireDate > .now else {
            return // never schedule in the past
        }
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour], from: fireDate),
            repeats: false)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
