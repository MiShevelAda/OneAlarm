import Foundation

/// `Locale.Weekday` is the type AlarmKit's recurrence takes, but it carries no ordering and no
/// integer mapping of its own. Both are needed: ordering so a stored set round trips
/// deterministically, and an integer so a day can be shifted when an offset crosses midnight.
extension Locale.Weekday {

    /// 1 = Sunday through 7 = Saturday, matching `Calendar.component(.weekday, from:)`.
    var calendarIndex: Int {
        switch self {
        case .sunday: return 1
        case .monday: return 2
        case .tuesday: return 3
        case .wednesday: return 4
        case .thursday: return 5
        case .friday: return 6
        case .saturday: return 7
        @unknown default: return 1
        }
    }

    static func from(calendarIndex: Int) -> Locale.Weekday {
        let normalized = ((calendarIndex - 1) % 7 + 7) % 7 + 1
        switch normalized {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        default: return .saturday
        }
    }

    /// Shift by whole days, wrapping. `days` is negative when an offset pushed the alarm onto the
    /// previous day.
    func shifted(by days: Int) -> Locale.Weekday {
        .from(calendarIndex: calendarIndex + days)
    }

    /// `"MONDAY"`. Whoop's `day_of_week_list` casing.
    var whoopName: String {
        switch self {
        case .sunday: return "SUNDAY"
        case .monday: return "MONDAY"
        case .tuesday: return "TUESDAY"
        case .wednesday: return "WEDNESDAY"
        case .thursday: return "THURSDAY"
        case .friday: return "FRIDAY"
        case .saturday: return "SATURDAY"
        @unknown default: return "MONDAY"
        }
    }

    /// `"monday"`. Eight Sleep's `repeat.weekDays` key casing.
    var eightSleepKey: String {
        whoopName.lowercased()
    }

    /// Two letter label for the day picker.
    var shortLabel: String {
        switch self {
        case .sunday: return "Su"
        case .monday: return "Mo"
        case .tuesday: return "Tu"
        case .wednesday: return "We"
        case .thursday: return "Th"
        case .friday: return "Fr"
        case .saturday: return "Sa"
        @unknown default: return "?"
        }
    }

    /// Monday first, which is how the picker reads in Europe.
    static let displayOrder: [Locale.Weekday] = [
        .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday,
    ]

    static let weekdaysOnly: Set<Locale.Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    static let everyDay: Set<Locale.Weekday> = Set(displayOrder)
}

/// `Locale.Weekday` is not `Codable`, so a set of them cannot be persisted directly. These helpers
/// convert to and from the calendar indices, which are stable across OS versions in a way that a
/// raw enum ordering would not be.
enum WeekdaySetCoding {
    static func encode(_ days: Set<Locale.Weekday>) -> [Int] {
        days.map(\.calendarIndex).sorted()
    }

    static func decode(_ indices: [Int]) -> Set<Locale.Weekday> {
        Set(indices.map { Locale.Weekday.from(calendarIndex: $0) })
    }
}
