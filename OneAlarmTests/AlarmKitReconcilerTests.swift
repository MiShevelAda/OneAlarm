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
        skipped: Bool = false
    ) -> RoutinePlan.Entry {
        RoutinePlan.Entry(
            routineID: id, routineName: id, weekdays: days,
            localTime: WallClockTime(hour: hour, minute: 0), bentTo: bentTo,
            isOn: isOn, isSkippedNextMorning: skipped
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

    /// A bend keeps the old single-alarm behaviour, on purpose.
    ///
    /// AlarmKit offers `.never` and `.weekly` and nothing between, so "this Saturday and not every
    /// Saturday" is not expressible. The rules engine has already reduced the target to the one
    /// weekday the bend falls on, and every routine alarm stands down so the bend cannot be
    /// shouted over by the routine it displaces.
    func testABendArmsOneMorningAndStandsTheRoutinesDown() {
        let outcome = AlarmKitReconciler.reconcile(
            plan: plan([
                entry("weekdays", weekdays, hour: 7),
                entry("weekend", weekend, hour: 9, bentTo: WallClockTime(hour: 10, minute: 0)),
            ]),
            target: target([.saturday], hour: 10),
            held: ["weekdays", "weekend"]
        )

        XCTAssertEqual(outcome.schedule.count, 1)
        XCTAssertEqual(outcome.schedule.first?.key, AlarmKitReconciler.overrideKey)
        XCTAssertEqual(outcome.schedule.first?.time.hhmm, "10:00")
        XCTAssertEqual(outcome.schedule.first?.weekdays, [.saturday])
        XCTAssertEqual(outcome.cancel, ["weekdays", "weekend"])
    }

    /// When the bend expires, the routines come back and the bend's alarm goes.
    func testTheBendAlarmIsCancelledOnceItExpires() {
        let outcome = AlarmKitReconciler.reconcile(
            plan: plan([entry("weekdays", weekdays, hour: 7), entry("weekend", weekend, hour: 9)]),
            target: target(weekdays),
            held: [AlarmKitReconciler.overrideKey, "weekdays"]
        )

        XCTAssertEqual(Set(outcome.schedule.map(\.key)), ["weekdays", "weekend"])
        XCTAssertEqual(outcome.cancel, [AlarmKitReconciler.overrideKey])
    }

    /// A bend days away still collapses this leg to one alarm, and that is known rather than hidden.
    ///
    /// `isBent` means "this routine has a bend somewhere ahead", not "on the next morning". Bending
    /// next Saturday from a Monday therefore stands every routine alarm down for the rest of the
    /// week. It is what this leg did for every morning before 17 August, so it is a narrowing rather
    /// than a regression, and the nightly Set covers it. Pinned here so the day somebody narrows it
    /// properly, this test is what tells them the behaviour changed on purpose.
    func testABendDaysAwayStillCollapsesToASingleAlarm() {
        let outcome = AlarmKitReconciler.reconcile(
            plan: plan([
                entry("weekdays", weekdays, hour: 7),
                entry("weekend", weekend, hour: 9, bentTo: WallClockTime(hour: 10, minute: 0)),
            ]),
            // The next morning is an ordinary weekday: the bend is days off.
            target: target(weekdays, hour: 7),
            held: ["weekdays", "weekend"]
        )

        XCTAssertEqual(outcome.schedule.count, 1)
        XCTAssertEqual(outcome.schedule.first?.weekdays, weekdays,
                       "it arms the target, so the week is still covered, just by one alarm")
        XCTAssertEqual(outcome.cancel, ["weekdays", "weekend"])
    }

    /// A skip arms whatever the rules engine says is next, which is past the skipped morning.
    func testASkipArmsTheMorningAfterIt() {
        let outcome = AlarmKitReconciler.reconcile(
            plan: plan([entry("weekdays", weekdays, hour: 7)], skips: true),
            target: target([.tuesday]),
            held: ["weekdays"]
        )

        XCTAssertEqual(outcome.schedule.first?.key, AlarmKitReconciler.overrideKey)
        XCTAssertEqual(outcome.schedule.first?.weekdays, [.tuesday])
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
