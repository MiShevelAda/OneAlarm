import XCTest
@testable import OneAlarm

/// Which time gets struck through while a one-off is armed.
///
/// **Why three strings are worth a test file.** On 17 August the screen said *"Tomorrow only.
/// Weekdays is still 06:01 and returns after"* directly above a week list showing Weekdays at
/// **07:01**. Both numbers came from this app, an hour apart, and the wrong one was on the sentence
/// whose entire job is telling him what he goes back to. Nothing caught it because nothing asserted
/// it.
///
/// The display was then rebuilt in the shape Alex asked for, pointing at Eight Sleep's own screen:
/// `UPCOMING ALARM ONLY  09:10  0̶9̶:̶3̶0̶`. A struck-through number cannot be misread, which is most of
/// why it is better. But it can be **stale**, or **absent**, or **shown when it should not be**, and
/// those are the three ways it can still go wrong.
///
/// Tests the pure `struckThrough` rather than the property that calls it. `ScheduleStore` reads the
/// wall clock through a private `calendar` with no seam, so anything depending on `next` cannot be
/// asserted deterministically. The logic that broke does not need the clock, and was pulled out
/// precisely so it could be pinned here.
final class OneOffDisplayTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich") ?? .current
        return calendar
    }

    /// Saturday 16 January 2027.
    private let saturday = CalendarDay(year: 2027, month: 1, day: 16)

    private func weekendRoutine(at time: WallClockTime) -> Routine {
        Routine(id: "weekend", name: "Weekend",
                weekdayIndices: WeekdaySetCoding.encode([.saturday, .sunday]),
                time: time)
    }

    private func bend(to time: WallClockTime?, snapshot: WallClockTime?) -> DayOverride {
        DayOverride(day: saturday, time: time, routineTime: snapshot, routineName: "Weekend")
    }

    // MARK: A bend

    func testABendOffersTheRoutineTimeToStrikeThrough() {
        let was = ScheduleStore.struckThrough(
            override: bend(to: WallClockTime(hour: 9, minute: 10),
                           snapshot: WallClockTime(hour: 9, minute: 30)),
            routines: [weekendRoutine(at: WallClockTime(hour: 9, minute: 30))],
            showing: WallClockTime(hour: 9, minute: 10),
            calendar: calendar
        )

        XCTAssertEqual(was, WallClockTime(hour: 9, minute: 30))
    }

    /// **The 17 August bug, pinned.** The snapshot goes stale the moment he edits the routine while a
    /// bend is armed, and the screen must show the live routine rather than it.
    ///
    /// The snapshot is not wrong and is not removed: `restoreAfterOverride` needs it to put the right
    /// value back. It just must never be the number on screen.
    func testTheStruckThroughTimeIsLiveRatherThanTheStaleSnapshot() {
        let was = ScheduleStore.struckThrough(
            override: bend(to: WallClockTime(hour: 9, minute: 10),
                           // Captured when the bend was made.
                           snapshot: WallClockTime(hour: 9, minute: 30)),
            // He has since edited the routine to 11:00.
            routines: [weekendRoutine(at: WallClockTime(hour: 11, minute: 0))],
            showing: WallClockTime(hour: 9, minute: 10),
            calendar: calendar
        )

        XCTAssertEqual(was, WallClockTime(hour: 11, minute: 0),
                       "what he goes back to is what the routine says now, not what it said then")
        XCTAssertNotEqual(was, WallClockTime(hour: 9, minute: 30))
    }

    /// The snapshot is still the fallback when no live routine covers that day any more.
    ///
    /// He can delete the routine while its bend is armed. Falling back to nil there would leave the
    /// screen with a bent time and nothing to compare it against.
    func testTheSnapshotIsUsedWhenTheRoutineIsGone() {
        let was = ScheduleStore.struckThrough(
            override: bend(to: WallClockTime(hour: 9, minute: 10),
                           snapshot: WallClockTime(hour: 9, minute: 30)),
            routines: [],
            showing: WallClockTime(hour: 9, minute: 10),
            calendar: calendar
        )

        XCTAssertEqual(was, WallClockTime(hour: 9, minute: 30))
    }

    /// Nothing is struck through when the bend landed on the routine's own time.
    ///
    /// Two identical numbers side by side, one with a line through it, reads as a bug rather than as
    /// information, and he would be right to read it that way.
    func testNothingIsStruckThroughWhenTheBendChangedNothing() {
        let was = ScheduleStore.struckThrough(
            override: bend(to: WallClockTime(hour: 9, minute: 30),
                           snapshot: WallClockTime(hour: 9, minute: 30)),
            routines: [weekendRoutine(at: WallClockTime(hour: 9, minute: 30))],
            showing: WallClockTime(hour: 9, minute: 30),
            calendar: calendar
        )

        XCTAssertNil(was)
    }

    /// A routine switched off does not supply the comparison.
    ///
    /// An off routine is not what he goes back to, so striking its time through would name a morning
    /// that is not coming.
    func testASwitchedOffRoutineIsNotTheComparison() {
        var off = weekendRoutine(at: WallClockTime(hour: 11, minute: 0))
        off.isOn = false

        let was = ScheduleStore.struckThrough(
            override: bend(to: WallClockTime(hour: 9, minute: 10),
                           snapshot: WallClockTime(hour: 9, minute: 30)),
            routines: [off],
            showing: WallClockTime(hour: 9, minute: 10),
            calendar: calendar
        )

        XCTAssertEqual(was, WallClockTime(hour: 9, minute: 30), "falls back to the snapshot")
    }

    // MARK: A skip

    /// A skip has no replacement time, so there is nothing to strike through.
    ///
    /// A bend replaces the next morning, so the big number **is** that morning. A skip removes it, so
    /// the big number has already moved to the morning after and comparing it to anything would be
    /// comparing two different days.
    func testASkipStrikesNothingThrough() {
        let was = ScheduleStore.struckThrough(
            override: bend(to: nil, snapshot: WallClockTime(hour: 9, minute: 30)),
            routines: [weekendRoutine(at: WallClockTime(hour: 9, minute: 30))],
            showing: WallClockTime(hour: 7, minute: 0),
            calendar: calendar
        )

        XCTAssertNil(was)
    }
}
