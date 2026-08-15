import Foundation

/// One alarm that already exists on a remote service, described well enough for a human to pick it
/// out of a list.
///
/// Needed because both remote legs move an alarm you already have, and an account can hold several:
/// two Pods, a weekday alarm and a weekend one, or both sides of one bed. Picking the first the
/// server happens to list is a coin flip, and a coin flip that silently moves the wrong alarm is the
/// worst kind of bug this app can have.
///
/// Neither service labels its alarms with a device or a room, so these are identified the only way
/// the data allows: by time and by days.
struct RemoteAlarmChoice: Identifiable, Equatable, Sendable {
    let id: String
    let time: WallClockTime?
    let weekdays: Set<Locale.Weekday>
    let isEnabled: Bool
    /// Anything extra the service gives us, such as Whoop's wake mode.
    let detail: String?

    var timeLabel: String { time?.hhmm ?? "unknown time" }

    var daysLabel: String {
        if weekdays.isEmpty { return "no days set" }
        if weekdays == Locale.Weekday.everyDay { return "every day" }
        if weekdays == Locale.Weekday.weekdaysOnly { return "weekdays" }
        return Locale.Weekday.displayOrder
            .filter { weekdays.contains($0) }
            .map(\.shortLabel)
            .joined(separator: " ")
    }

    /// One line, for a picker row and for the confirmation afterwards.
    var summary: String {
        var parts = ["\(timeLabel), \(daysLabel)"]
        if let detail, !detail.isEmpty { parts.append(detail) }
        if !isEnabled { parts.append("currently off") }
        return parts.joined(separator: " · ")
    }
}

/// Remembers which alarm the user chose, per service.
///
/// Not a secret, so `UserDefaults` is the right home. Storing it matters more than it looks: without
/// it, a change in the order the server returns alarms would silently move a different one, and the
/// alarm we moved last night would be left sitting at our time.
enum RemoteAlarmSelection {
    private static func key(_ device: DeviceID) -> String {
        "OneAlarm.selectedRemoteAlarm.\(device.rawValue)"
    }

    static func selected(for device: DeviceID) -> String? {
        UserDefaults.standard.string(forKey: key(device))
    }

    static func select(_ id: String?, for device: DeviceID) {
        if let id {
            UserDefaults.standard.set(id, forKey: key(device))
        } else {
            UserDefaults.standard.removeObject(forKey: key(device))
        }
    }

    /// The chosen alarm if it is still there, otherwise nothing.
    ///
    /// Deliberately does **not** fall back to the first alarm. If the one you picked has been
    /// deleted, the honest outcome is to ask again rather than to quietly start moving a different
    /// one.
    static func resolve(_ choices: [RemoteAlarmChoice], for device: DeviceID) -> RemoteAlarmChoice? {
        if let id = selected(for: device), let match = choices.first(where: { $0.id == id }) {
            return match
        }
        // Only safe to assume when there is nothing to be ambiguous about.
        return choices.count == 1 ? choices.first : nil
    }
}
