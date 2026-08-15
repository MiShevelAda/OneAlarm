import XCTest
@testable import OneAlarm

/// The RulesEngine is the only part of this app that can be tested completely without a device, a
/// network or a credential, and it is where the correctness risk actually lives. The three edges
/// that matter are midnight crossing, daylight saving, and weekday shifting, because each of them
/// produces an alarm that is wrong by hours rather than obviously broken.
final class RulesEngineTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    /// An absolute instant, for asserting what a daylight saving transition actually produced
    /// rather than only that something was produced.
    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return gregorian.date(from: components)!
    }

    private func schedule(
        master: WallClockTime,
        days: Set<Locale.Weekday>,
        rules: [DeviceRule]
    ) -> WakeSchedule {
        WakeSchedule(
            masterTime: master,
            weekdayIndices: WeekdaySetCoding.encode(days),
            rules: rules
        )
    }

    // MARK: Offsets

    func testOffsetsProduceTheExpectedLocalTimes() {
        let schedule = schedule(
            master: WallClockTime(hour: 7, minute: 0),
            days: Locale.Weekday.weekdaysOnly,
            rules: [
                DeviceRule(device: .eightSleep, offsetMinutes: -10, isEnabled: true, weekdayOverrideIndices: nil),
                DeviceRule(device: .whoop, offsetMinutes: -5, isEnabled: true, weekdayOverrideIndices: nil),
                DeviceRule(device: .iphone, offsetMinutes: 0, isEnabled: true, weekdayOverrideIndices: nil),
            ]
        )

        let targets = RulesEngine.resolve(
            schedule: schedule, calendar: calendar, now: date(2026, 8, 17, 12, 0)
        )

        XCTAssertEqual(targets.count, 3)
        XCTAssertEqual(targets.first(where: { $0.device == .eightSleep })?.localTime, WallClockTime(hour: 6, minute: 50))
        XCTAssertEqual(targets.first(where: { $0.device == .whoop })?.localTime, WallClockTime(hour: 6, minute: 55))
        XCTAssertEqual(targets.first(where: { $0.device == .iphone })?.localTime, WallClockTime(hour: 7, minute: 0))
    }

    func testTargetsAreOrderedByWhenTheyFire() {
        let schedule = schedule(
            master: WallClockTime(hour: 7, minute: 0),
            days: Locale.Weekday.everyDay,
            rules: [
                DeviceRule(device: .iphone, offsetMinutes: 0, isEnabled: true, weekdayOverrideIndices: nil),
                DeviceRule(device: .eightSleep, offsetMinutes: -10, isEnabled: true, weekdayOverrideIndices: nil),
                DeviceRule(device: .whoop, offsetMinutes: -5, isEnabled: true, weekdayOverrideIndices: nil),
            ]
        )

        let targets = RulesEngine.resolve(
            schedule: schedule, calendar: calendar, now: date(2026, 8, 17, 12, 0)
        )

        XCTAssertEqual(targets.map(\.device), [.eightSleep, .whoop, .iphone])
    }

    func testDisabledRulesAreSkipped() {
        let schedule = schedule(
            master: WallClockTime(hour: 7, minute: 0),
            days: Locale.Weekday.everyDay,
            rules: [
                DeviceRule(device: .iphone, offsetMinutes: 0, isEnabled: true, weekdayOverrideIndices: nil),
                DeviceRule(device: .whoop, offsetMinutes: -5, isEnabled: false, weekdayOverrideIndices: nil),
            ]
        )

        let targets = RulesEngine.resolve(
            schedule: schedule, calendar: calendar, now: date(2026, 8, 17, 12, 0)
        )

        XCTAssertEqual(targets.map(\.device), [.iphone])
    }

    // MARK: Midnight

    /// The trap this whole `dayShift` mechanism exists for. A Monday master alarm at 00:05 with a
    /// ten minute lead is really a Sunday 23:55 alarm. Sending it as Monday 23:55 warms the bed a
    /// full night late.
    func testNegativeOffsetCrossingMidnightMovesTheDayBack() {
        let schedule = schedule(
            master: WallClockTime(hour: 0, minute: 5),
            days: [.monday],
            rules: [DeviceRule(device: .eightSleep, offsetMinutes: -10, isEnabled: true, weekdayOverrideIndices: nil)]
        )

        let target = RulesEngine.resolve(
            schedule: schedule, calendar: calendar, now: date(2026, 8, 17, 12, 0)
        ).first

        XCTAssertEqual(target?.localTime, WallClockTime(hour: 23, minute: 55))
        XCTAssertEqual(target?.dayShift, -1)
        XCTAssertEqual(target?.weekdays, [.sunday])
        XCTAssertEqual(target?.crossesMidnight, true)
    }

    func testPositiveOffsetCrossingMidnightMovesTheDayForward() {
        let schedule = schedule(
            master: WallClockTime(hour: 23, minute: 58),
            days: [.friday],
            rules: [DeviceRule(device: .iphone, offsetMinutes: 5, isEnabled: true, weekdayOverrideIndices: nil)]
        )

        let target = RulesEngine.resolve(
            schedule: schedule, calendar: calendar, now: date(2026, 8, 17, 12, 0)
        ).first

        XCTAssertEqual(target?.localTime, WallClockTime(hour: 0, minute: 3))
        XCTAssertEqual(target?.dayShift, 1)
        XCTAssertEqual(target?.weekdays, [.saturday])
    }

    func testWholeWeekShiftsBackTogether() {
        let schedule = schedule(
            master: WallClockTime(hour: 0, minute: 0),
            days: Locale.Weekday.weekdaysOnly,
            rules: [DeviceRule(device: .eightSleep, offsetMinutes: -30, isEnabled: true, weekdayOverrideIndices: nil)]
        )

        let target = RulesEngine.resolve(
            schedule: schedule, calendar: calendar, now: date(2026, 8, 17, 12, 0)
        ).first

        XCTAssertEqual(target?.localTime, WallClockTime(hour: 23, minute: 30))
        XCTAssertEqual(target?.weekdays, [.sunday, .monday, .tuesday, .wednesday, .thursday])
    }

    // MARK: Daylight saving

    /// Europe/Zurich springs forward on 29 March 2026: 02:00 CET becomes 03:00 CEST, so 02:30 that
    /// morning does not exist at all.
    ///
    /// Asserting the exact instant matters here. A test that only checks "not nil, and later than
    /// now" also passes if the engine silently skips to the *following* Sunday, which is an alarm a
    /// week late and a far worse bug than no alarm.
    func testSpringForwardResolvesToTheFirstRealInstant() {
        let schedule = schedule(
            master: WallClockTime(hour: 2, minute: 30),
            days: [.sunday],
            rules: [DeviceRule(device: .iphone, offsetMinutes: 0, isEnabled: true, weekdayOverrideIndices: nil)]
        )

        let target = RulesEngine.resolve(
            schedule: schedule, calendar: calendar, now: date(2026, 3, 28, 12, 0)
        ).first

        // 03:00 CEST, the first instant that exists after the gap.
        XCTAssertEqual(target?.nextOccurrence, utc(2026, 3, 29, 1, 0))
    }

    /// Zurich falls back on 25 October 2026: 03:00 CEST becomes 02:00 CET.
    ///
    /// The point of this test is that a wall clock offset is not an elapsed time offset. A 70 minute
    /// lead spans the repeated hour and becomes a **130 minute** real gap, and the summary line in
    /// the UI reports that number to the user.
    func testFallBackStretchesTheRealGap() {
        let schedule = schedule(
            master: WallClockTime(hour: 3, minute: 0),
            days: [.sunday],
            rules: [
                DeviceRule(device: .iphone, offsetMinutes: 0, isEnabled: true, weekdayOverrideIndices: nil),
                DeviceRule(device: .eightSleep, offsetMinutes: -70, isEnabled: true, weekdayOverrideIndices: nil),
            ]
        )

        let targets = RulesEngine.resolve(
            schedule: schedule, calendar: calendar, now: date(2026, 10, 24, 12, 0)
        )

        let eightSleep = targets.first { $0.device == .eightSleep }
        let iphone = targets.first { $0.device == .iphone }

        XCTAssertEqual(eightSleep?.localTime, WallClockTime(hour: 1, minute: 50))
        // 01:50 is still CEST, before the transition.
        XCTAssertEqual(eightSleep?.nextOccurrence, utc(2026, 10, 24, 23, 50))
        // 03:00 is CET, after it.
        XCTAssertEqual(iphone?.nextOccurrence, utc(2026, 10, 25, 2, 0))
        XCTAssertEqual(RulesEngine.leadMinutes(for: targets), 130)
    }

    /// A whole day of offset keeps the time and moves the day. This is the case a naive
    /// `shifted / 1440` gets wrong, because integer division truncates toward zero and yields a
    /// day shift of 0 for exactly -1440.
    func testWholeDayOffsetsKeepTheTimeAndMoveTheDay() {
        func target(offset: Int) -> ResolvedTarget? {
            RulesEngine.resolve(
                schedule: schedule(
                    master: WallClockTime(hour: 0, minute: 0),
                    days: [.monday],
                    rules: [DeviceRule(device: .iphone, offsetMinutes: offset, isEnabled: true, weekdayOverrideIndices: nil)]
                ),
                calendar: calendar,
                now: date(2026, 8, 17, 12, 0)
            ).first
        }

        XCTAssertEqual(target(offset: -1440)?.localTime, WallClockTime(hour: 0, minute: 0))
        XCTAssertEqual(target(offset: -1440)?.dayShift, -1)
        XCTAssertEqual(target(offset: -1440)?.weekdays, [.sunday])

        XCTAssertEqual(target(offset: 1440)?.localTime, WallClockTime(hour: 0, minute: 0))
        XCTAssertEqual(target(offset: 1440)?.dayShift, 1)
        XCTAssertEqual(target(offset: 1440)?.weekdays, [.tuesday])
    }

    func testOneMinuteBoundaries() {
        func target(master: WallClockTime, offset: Int) -> ResolvedTarget? {
            RulesEngine.resolve(
                schedule: schedule(
                    master: master,
                    days: [.wednesday],
                    rules: [DeviceRule(device: .iphone, offsetMinutes: offset, isEnabled: true, weekdayOverrideIndices: nil)]
                ),
                calendar: calendar,
                now: date(2026, 8, 17, 12, 0)
            ).first
        }

        let back = target(master: WallClockTime(hour: 0, minute: 0), offset: -1)
        XCTAssertEqual(back?.localTime, WallClockTime(hour: 23, minute: 59))
        XCTAssertEqual(back?.dayShift, -1)
        XCTAssertEqual(back?.weekdays, [.tuesday])

        let forward = target(master: WallClockTime(hour: 23, minute: 59), offset: 1)
        XCTAssertEqual(forward?.localTime, WallClockTime(hour: 0, minute: 0))
        XCTAssertEqual(forward?.dayShift, 1)
        XCTAssertEqual(forward?.weekdays, [.thursday])
    }

    /// A set that straddles the wrap has to move as a whole, not partly.
    func testWeekdaySetSpanningTheWrapShiftsTogether() {
        let target = RulesEngine.resolve(
            schedule: schedule(
                master: WallClockTime(hour: 0, minute: 30),
                days: [.sunday, .monday],
                rules: [DeviceRule(device: .eightSleep, offsetMinutes: -60, isEnabled: true, weekdayOverrideIndices: nil)]
            ),
            calendar: calendar,
            now: date(2026, 8, 17, 12, 0)
        ).first

        XCTAssertEqual(target?.localTime, WallClockTime(hour: 23, minute: 30))
        XCTAssertEqual(target?.weekdays, [.saturday, .sunday])
    }

    // MARK: Boundary behaviour around "now"

    /// Exactly at the alarm minute, the answer is tomorrow. An alarm firing for an instant that has
    /// just arrived would fire immediately on every recompute.
    func testAlarmAtExactlyNowRollsToTheNextDay() {
        let now = date(2026, 8, 17, 7, 0)
        let target = RulesEngine.resolve(
            schedule: schedule(
                master: WallClockTime(hour: 7, minute: 0),
                days: Locale.Weekday.everyDay,
                rules: [DeviceRule(device: .iphone, offsetMinutes: 0, isEnabled: true, weekdayOverrideIndices: nil)]
            ),
            calendar: calendar,
            now: now
        ).first

        XCTAssertEqual(target?.nextOccurrence, date(2026, 8, 18, 7, 0))
    }

    func testAlarmOneMinuteAwayIsStillToday() {
        let now = date(2026, 8, 17, 6, 59)
        let target = RulesEngine.resolve(
            schedule: schedule(
                master: WallClockTime(hour: 7, minute: 0),
                days: Locale.Weekday.everyDay,
                rules: [DeviceRule(device: .iphone, offsetMinutes: 0, isEnabled: true, weekdayOverrideIndices: nil)]
            ),
            calendar: calendar,
            now: now
        ).first

        XCTAssertEqual(target?.nextOccurrence, date(2026, 8, 17, 7, 0))
    }

    /// The offset string is recomputed for the instant the alarm fires, so a summer alarm and a
    /// winter alarm carry different offsets. Whoop's field has no daylight saving awareness, which
    /// is exactly why this must not be cached.
    func testUTCOffsetFollowsTheSeason() {
        let schedule = schedule(
            master: WallClockTime(hour: 7, minute: 0),
            days: Locale.Weekday.everyDay,
            rules: [DeviceRule(device: .whoop, offsetMinutes: 0, isEnabled: true, weekdayOverrideIndices: nil)]
        )

        let summer = RulesEngine.resolve(schedule: schedule, calendar: calendar, now: date(2026, 7, 1, 12, 0)).first
        let winter = RulesEngine.resolve(schedule: schedule, calendar: calendar, now: date(2026, 12, 1, 12, 0)).first

        XCTAssertEqual(summer?.utcOffsetString, "+0200")
        XCTAssertEqual(winter?.utcOffsetString, "+0100")
    }

    // MARK: Weekdays

    func testPerDeviceWeekdayOverrideWins() {
        var rule = DeviceRule(device: .whoop, offsetMinutes: 0, isEnabled: true, weekdayOverrideIndices: nil)
        rule.weekdayOverride = [.saturday, .sunday]

        let schedule = schedule(
            master: WallClockTime(hour: 9, minute: 0),
            days: Locale.Weekday.weekdaysOnly,
            rules: [rule]
        )

        let target = RulesEngine.resolve(
            schedule: schedule, calendar: calendar, now: date(2026, 8, 17, 12, 0)
        ).first

        XCTAssertEqual(target?.weekdays, [.saturday, .sunday])
    }

    func testEmptyWeekdaySetProducesNoTarget() {
        let schedule = schedule(
            master: WallClockTime(hour: 7, minute: 0),
            days: [],
            rules: [DeviceRule(device: .iphone, offsetMinutes: 0, isEnabled: true, weekdayOverrideIndices: nil)]
        )

        let targets = RulesEngine.resolve(
            schedule: schedule, calendar: calendar, now: date(2026, 8, 17, 12, 0)
        )

        XCTAssertTrue(targets.isEmpty)
    }

    func testNextOccurrenceIsAlwaysInTheFuture() {
        let now = date(2026, 8, 17, 7, 30)
        let schedule = schedule(
            master: WallClockTime(hour: 7, minute: 0),
            days: Locale.Weekday.everyDay,
            rules: [DeviceRule(device: .iphone, offsetMinutes: 0, isEnabled: true, weekdayOverrideIndices: nil)]
        )

        let target = RulesEngine.resolve(schedule: schedule, calendar: calendar, now: now).first

        XCTAssertNotNil(target)
        XCTAssertGreaterThan(target!.nextOccurrence, now)
    }
}
