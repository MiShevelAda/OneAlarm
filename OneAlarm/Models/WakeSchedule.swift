import Foundation

enum DeviceID: String, Codable, CaseIterable, Sendable, Identifiable {
    case iphone
    case eightSleep
    case whoop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iphone: return "iPhone"
        case .eightSleep: return "Eight Sleep"
        case .whoop: return "Whoop"
        }
    }

    /// What the offset is for, in one line, shown under the device name.
    var rationale: String {
        switch self {
        case .iphone: return "The loud backstop. Also rings on the Apple Watch."
        case .eightSleep: return "Thermal and vibration ramp needs a run up."
        case .whoop: return "Haptic smart wake window."
        }
    }

    var symbolName: String {
        switch self {
        case .iphone: return "iphone"
        case .eightSleep: return "bed.double.fill"
        case .whoop: return "applewatch"
        }
    }

    /// Whether the leg needs credentials before it can do anything.
    var requiresCredentials: Bool {
        switch self {
        case .iphone: return false
        case .eightSleep, .whoop: return true
        }
    }
}

struct DeviceRule: Codable, Equatable, Sendable, Identifiable {
    var device: DeviceID
    /// Negative is earlier than the master time. Eight Sleep defaults to -10, Whoop to -5.
    var offsetMinutes: Int
    var isEnabled: Bool
    /// When set, this device uses its own days instead of the master's.
    var weekdayOverrideIndices: [Int]?

    var id: String { device.rawValue }

    var weekdayOverride: Set<Locale.Weekday>? {
        get { weekdayOverrideIndices.map(WeekdaySetCoding.decode) }
        set { weekdayOverrideIndices = newValue.map(WeekdaySetCoding.encode) }
    }
}

/// A named set of days with one wake time. Two by default, matching the split both services already
/// hold on the account: Weekdays and Weekend.
///
/// A day belongs to at most one routine. That is enforced when days are toggled, because two
/// routines claiming the same day means two answers to "when do I wake on Tuesday" and no way to
/// pick between them.
struct Routine: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var weekdayIndices: [Int]
    var time: WallClockTime
    var isOn: Bool = true

    var weekdays: Set<Locale.Weekday> {
        get { WeekdaySetCoding.decode(weekdayIndices) }
        set { weekdayIndices = WeekdaySetCoding.encode(newValue) }
    }

    /// The routine's name, derived from the days rather than stored.
    ///
    /// Alex, 2026-08-16: *"don't redefine the name of the routine. It might be weekdays, but maybe
    /// some people will have a routine Monday to Wednesday."* A stored "Weekdays" is a label that
    /// was true when it was written and becomes a lie the moment the days change, and nothing warns
    /// you. Derived, it cannot disagree with the chips directly beneath it.
    var displayName: String {
        let days = Locale.Weekday.displayOrder.filter { weekdays.contains($0) }
        if days.isEmpty { return "No days" }
        if Set(days) == Locale.Weekday.everyDay { return "Every day" }
        if Set(days) == Locale.Weekday.weekdaysOnly { return "Weekdays" }
        if Set(days) == Set([Locale.Weekday.saturday, .sunday]) { return "Weekend" }
        if days.count == 1 { return days[0].shortLabel + "s" }

        // A contiguous run reads as a range. Monday to Wednesday, not Mon, Tue, Wed.
        let order = Locale.Weekday.displayOrder
        if let first = order.firstIndex(of: days[0]), let last = order.firstIndex(of: days[days.count - 1]),
           last - first + 1 == days.count {
            return "\(days[0].shortLabel) to \(days[days.count - 1].shortLabel)"
        }
        return days.map(\.shortLabel).joined(separator: " ")
    }

    /// "Monday to Friday", "Saturday and Sunday", "Tuesday". Written out rather than abbreviated,
    /// because the chips above it are already the short version and repeating them says nothing.
    var daysSentence: String {
        let days = Locale.Weekday.displayOrder.filter { weekdays.contains($0) }
        if days.isEmpty { return "never" }
        if Set(days) == Locale.Weekday.everyDay { return "day" }
        if Set(days) == Locale.Weekday.weekdaysOnly { return "Monday to Friday" }
        if Set(days) == Set([Locale.Weekday.saturday, .sunday]) { return "Saturday and Sunday" }
        let names = days.map(\.shortLabel)
        guard names.count > 1, let last = names.last else { return names.joined() }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// A calendar day, stored as three integers rather than a `Date`.
///
/// A `Date` is an instant, and an instant means a different day depending on where you are standing.
/// "Saturday the sixteenth" has to survive a flight.
struct CalendarDay: Codable, Equatable, Sendable, Comparable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, in calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    var sortKey: Int { year * 10_000 + month * 100 + day }

    static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool { lhs.sortKey < rhs.sortKey }

    func date(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}

/// One day bent away from its routine, or skipped.
///
/// **Keyed by a date, never by a weekday.** Alex, 2026-08-16: a weekend routine covers Saturday and
/// Sunday, and moving Saturday must leave Sunday and every future Saturday alone. Keyed by weekday
/// it would move all of them, which is editing the routine rather than deviating from it.
///
/// It expires by itself. An override that has to be cancelled is one that eventually fires on a
/// morning nobody chose.
struct DayOverride: Codable, Equatable, Sendable {
    var day: CalendarDay
    /// `nil` means skip: no alarm at all that day, routine untouched.
    var time: WallClockTime?
    /// What the routine said, so it can be put back and so the screen can name it.
    var routineTime: WallClockTime?
    var routineName: String?

    var isSkip: Bool { time == nil }
}

/// The plan. Routines are the source; `masterTime` and `weekdayIndices` are **derived** from them
/// and from any override, recomputed on every change.
///
/// The derived pair is kept because every downstream consumer, the rules engine and all three
/// adapters, already works in those terms. Changing them into a routine-aware pipeline in one step
/// would touch everything at once, and nothing here has a compiler.
struct WakeSchedule: Codable, Equatable, Sendable {
    var masterTime: WallClockTime
    var weekdayIndices: [Int]
    var rules: [DeviceRule]
    var routines: [Routine] = WakeSchedule.defaultRoutines
    var override: DayOverride?
    /// Whose clock the routine time is expressed in. Its offset is zero by definition.
    ///
    /// **Not the same as which device has to wake you**, and the two must not be merged. The anchor
    /// is arithmetic: type 07:55 against the strap and everything else derives from it. The phone
    /// stays the leg that carries the guarantee, because it is the only one that arms with no
    /// account, no network and no server. Whoop can be refused, rate limited, signed out, or hold a
    /// value its strap never syncs, and all four happened on the first night of use.
    var anchorDeviceRaw: String = DeviceID.iphone.rawValue

    var anchorDevice: DeviceID {
        get { DeviceID(rawValue: anchorDeviceRaw) ?? .iphone }
        set { anchorDeviceRaw = newValue.rawValue }
    }

    var weekdays: Set<Locale.Weekday> {
        get { WeekdaySetCoding.decode(weekdayIndices) }
        set { weekdayIndices = WeekdaySetCoding.encode(newValue) }
    }

    static let defaultRoutines: [Routine] = [
        Routine(id: "weekdays", name: "Weekdays",
                weekdayIndices: WeekdaySetCoding.encode(Locale.Weekday.weekdaysOnly),
                time: WallClockTime(hour: 7, minute: 0)),
        Routine(id: "weekend", name: "Weekend",
                weekdayIndices: WeekdaySetCoding.encode([.saturday, .sunday]),
                time: WallClockTime(hour: 9, minute: 0)),
    ]

    static let `default` = WakeSchedule(
        masterTime: WallClockTime(hour: 7, minute: 0),
        weekdayIndices: WeekdaySetCoding.encode(Locale.Weekday.weekdaysOnly),
        rules: [
            DeviceRule(device: .eightSleep, offsetMinutes: -10, isEnabled: true, weekdayOverrideIndices: nil),
            DeviceRule(device: .whoop, offsetMinutes: -5, isEnabled: true, weekdayOverrideIndices: nil),
            DeviceRule(device: .iphone, offsetMinutes: 0, isEnabled: true, weekdayOverrideIndices: nil),
        ],
        routines: WakeSchedule.defaultRoutines,
        override: nil
    )

    func rule(for device: DeviceID) -> DeviceRule? {
        rules.first { $0.device == device }
    }

    func routine(covering day: Locale.Weekday) -> Routine? {
        routines.first { $0.isOn && $0.weekdays.contains(day) }
    }
}
