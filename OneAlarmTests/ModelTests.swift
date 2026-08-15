import XCTest
@testable import OneAlarm

final class WallClockTimeTests: XCTestCase {

    func testWrapsOutOfRangeValues() {
        XCTAssertEqual(WallClockTime(hour: 25, minute: 0), WallClockTime(hour: 1, minute: 0))
        XCTAssertEqual(WallClockTime(hour: -1, minute: 0), WallClockTime(hour: 23, minute: 0))
    }

    func testMinutesSinceMidnightRoundTrips() {
        for minutes in stride(from: 0, to: 1440, by: 7) {
            XCTAssertEqual(WallClockTime(minutesSinceMidnight: minutes).minutesSinceMidnight, minutes)
        }
    }

    func testNegativeAndOverflowingMinutesNormalise() {
        XCTAssertEqual(WallClockTime(minutesSinceMidnight: -5), WallClockTime(hour: 23, minute: 55))
        XCTAssertEqual(WallClockTime(minutesSinceMidnight: 1443), WallClockTime(hour: 0, minute: 3))
    }

    /// Eight Sleep wants zero padding and seconds always present.
    func testWireFormat() {
        XCTAssertEqual(WallClockTime(hour: 6, minute: 5).hhmmss, "06:05:00")
        XCTAssertEqual(WallClockTime(hour: 23, minute: 55).hhmmss, "23:55:00")
        XCTAssertEqual(WallClockTime(hour: 6, minute: 5).hhmm, "06:05")
    }
}

final class WeekdayTests: XCTestCase {

    func testCalendarIndexRoundTrips() {
        for day in Locale.Weekday.displayOrder {
            XCTAssertEqual(Locale.Weekday.from(calendarIndex: day.calendarIndex), day)
        }
    }

    func testShiftingWraps() {
        XCTAssertEqual(Locale.Weekday.monday.shifted(by: -1), .sunday)
        XCTAssertEqual(Locale.Weekday.sunday.shifted(by: -1), .saturday)
        XCTAssertEqual(Locale.Weekday.saturday.shifted(by: 1), .sunday)
        XCTAssertEqual(Locale.Weekday.monday.shifted(by: 7), .monday)
        XCTAssertEqual(Locale.Weekday.monday.shifted(by: 0), .monday)
    }

    /// `from(calendarIndex:)` is fed `calendarIndex + days` directly, so it has to be correct well
    /// outside the 1 to 7 range. Index 0 and index 8 are the ones a single modulo gets wrong.
    func testIndexWrapsWellOutsideTheValidRange() {
        XCTAssertEqual(Locale.Weekday.from(calendarIndex: 0), .saturday)
        XCTAssertEqual(Locale.Weekday.from(calendarIndex: 8), .sunday)
        XCTAssertEqual(Locale.Weekday.from(calendarIndex: -6), .sunday)
        XCTAssertEqual(Locale.Weekday.from(calendarIndex: 15), .sunday)
        XCTAssertEqual(Locale.Weekday.from(calendarIndex: -13), .sunday)
    }

    func testWireNames() {
        XCTAssertEqual(Locale.Weekday.wednesday.whoopName, "WEDNESDAY")
        XCTAssertEqual(Locale.Weekday.wednesday.eightSleepKey, "wednesday")
    }

    func testSetCodingRoundTrips() {
        let days = Locale.Weekday.weekdaysOnly
        XCTAssertEqual(WeekdaySetCoding.decode(WeekdaySetCoding.encode(days)), days)
    }
}

final class ResolvedTargetTests: XCTestCase {

    private func target(offsetSeconds: Int) -> ResolvedTarget {
        ResolvedTarget(
            device: .whoop,
            localTime: WallClockTime(hour: 7, minute: 0),
            weekdays: [.monday],
            dayShift: 0,
            nextOccurrence: Date(timeIntervalSince1970: 0),
            utcOffsetSeconds: offsetSeconds
        )
    }

    /// Whoop wants `"-0700"` style, sign always present, four digits, no colon.
    func testOffsetStringFormatting() {
        XCTAssertEqual(target(offsetSeconds: 3600).utcOffsetString, "+0100")
        XCTAssertEqual(target(offsetSeconds: 7200).utcOffsetString, "+0200")
        XCTAssertEqual(target(offsetSeconds: -25200).utcOffsetString, "-0700")
        XCTAssertEqual(target(offsetSeconds: 0).utcOffsetString, "+0000")
        XCTAssertEqual(target(offsetSeconds: 19800).utcOffsetString, "+0530")
        XCTAssertEqual(target(offsetSeconds: -12600).utcOffsetString, "-0330")
    }
}

final class WakeScheduleTests: XCTestCase {

    func testDefaultsMatchTheDocumentedRules() {
        let schedule = WakeSchedule.default
        XCTAssertEqual(schedule.masterTime, WallClockTime(hour: 7, minute: 0))
        XCTAssertEqual(schedule.rule(for: .eightSleep)?.offsetMinutes, -10)
        XCTAssertEqual(schedule.rule(for: .whoop)?.offsetMinutes, -5)
        XCTAssertEqual(schedule.rule(for: .iphone)?.offsetMinutes, 0)
    }

    func testCodableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(WakeSchedule.default)
        let decoded = try JSONDecoder().decode(WakeSchedule.self, from: encoded)
        XCTAssertEqual(decoded, WakeSchedule.default)
    }

    /// Nothing credential shaped may end up in the persisted schedule, since it lives in plain
    /// UserDefaults.
    func testPersistedScheduleCarriesNoCredentialFields() throws {
        let json = String(data: try JSONEncoder().encode(WakeSchedule.default), encoding: .utf8)!.lowercased()
        for forbidden in ["password", "token", "secret", "email"] {
            XCTAssertFalse(json.contains(forbidden), "schedule JSON contained \(forbidden)")
        }
    }
}
