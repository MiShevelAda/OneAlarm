import Foundation

/// One alarm that already exists on a remote service, described well enough for a human to pick it
/// out of a list.
///
/// Needed because both remote legs move an alarm you already have, and an account can hold several:
/// two Pods, a weekday alarm and a weekend one, or both sides of one bed. Picking the first the
/// server happens to list is a coin flip, and a coin flip that silently moves the wrong alarm is the
/// worst kind of bug this app can have.
///
/// Neither service puts a bed or a room **on the alarm object**, so a row is identified by time and
/// days. That is a fact about the object, not about the service: Eight Sleep does name its Pods, in
/// `/v1/household/users/{id}/summary`, and the account's current bed and side are stated once above
/// the list. An earlier version of this comment said the services do not label alarms at all, which
/// was inferred from an absent field and was wrong.
struct RemoteAlarmChoice: Identifiable, Equatable, Sendable {
    let id: String
    let time: WallClockTime?
    let weekdays: Set<Locale.Weekday>
    let isEnabled: Bool
    /// Anything extra the service gives us, such as Whoop's wake mode.
    let detail: String?
    /// The bed, pod or side this alarm belongs to, when the service names one.
    ///
    /// Alex, 2026-08-16: identify the pod by name, and group the picker by it. An earlier comment
    /// on this file asserted that neither service labels its alarms with a device or a room. That
    /// was inferred from the fields the parser happened to read, not from the object, which is the
    /// same mistake that cost five hours on the Whoop write. `rawKeys` is now shown whether or not
    /// the parse succeeded, so the question gets answered from a real account rather than argued.
    var group: String?
    /// The field names the service actually returned, shown only when parsing failed.
    ///
    /// Whoop's read shape is the least verified thing in this app: the reference work it was ported
    /// from shipped no captured smart alarm response and its author hedged the shape in a comment.
    /// When the parse comes back empty, guessing again is worse than showing what arrived.
    var rawKeys: [String] = []

    var parsedCleanly: Bool { time != nil }

    /// Whether this alarm can ever go off.
    ///
    /// An alarm with no days and its switch off is inert. Eight Sleep's own app filters these out
    /// of its list, so an account showing two alarms there returns three here, and the difference
    /// reads as OneAlarm inventing one. It is shown, last, and labelled, rather than hidden:
    /// silently dropping something the account really contains is how this project has been wrong
    /// three times already.
    var canFire: Bool { isEnabled && !weekdays.isEmpty }

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

extension Array where Element == RemoteAlarmChoice {
    /// Grouped by the bed or pod that owns them, in a stable order, with the unnamed ones last.
    ///
    /// Two alarms at the same time on two different pods are indistinguishable by time and days,
    /// which is the entire reason a name matters: picking the wrong one silently moves the wrong
    /// bed, and the only symptom is somebody not waking up.
    var byGroup: [(name: String?, choices: [RemoteAlarmChoice])] {
        var order: [String] = []
        var buckets: [String: [RemoteAlarmChoice]] = [:]
        var unnamed: [RemoteAlarmChoice] = []

        // Inert alarms last, whatever their time. They are the ones a user does not recognise.
        for choice in sorted(by: { $0.canFire && !$1.canFire }) {
            guard let group = choice.group, !group.isEmpty else {
                unnamed.append(choice)
                continue
            }
            if buckets[group] == nil { order.append(group) }
            buckets[group, default: []].append(choice)
        }

        var result = order.map { (name: Optional($0), choices: buckets[$0] ?? []) }
        if !unnamed.isEmpty {
            // Named as unknown rather than blank, so a partially labelled account does not look
            // like a rendering bug.
            result.append((name: result.isEmpty ? nil : "Not named by the service", choices: unnamed))
        }
        return result
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
