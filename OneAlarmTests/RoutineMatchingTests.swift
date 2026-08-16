import XCTest
@testable import OneAlarm

/// The matcher that replaced the alarm picker.
///
/// Alex, 2026-08-16: *"picking one routine can break the entire thing... what I should be able to
/// pick is just the bed, and I should not pick a routine. This should only be done in the
/// background."*
///
/// These tests exist because the thing being replaced was not merely awkward, it was destructive.
/// One chosen alarm cannot carry two routines, so the app rewrote that alarm's **days** every time
/// the week turned over, which is how a real Monday to Friday schedule became every day. The rule
/// this file locks down is that a routine only ever drives an alarm that **already has its days**,
/// and that everything which does not line up is named rather than forced to fit.
final class RoutineMatchingTests: XCTestCase {

    private typealias Alarm = RoutinePlan.CandidateAlarm

    private func entry(
        _ id: String,
        _ days: Set<Locale.Weekday>,
        at hour: Int,
        minute: Int = 0,
        bentTo: WallClockTime? = nil
    ) -> RoutinePlan.Entry {
        RoutinePlan.Entry(
            routineID: id,
            routineName: id,
            weekdays: days,
            localTime: WallClockTime(hour: hour, minute: minute),
            bentTo: bentTo
        )
    }

    private let weekdayAlarm = Alarm(id: "a1", weekdays: Locale.Weekday.weekdaysOnly,
                                     isEnabled: true, label: "07:00 weekdays")
    private let weekendAlarm = Alarm(id: "a2", weekdays: [.saturday, .sunday],
                                     isEnabled: true, label: "09:00 Sat Sun")

    /// The case Alex described, end to end.
    func testEachRoutineDrivesTheAlarmWithItsOwnDays() {
        let report = RoutinePlan.match(
            entries: [
                entry("Weekdays", Locale.Weekday.weekdaysOnly, at: 6, minute: 50),
                entry("Weekend", [.saturday, .sunday], at: 8, minute: 50),
            ],
            against: [weekdayAlarm, weekendAlarm]
        )

        XCTAssertEqual(report.pairs.count, 2)
        XCTAssertEqual(report.pairs.first { $0.routineID == "Weekdays" }?.alarmID, "a1")
        XCTAssertEqual(report.pairs.first { $0.routineID == "Weekend" }?.alarmID, "a2")
        XCTAssertEqual(report.pairs.first { $0.routineID == "Weekend" }?.time.hhmm, "08:50")
        XCTAssertTrue(report.isComplete)
    }

    /// Nothing is reshaped to fit.
    ///
    /// A Monday to Friday routine landing on a Monday to Wednesday alarm would move an alarm
    /// covering days the routine does not describe, and the only way to make that correct is to
    /// rewrite the alarm's days. That operation no longer exists, so the honest outcome is to write
    /// nothing and say which routine has no home.
    func testAPartialDayOverlapIsNotAMatch() {
        let nearMiss = Alarm(id: "a3", weekdays: [.monday, .tuesday, .wednesday],
                             isEnabled: true, label: "07:00 Mon Tue Wed")
        let report = RoutinePlan.match(
            entries: [entry("Weekdays", Locale.Weekday.weekdaysOnly, at: 7)],
            against: [nearMiss]
        )

        XCTAssertTrue(report.pairs.isEmpty)
        XCTAssertEqual(report.routinesWithNoAlarm, ["Weekdays"])
        XCTAssertEqual(report.alarmsWithNoRoutine, ["07:00 Mon Tue Wed"])
        XCTAssertFalse(report.isComplete)
    }

    /// A routine covering a superset of an alarm's days is not a match either. Same reason, the
    /// other way round.
    func testASupersetIsNotAMatch() {
        let report = RoutinePlan.match(
            entries: [entry("Every day", Locale.Weekday.everyDay, at: 7)],
            against: [weekdayAlarm, weekendAlarm]
        )

        XCTAssertTrue(report.pairs.isEmpty)
        XCTAssertEqual(report.alarmsWithNoRoutine.count, 2)
    }

    /// An alarm nobody describes is left alone and named, never claimed by the nearest routine.
    func testAnUnmatchedAlarmIsReportedRatherThanTouched() {
        let stray = Alarm(id: "a9", weekdays: [.wednesday], isEnabled: true, label: "05:30 Wed")
        let report = RoutinePlan.match(
            entries: [entry("Weekdays", Locale.Weekday.weekdaysOnly, at: 7)],
            against: [weekdayAlarm, stray]
        )

        XCTAssertEqual(report.pairs.map(\.alarmID), ["a1"])
        XCTAssertEqual(report.alarmsWithNoRoutine, ["05:30 Wed"])
        XCTAssertTrue(report.isComplete, "every routine has an alarm, so the week has no hole in it")
    }

    /// An inert alarm is not a problem to report.
    ///
    /// Eight Sleep's own app hides alarms with no days, so an account showing two returns three.
    /// Naming that third one on every sync would put a warning in front of him about something he
    /// cannot see and does not care about.
    func testAnAlarmWithNoDaysIsNotReportedAsUnmatched() {
        let inert = Alarm(id: "a0", weekdays: [], isEnabled: false, label: "00:19, no days")
        let report = RoutinePlan.match(
            entries: [entry("Weekdays", Locale.Weekday.weekdaysOnly, at: 7)],
            against: [weekdayAlarm, inert]
        )

        XCTAssertEqual(report.alarmsWithNoRoutine, [])
    }

    /// A routine with no days of its own matches nothing and is not reported as a gap.
    func testARoutineWithNoDaysIsSkipped() {
        let report = RoutinePlan.match(
            entries: [entry("Empty", [], at: 7)],
            against: [weekdayAlarm]
        )

        XCTAssertTrue(report.pairs.isEmpty)
        XCTAssertTrue(report.routinesWithNoAlarm.isEmpty)
    }

    /// Two alarms with the same days are both moved.
    ///
    /// This list is scoped to one account, so they are both his, and leaving one behind is how two
    /// Monday alarms end up at two different times with nothing on screen saying why.
    func testEveryAlarmWithMatchingDaysIsMoved() {
        let twin = Alarm(id: "a1b", weekdays: Locale.Weekday.weekdaysOnly,
                         isEnabled: true, label: "07:15 weekdays")
        let report = RoutinePlan.match(
            entries: [entry("Weekdays", Locale.Weekday.weekdaysOnly, at: 6, minute: 50)],
            against: [weekdayAlarm, twin]
        )

        XCTAssertEqual(Set(report.pairs.map(\.alarmID)), ["a1", "a1b"])
        XCTAssertTrue(report.alarmsWithNoRoutine.isEmpty)
    }

    /// A switch he turned off stays off, and the receipt says so out loud.
    func testADisabledMatchIsFlaggedRatherThanSwitchedOn() {
        let off = Alarm(id: "a4", weekdays: Locale.Weekday.weekdaysOnly,
                        isEnabled: false, label: "07:00 weekdays")
        let report = RoutinePlan.match(
            entries: [entry("Weekdays", Locale.Weekday.weekdaysOnly, at: 7)],
            against: [off]
        )

        XCTAssertEqual(report.pairs.first?.isDisabledRemotely, true)
        XCTAssertTrue(report.note.contains("switched off"))
    }

    /// A one day bend writes the bent time, not the routine's time.
    func testABendIsWhatGetsWritten() {
        let report = RoutinePlan.match(
            entries: [entry("Weekend", [.saturday, .sunday], at: 9, bentTo: WallClockTime(hour: 10, minute: 0))],
            against: [weekendAlarm]
        )

        XCTAssertEqual(report.pairs.first?.time.hhmm, "10:00")
    }

    /// Every gap ends up in the sentence the user reads. A silent partial write is the failure mode
    /// this whole report exists to prevent.
    func testTheNoteNamesEveryGap() {
        let report = RoutinePlan.match(
            entries: [
                entry("Weekdays", Locale.Weekday.weekdaysOnly, at: 6, minute: 50),
                entry("Weekend", [.saturday, .sunday], at: 9),
            ],
            against: [weekdayAlarm, Alarm(id: "a7", weekdays: [.wednesday], isEnabled: true, label: "05:30 Wed")]
        )

        XCTAssertTrue(report.note.contains("Weekdays to 06:50"))
        XCTAssertTrue(report.note.contains("Weekend"), "the routine with no alarm has to be named")
        XCTAssertTrue(report.note.contains("05:30 Wed"), "the alarm left alone has to be named")
    }
}

/// The plan builder: routines projected onto one device's clock.
final class RoutinePlanBuildingTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return calendar
    }

    private func schedule(routines: [Routine], override: DayOverride? = nil) -> WakeSchedule {
        var schedule = WakeSchedule.default
        schedule.routines = routines
        schedule.override = override
        return schedule
    }

    private let pod = DeviceRule(device: .eightSleep, offsetMinutes: -10, isEnabled: true)

    func testEveryRoutineCarriesTheDeviceLead() {
        let plan = RulesEngine.plan(
            for: pod,
            in: schedule(routines: WakeSchedule.defaultRoutines),
            calendar: calendar,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(plan.entries.count, 2)
        XCTAssertEqual(plan.entries.first { $0.routineID == "weekdays" }?.localTime.hhmm, "06:50")
        XCTAssertEqual(plan.entries.first { $0.routineID == "weekend" }?.localTime.hhmm, "08:50")
    }

    /// A lead that walks the alarm onto the previous day has to walk the day set with it, or the
    /// plan would try to match a Monday to Friday alarm with a Sunday to Thursday intention.
    func testALeadAcrossMidnightShiftsTheDays() {
        let routine = Routine(
            id: "early",
            name: "Early",
            weekdayIndices: WeekdaySetCoding.encode(Locale.Weekday.weekdaysOnly),
            time: WallClockTime(hour: 0, minute: 5)
        )
        let plan = RulesEngine.plan(
            for: pod,
            in: schedule(routines: [routine]),
            calendar: calendar,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(plan.entries.first?.localTime.hhmm, "23:55")
        XCTAssertEqual(plan.entries.first?.weekdays, Set([.sunday, .monday, .tuesday, .wednesday, .thursday]))
    }

    func testARoutineThatIsSwitchedOffIsNotInThePlan() {
        var routines = WakeSchedule.defaultRoutines
        routines[1].isOn = false

        let plan = RulesEngine.plan(
            for: pod,
            in: schedule(routines: routines),
            calendar: calendar,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(plan.entries.map(\.routineID), ["weekdays"])
    }

    /// An expired bend must never reach a plan. It would put a time nobody chose on a live account.
    func testAnExpiredBendIsIgnored() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let yesterday = CalendarDay(calendar.date(byAdding: .day, value: -1, to: now)!, in: calendar)
        let plan = RulesEngine.plan(
            for: pod,
            in: schedule(
                routines: WakeSchedule.defaultRoutines,
                override: DayOverride(day: yesterday, time: WallClockTime(hour: 11, minute: 0))
            ),
            calendar: calendar,
            now: now
        )

        XCTAssertNil(plan.entries.first(where: \.isBent))
    }

    /// A skip is carried as a flag and deliberately not turned into a write.
    ///
    /// Eight Sleep has a `skipNext` field on every alarm and this app has never sent it, so its
    /// behaviour is known from its name and nothing else. This project has already paid five hours
    /// for reasoning about a field name.
    func testASkipIsFlaggedAndNotWritten() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = CalendarDay(now, in: calendar)
        let plan = RulesEngine.plan(
            for: pod,
            in: schedule(
                routines: WakeSchedule.defaultRoutines,
                override: DayOverride(day: today, time: nil)
            ),
            calendar: calendar,
            now: now
        )

        XCTAssertTrue(plan.skipsNextMorning)
        XCTAssertNil(plan.entries.first(where: \.isBent), "a skip is not a time to write")
    }
}
