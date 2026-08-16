import XCTest
@testable import OneAlarm

/// A bend that crosses midnight and the day set that should follow it.
///
/// **Known defect, logged as problem 1 in `docs/STATUS.md`, deliberately not fixed on 17 August.**
/// `RulesEngine.plan` computes `dayShift` from the **routine's** time plus the device lead, then uses
/// it to shift the day set. The bent time is computed separately with no day shift of its own. When
/// the bend and the routine fall on different sides of midnight for that device, the days written no
/// longer belong to the time written, and the bed is armed roughly a day out.
///
/// **Why the test asserts the wrong answer on purpose.** The obvious fix, deriving the shift from the
/// bent time, means a bend **rewrites a remote alarm's days** for one morning and something has to put
/// them back. Writing days to a remote alarm is what turned Alex's real Monday to Friday schedule into
/// every day, and Eight Sleep was confirmed working hours before this was found. So the behaviour is
/// pinned rather than changed, and the test documents the bug instead of hiding it.
///
/// **Closed 18 August, and not the way this file expected.** The fix it described, deriving the day
/// set from the bent time, was never made, because the bend stopped touching the routine's alarm at
/// all. It gets its own alarm on both legs now, so the routine's days were never the thing that had
/// to change.
///
/// What did have to change is `overrideDay.weekday`: which single morning the override arms. That
/// takes the **bend's** shift, while a skip takes the **routine's**, because a skip suppresses an
/// alarm that fires at the routine's time. One shift for both was the bug, and it went from cosmetic
/// to real the moment that field started creating alarms.
///
/// Kept in full rather than rewritten, including the reasoning that turned out to be answering the
/// wrong question. It was correct reasoning about the design as it stood, and knowing that a
/// carefully argued fix can be dissolved by a change somewhere else is worth more than a tidy file.
final class OverrideDayShiftTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich") ?? .current
        return calendar
    }

    /// Friday 15 January 2027, 22:00 local. Fixed rather than `Date()`, so this cannot fail on a
    /// Tuesday for reasons nobody can reproduce on a Wednesday.
    private var now: Date {
        var parts = DateComponents()
        parts.year = 2027; parts.month = 1; parts.day = 15; parts.hour = 22
        return calendar.date(from: parts)!
    }

    private let bedLead = DeviceRule(device: .eightSleep, offsetMinutes: -10, isEnabled: true)

    private func schedule(routineAt time: WallClockTime, bentTo: WallClockTime?) -> WakeSchedule {
        var schedule = WakeSchedule.default
        schedule.routines = [
            Routine(id: "weekdays", name: "Weekdays",
                    weekdayIndices: WeekdaySetCoding.encode(Locale.Weekday.weekdaysOnly),
                    time: time),
        ]
        // **Monday the 18th, and the date is the whole fixture.**
        //
        // This said "Saturday the 16th, the morning after `now`" and put the override there. `now` is
        // Friday at 22:00, so the next *calendar* morning is indeed Saturday, but these routines are
        // **Monday to Friday** and their next firing is Monday the 18th. `RulesEngine.plan` finds the
        // bent routine with `schedule.routine(covering:)` on the override's weekday, nothing covers
        // Saturday, so `bentTo` came out nil and every assertion about a bent time failed against the
        // unbent one.
        //
        // The fixture was wrong, not the engine. Worth the paragraph because the failure reads as a
        // bend bug and is a calendar bug, and the two live in different files.
        schedule.override = DayOverride(day: CalendarDay(year: 2027, month: 1, day: 18),
                                        time: bentTo, routineTime: time, routineName: "Weekdays")
        return schedule
    }

    /// The routine's own midnight crossing shifts the days, and that part is correct.
    ///
    /// A weekday routine at 00:05 with a ten minute bed lead is an alarm at 23:55 the evening before,
    /// so Monday to Friday becomes Sunday to Thursday. This is the behaviour the shift exists for and
    /// it must survive any fix to the one below.
    func testTheRoutinesOwnMidnightCrossingStillShifts() throws {
        let plan = RulesEngine.plan(
            for: bedLead,
            in: schedule(routineAt: WallClockTime(hour: 0, minute: 5), bentTo: nil),
            calendar: calendar,
            now: now
        )

        let entry = try XCTUnwrap(plan.entries.first)
        XCTAssertEqual(entry.localTime.hhmm, "23:55")
        XCTAssertEqual(entry.weekdays, Set([.sunday, .monday, .tuesday, .wednesday, .thursday]),
                       "an alarm at 23:55 on Sunday is Monday's alarm")
    }

    /// **The defect, resolved rather than fixed.** A bend across midnight leaves the routine alone.
    ///
    /// This asserted the wrong answer on purpose until 18 August, and the reasoning was sound at the
    /// time: deriving the day set from the bent time meant a bend would **rewrite a remote alarm's
    /// days** for one morning, and something had to put them back. Writing days to a remote alarm is
    /// what turned Alex's real Monday to Friday schedule into every day.
    ///
    /// What changed is that a bend no longer touches the routine's alarm at all, on either leg. It
    /// gets its own alarm. So the routine's day set is not in the question any more, and
    /// `entry.weekdays` staying Monday to Friday is now **correct** rather than a known wrong answer,
    /// because it describes the routine and nothing else. The hard half went away instead of being
    /// solved.
    ///
    /// What has to be right instead is `overrideDay.weekday`, a different field with a different
    /// shift, asserted directly below.
    func testABendAcrossMidnightLeavesTheRoutineDaysAlone() throws {
        let plan = RulesEngine.plan(
            for: bedLead,
            in: schedule(routineAt: WallClockTime(hour: 7, minute: 0),
                         bentTo: WallClockTime(hour: 0, minute: 5)),
            calendar: calendar,
            now: now
        )

        let entry = try XCTUnwrap(plan.entries.first)
        XCTAssertEqual(entry.timeToWrite.hhmm, "23:55", "the bent time crosses midnight correctly")
        XCTAssertEqual(entry.weekdays, Locale.Weekday.weekdaysOnly,
                       "the routine's own days, untouched, because the bend has its own alarm now")
    }

    /// A bend across midnight is armed on the evening before, not on the morning he picked.
    ///
    /// **The half that stopped being cosmetic.** The override's weekday was shifted by the
    /// **routine's** lead for both a bend and a skip, and that was filed as a defect worth only a
    /// wrong day set. Then this field started deciding which single morning gets a real alarm created
    /// on his bed, and which morning is taken off the phone's weekly alarm. A defect's severity is a
    /// property of what reads it, not of the defect.
    ///
    /// The override is on Monday the 18th. The bed's ten minute lead makes a 00:05 bend an alarm at
    /// 23:55, which is **Sunday** evening. Arming Monday would ring a day late, and on a bed the
    /// heating would start a day late with it.
    func testABendAcrossMidnightIsArmedTheEveningBefore() throws {
        let plan = RulesEngine.plan(
            for: bedLead,
            in: schedule(routineAt: WallClockTime(hour: 7, minute: 0),
                         bentTo: WallClockTime(hour: 0, minute: 5)),
            calendar: calendar,
            now: now
        )

        let bend = try XCTUnwrap(try XCTUnwrap(plan.entries.first).overrideDay)
        XCTAssertEqual(bend.date, CalendarDay(year: 2027, month: 1, day: 18),
                       "the date is the morning he chose, and never moves")
        XCTAssertEqual(bend.weekday, .sunday,
                       "but the alarm for it fires on Sunday evening, so that is the day to arm")
    }

    /// A skip across midnight follows the **routine's** shift, not the bend's. The pair to the above.
    ///
    /// A skip suppresses the routine's own alarm for that morning, and that alarm fires at the
    /// routine's time. A routine at 00:05 on a bed with a ten minute lead is a 23:55 alarm the
    /// evening before, so skipping Monday the 18th has to remove Sunday.
    ///
    /// Both tests exist because using one shift for both cases is exactly the bug above, and a single
    /// test cannot tell a correct answer from a coincidence on a fixture where the two shifts agree.
    func testASkipAcrossMidnightFollowsTheRoutinesShift() throws {
        let plan = RulesEngine.plan(
            for: bedLead,
            in: schedule(routineAt: WallClockTime(hour: 0, minute: 5), bentTo: nil),
            calendar: calendar,
            now: now
        )

        let entry = try XCTUnwrap(plan.entries.first)
        XCTAssertEqual(entry.localTime.hhmm, "23:55")
        let skip = try XCTUnwrap(entry.overrideDay,
                                 "a skip carries its day too, or a leg can only stand the whole routine down")
        XCTAssertEqual(skip.weekday, .sunday, "Monday's alarm is armed on Sunday evening")
        XCTAssertTrue(entry.isSkippedNextMorning)
    }

    /// A bend carries the date and weekday it falls on, not just a time.
    ///
    /// Added 18 August, and it is what made the Eight Sleep one-off fixable. `bentTo` says what time
    /// to use and never which morning, so the only thing a service leg could do with it was rewrite
    /// the routine's own alarm, which moves every morning that routine covers. Alex: *"instead of
    /// changing it for one time, it changes the entire Monday to Friday routine on Eight Sleep."*
    ///
    /// With the day carried, the leg can write the override as its own single day alarm and leave the
    /// routine alone.
    func testABendCarriesTheDayItFallsOn() throws {
        let plan = RulesEngine.plan(
            for: bedLead,
            in: schedule(routineAt: WallClockTime(hour: 6, minute: 5),
                         bentTo: WallClockTime(hour: 6, minute: 20)),
            calendar: calendar,
            now: now
        )

        let entry = try XCTUnwrap(plan.entries.first)
        let bend = try XCTUnwrap(entry.overrideDay, "a bend with no day is a bend nothing can write")
        XCTAssertEqual(bend.date, CalendarDay(year: 2027, month: 1, day: 18))
        XCTAssertEqual(bend.weekday, .monday, "the 18th of January 2027 is a Monday")
        XCTAssertEqual(bend.linkKey(routine: "weekdays"), "oneoff:weekdays:20270118",
                       "the key an override's own alarm is filed under, and what expires it")
    }

    /// A routine with **no override at all** carries no day. The control for the two above.
    ///
    /// It used to pass `bentTo: nil` to the fixture, which does not remove the override, it makes it
    /// a **skip**. So it asserted that a skip carries no day, which was true until 18 August and is
    /// now exactly backwards: a skip needs its day as much as a bend does, or a leg can only stand
    /// the whole routine down for the night. Caught by the assertion flipping, which is the only
    /// reason it is not still passing while testing the wrong thing.
    ///
    /// If this ever fails, every routine looks overridden and both legs start carving a day out of
    /// their weekly alarm on every sync.
    func testARoutineWithNoOverrideCarriesNoDay() throws {
        var schedule = WakeSchedule.default
        schedule.routines = [
            Routine(id: "weekdays", name: "Weekdays",
                    weekdayIndices: WeekdaySetCoding.encode(Locale.Weekday.weekdaysOnly),
                    time: WallClockTime(hour: 6, minute: 5)),
        ]
        schedule.override = nil

        let plan = RulesEngine.plan(for: bedLead, in: schedule, calendar: calendar, now: now)

        let entry = try XCTUnwrap(plan.entries.first)
        XCTAssertNil(entry.overrideDay)
        XCTAssertNil(entry.bentTo)
        XCTAssertFalse(entry.isSkippedNextMorning)
    }

    /// An ordinary bend, nowhere near midnight, is unaffected. The control.
    ///
    /// This is the shape Alex can actually produce from the home screen: the minus and plus fifteen
    /// buttons cannot walk a 06:05 routine anywhere near midnight. It needs the picker and a
    /// deliberate near-midnight time, which is why the defect above is filed rather than hotfixed.
    func testAnOrdinaryBendKeepsTheRoutineDays() throws {
        let plan = RulesEngine.plan(
            for: bedLead,
            in: schedule(routineAt: WallClockTime(hour: 6, minute: 5),
                         bentTo: WallClockTime(hour: 6, minute: 20)),
            calendar: calendar,
            now: now
        )

        let entry = try XCTUnwrap(plan.entries.first)
        XCTAssertEqual(entry.localTime.hhmm, "05:55", "the routine, at the bed's lead")
        XCTAssertEqual(entry.timeToWrite.hhmm, "06:10", "the bend, at the bed's lead")
        XCTAssertEqual(entry.weekdays, Locale.Weekday.weekdaysOnly)
    }
}
