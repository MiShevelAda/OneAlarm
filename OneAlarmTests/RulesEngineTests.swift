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

    /// Europe/Zurich springs forward on 29 March 2026, so 02:30 that morning does not exist. The
    /// correct answer is the next real instant, not "no alarm".
    func testSpringForwardStillProducesAnAlarm() {
        let schedule = schedule(
            master: WallClockTime(hour: 2, minute: 30),
            days: [.sunday],
            rules: [DeviceRule(device: .iphone, offsetMinutes: 0, isEnabled: true, weekdayOverrideIndices: nil)]
        )

        let target = RulesEngine.resolve(
            schedule: schedule, calendar: calendar, now: date(2026, 3, 28, 12, 0)
        ).first

        XCTAssertNotNil(target?.nextOccurrence)
        XCTAssertGreaterThan(target!.nextOccurrence, date(2026, 3, 28, 12, 0))
    }

    /// The offset is in wall clock minutes, so the UTC gap between two legs is not constant across
    /// a transition. Recording the behaviour rather than asserting a number, because what matters
    /// is that both legs resolve and neither silently disappears.
    func testFallBackResolvesBothLegs() {
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

        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(targets.first(where: { $0.device == .eightSleep })?.localTime, WallClockTime(hour: 1, minute: 50))
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
