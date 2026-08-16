import XCTest
@testable import OneAlarm

/// Which alarms the phone should be holding.
///
/// This is the leg that exists because it needs no account, no network and no server, so it is the
/// one that must never quietly drop a morning. It did, until 17 August: it held a single alarm whose
/// days were those of the routine covering the **next** morning, so a Friday night sync armed
/// Saturday and Sunday and left Monday with nothing.
///
/// `AlarmManager.shared` is an Apple singleton with no seam, so the framework calls cannot be
/// exercised offline and never could be. Everything that **decides** anything can, and does here.
final class AlarmKitReconcilerTests: XCTestCase {

    private func entry(
        _ id: String,
        _ days: Set<Locale.Weekday>,
        hour: Int,
        bentTo: WallClockTime? = nil,
        isOn: Bool = true,
        skipped: Bool = false,
        on day: Locale.Weekday? = nil
    ) -> RoutinePlan.Entry {
        RoutinePlan.Entry(
            routineID: id, routineName: id, weekdays: days,
            localTime: WallClockTime(hour: hour, minute: 0), bentTo: bentTo,
            isOn: isOn, isSkippedNextMorning: skipped,
            // The date is never read by the reconciler, only the weekday, so one fixed Monday
            // serves every case here. `RulesEngine` is where the date has to be right, and
            // `BendDayShiftTests` is where that is asserted.
            overrideDay: day.map {
                RoutinePlan.OverrideDay(date: CalendarDay(year: 2027, month: 1, day: 18), weekday: $0)
            }
        )
    }

    private func plan(_ entries: [RoutinePlan.Entry], skips: Bool = false) -> RoutinePlan {
        RoutinePlan(device: .iphone, entries: entries, skipsNextMorning: skips)
    }

    private func target(_ days: Set<Locale.Weekday>, hour: Int = 7) -> ResolvedTarget {
        ResolvedTarget(
            device: .iphone,
            localTime: WallClockTime(hour: hour, minute: 0),
            weekdays: days,
            dayShift: 0,
            nextOccurrence: Date(timeIntervalSince1970: 1_800_000_000),
            utcOffsetSeconds: 3600
        )
    }

    private let weekdays = Locale.Weekday.weekdaysOnly
    private let weekend: Set<Locale.Weekday> = [.saturday, .sunday]

    /// The bug, stated as a test.
    ///
    /// Two routines means two alarms, so Monday is armed on a Friday night rather than waiting for
    /// him to sync again on the Sunday.
    func testEveryRoutineGetsItsOwnAlarm() {
        let outcome = AlarmKitReconciler.reconcile(
            plan: plan([entry("weekdays", weekdays, hour: 7), entry("weekend", weekend, hour: 9)]),
            target: target(weekend, hour: 9),
            held: []
        )

        XCTAssertEqual(outcome.schedule.count, 2)
        XCTAssertEqual(outcome.schedule.first { $0.key == "weekdays" }?.weekdays, weekdays)
        XCTAssertEqual(outcome.schedule.first { $0.key == "weekend" }?.time.hhmm, "09:00")
        XCTAssertTrue(outcome.cancel.isEmpty)
    }

    /// A routine deleted or switched off has its alarm cancelled, rather than left ringing.
    func testAnAlarmWithNoLiveRoutineIsCancelled() {
        let outcome = AlarmKitReconciler.reconcile(
            plan: plan([entry("weekdays", weekdays, hour: 7)]),
            target: target(weekdays),
            held: ["weekdays", "weekend"]
        )

        XCTAssertEqual(outcome.schedule.map(\.key), ["weekdays"])
        XCTAssertEqual(outcome.cancel, ["weekend"])
    }

    func testASwitchedOffRoutineIsNotArmed() {
        let outcome = AlarmKitReconciler.reconcile(
            plan: plan([entry("weekdays", weekdays, hour: 7, isOn: false)]),
            target: target(weekdays),
            held: ["weekdays"]
        )

        XCTAssertTrue(outcome.schedule.isEmpty)
        XCTAssertEqual(outcome.cancel, ["weekdays"])
    }

    /// A routine emptied of days arms nothing, and its old alarm goes.
    func testARoutineWithNoDaysArmsNothing() {
        let outcome = AlarmKitReconciler.reconcile(
            plan: plan([entry("weekdays", [], hour: 7)]),
            target: target(weekdays),
            held: ["weekdays"]
        )

        XCTAssertTrue(outcome.schedule.isEmpty)
        XCTAssertEqual(outcome.cancel, ["weekdays"])
    }

    /// A bend splits its routine in two, and leaves every other routine armed.
    ///
    /// **This test asserted the opposite until 18 August.** It pinned the old behaviour, where a bend
    /// stood every routine alarm down and armed one alarm for the bent morning. That was written up
    /// as a deliberate narrowing, which it was, and it was still a silent missed morning on the leg
    /// that exists because it needs no account, no network and no server.
    ///
    /// AlarmKit offers `.never` and `.weekly` and nothing in between, so "this Saturday and not every
    /// Saturday" is not expressible as one alarm. It is expressible as **two**, which is what this
    /// does now: the weekend routine keeps Sunday at its own time, and Saturday is armed separately
    /// at the bent time.
    func testABendSplitsItsRoutineAndLeavesTheOthersAlone() {
        let outcome = AlarmKitReconciler.reconcile(
            plan: plan([
                entry("weekdays", weekdays, hour: 7),
                entry("weekend", weekend, hour: 9,
                      bentTo: WallClockTime(hour: 10, minute: 0), on: .saturday),
            ]),
            target: target([.saturday], hour: 10),
            held: ["weekdays", "weekend"]
        )

        XCTAssertEqual(outcome.schedule.count, 3)
        XCTAssertEqual(outcome.schedule.first { $0.key == "weekdays" }?.weekdays, weekdays,
                       "the routine nothing happened to is untouched, and Monday stays armed")
        let bentRoutine = outcome.schedule.first { $0.key == "weekend" }
        XCTAssertEqual(bentRoutine?.weekdays, [.sunday], "Saturday is handled separately")
        XCTAssertEqual(bentRoutine?.time.hhmm, "09:00", "and Sunday keeps the routine's own time")
        let override = outcome.schedule.first { $0.key == AlarmKitReconciler.overrideKey }
        XCTAssertEqual(override?.weekdays, [.saturday])
        XCTAssertEqual(override?.time.hhmm, "10:00")
        XCTAssertEqual(outcome.cancel, [], "nothing has to be stood down any more")
    }

    /// A bend days away no longer costs the rest of the week.
    ///
    /// **The failure this change is really about.** `isBent` means "this routine has an override
    /// somewhere ahead", not "tomorrow". Bending next Saturday from a Monday used to stand every
    /// routine alarm down until the sync after it expired, so Monday to Friday had no phone alarm at
    /// all. Pinned as known behaviour rather than fixed, which is why it survived a day longer than
    /// it should have.
    func testABendDaysAwayLeavesTheRestOfTheWeekArmed() {
        let outcome = AlarmKitReconciler.reconcile(
            plan: plan([
                entry("weekdays", weekdays, hour: 7),
                entry("weekend", weekend, hour: 9,
                      bentTo: WallClockTime(hour: 10, minute: 0), on: .saturday),
            ]),
            // The next morning is an ordinary weekday: the bend is days off.
            target: target(weekdays, hour: 7),
            held: ["weekdays", "weekend"]
        )

        XCTAssertEqual(outcome.schedule.first { $0.key == "weekdays" }?.weekdays, weekdays,
                       "every weekday morning is still armed while a weekend bend waits")
        XCTAssertEqual(outcome.cancel, [])
    }

    /// A one day routine bent on its only day arms just the override.
    ///
    /// The edge the split has to handle: subtracting the bent day leaves the routine with no days,
    /// and a weekly alarm with an empty day set never fires. Arming it would be harmless and
    /// confusing; the override alarm already covers that morning completely.
    func testARoutineBentOnItsOnlyDayArmsOnlyTheOverride() {
        let outcome = AlarmKitReconciler.reconcile(
            plan: plan([
                entry("sat", [.saturday], hour: 9,
                      bentTo: WallClockTime(hour: 10, minute: 0), on: .saturday),
            ]),
            target: target([.saturday], hour: 10),
            held: ["sat"]
        )

        XCTAssertEqual(outcome.schedule.count, 1)
        XCTAssertEqual(outcome.schedule.first?.key, AlarmKitReconciler.overrideKey)
        XCTAssertEqual(outcome.schedule.first?.time.hhmm, "10:00")
        XCTAssertEqual(outcome.cancel, ["sat"])
    }

    /// When the bend expires, the routine gets its day back and the override's alarm goes.
    func testTheBendAlarmIsCancelledOnceItExpires() {
        let outcome = AlarmKitReconciler.reconcile(
            plan: plan([entry("weekdays", weekdays, hour: 7), entry("weekend", weekend, hour: 9)]),
            target: target(weekdays),
            held: [AlarmKitReconciler.overrideKey, "weekdays"]
        )

        XCTAssertEqual(Set(outcome.schedule.map(\.key)), ["weekdays", "weekend"])
        XCTAssertEqual(outcome.schedule.first { $0.key == "weekend" }?.weekdays, weekend,
                       "Saturday is back on the routine that owns it")
        XCTAssertEqual(outcome.cancel, [AlarmKitReconciler.overrideKey])
    }

    /// A skip removes one morning and arms every other one the routine covers.
    ///
    /// Same split as a bend with the second half left off. This used to stand the whole routine down
    /// and arm a single alarm for whatever came next, so skipping one Monday left Tuesday to Friday
    /// resting on him syncing again before Tuesday morning.
    func testASkipRemovesOneMorningAndKeepsTheRest() {
        let outcome = AlarmKitReconciler.reconcile(
            plan: plan([entry("weekdays", weekdays, hour: 7, skipped: true, on: .monday)], skips: true),
            target: target([.tuesday]),
            held: ["weekdays"]
        )

        XCTAssertEqual(outcome.schedule.count, 1)
        XCTAssertEqual(outcome.schedule.first?.key, "weekdays")
        XCTAssertEqual(outcome.schedule.first?.weekdays, [.tuesday, .wednesday, .thursday, .friday],
                       "Monday off, and the other four still armed")
        XCTAssertEqual(outcome.cancel, [])
    }

    /// A skip that arrives without a day stands the routine down, which is the safe direction.
    ///
    /// Belt and braces for a state the rules engine should not produce. Suppressing four mornings he
    /// wanted is recoverable by opening the app; ringing on a morning he cleared is not.
    func testASkipWithNoDayStandsTheRoutineDown() {
        let outcome = AlarmKitReconciler.reconcile(
            plan: plan([entry("weekdays", weekdays, hour: 7, skipped: true)], skips: true),
            target: target([.tuesday]),
            held: ["weekdays"]
        )

        XCTAssertEqual(outcome.schedule, [])
        XCTAssertEqual(outcome.cancel, ["weekdays"])
    }

    /// An empty plan arms the target, which is exactly what this leg did before the change.
    ///
    /// `write(_ target:)` with no plan is the protocol's own entry point. Making it arm nothing
    /// would turn "no plan supplied" into no alarm at all, on the leg that exists to always ring.
    /// That is a worse bug than the one this file was written to fix.
    func testAnEmptyPlanStillArmsTheTarget() {
        let outcome = AlarmKitReconciler.reconcile(
            plan: plan([]), target: target(weekdays), held: []
        )

        XCTAssertEqual(outcome.schedule.count, 1)
        XCTAssertEqual(outcome.schedule.first?.weekdays, weekdays)
        XCTAssertEqual(outcome.schedule.first?.time.hhmm, "07:00")
    }
}
