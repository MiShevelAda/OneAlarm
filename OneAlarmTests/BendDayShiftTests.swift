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
/// **When it is fixed**, `testABendAcrossMidnightDoesNotShiftItsDays` is the test that must flip, and
/// `testTheRoutinesOwnMidnightCrossingStillShifts` is the one that must not. Both are here so that
/// whoever fixes it can tell those two apart, which is the thing a bare bug report never gives you.
final class BendDayShiftTests: XCTestCase {

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

    /// **Pins the defect.** A bend across midnight keeps the routine's unshifted days.
    ///
    /// Routine at 07:00, so `dayShift` is 0 and the days stay Monday to Friday. Bent to 00:05, which
    /// the bed's ten minute lead makes 23:55, an evening alarm. The correct day set for 23:55 is the
    /// evening before, Sunday to Thursday. It is not what comes out.
    func testABendAcrossMidnightDoesNotShiftItsDays() throws {
        let plan = RulesEngine.plan(
            for: bedLead,
            in: schedule(routineAt: WallClockTime(hour: 7, minute: 0),
                         bentTo: WallClockTime(hour: 0, minute: 5)),
            calendar: calendar,
            now: now
        )

        let entry = try XCTUnwrap(plan.entries.first)
        XCTAssertEqual(entry.timeToWrite.hhmm, "23:55", "the bent time crosses midnight correctly")
        XCTAssertEqual(
            entry.weekdays,
            Locale.Weekday.weekdaysOnly,
            """
            KNOWN DEFECT, docs/STATUS.md problem 1. The days follow the routine's 07:00, not the \
            23:55 actually being written, so the bed is armed about a day early. When this is fixed \
            this assertion flips to Sunday to Thursday and the fix must also put the days back once \
            the bend expires, which is the hard half.
            """
        )
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
        let bend = try XCTUnwrap(entry.bendDay, "a bend with no day is a bend nothing can write")
        XCTAssertEqual(bend.date, CalendarDay(year: 2027, month: 1, day: 18))
        XCTAssertEqual(bend.weekday, .monday, "the 18th of January 2027 is a Monday")
        XCTAssertEqual(bend.linkKey(routine: "weekdays"), "oneoff:weekdays:20270118",
                       "the key an override's own alarm is filed under, and what expires it")
    }

    /// A routine with no bend carries no day. The control for the one above.
    ///
    /// If this ever fails, every routine looks bent and the Eight Sleep leg starts adding an override
    /// alarm on every sync.
    func testAnUnbentRoutineCarriesNoDay() throws {
        let plan = RulesEngine.plan(
            for: bedLead,
            in: schedule(routineAt: WallClockTime(hour: 6, minute: 5), bentTo: nil),
            calendar: calendar,
            now: now
        )

        XCTAssertNil(try XCTUnwrap(plan.entries.first).bendDay)
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
