import Foundation

/// A time of day with no date and no time zone attached.
///
/// This exists because the three device legs disagree about what a "time" is. AlarmKit wants a
/// time zone relative hour and minute, Eight Sleep wants a bare `"HH:mm:ss"` string that its
/// server resolves against a zone we never see, and Whoop wants a wall clock plus a fixed offset
/// string. Passing a `Date` around and hoping is how this ships an alarm at the wrong hour, so the
/// engine works in wall clock and each adapter projects into its own convention.
struct WallClockTime: Codable, Equatable, Hashable, Sendable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = ((hour % 24) + 24) % 24
        self.minute = ((minute % 60) + 60) % 60
    }

    /// Minutes since midnight, 0 through 1439.
    var minutesSinceMidnight: Int { hour * 60 + minute }

    init(minutesSinceMidnight: Int) {
        let normalized = ((minutesSinceMidnight % 1440) + 1440) % 1440
        self.hour = normalized / 60
        self.minute = normalized % 60
    }

    /// `"06:50:00"`. The format Eight Sleep expects on the wire: zero padded, seconds always
    /// present, no offset.
    var hhmmss: String {
        String(format: "%02d:%02d:00", hour, minute)
    }

    /// `"06:50"` for display.
    var hhmm: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

extension WallClockTime: Comparable {
    static func < (lhs: WallClockTime, rhs: WallClockTime) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }
}
