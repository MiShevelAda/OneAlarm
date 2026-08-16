import XCTest
@testable import OneAlarm

/// Adding and deleting a routine, which nothing tested until now.
///
/// Both were written on 16 August and both reach further than they look. A routine's id is what
/// `RemoteAlarmLink` keys ownership on, so getting it wrong puts two routines in charge of one alarm
/// on his bed. Deleting a routine is what makes the Eight Sleep leg switch an alarm off, so it is one
/// step from the only destructive thing this app does.
@MainActor
final class RoutineEditingTests: XCTestCase {

    private func store(_ routines: [Routine]) -> ScheduleStore {
        var schedule = WakeSchedule.default
        schedule.routines = routines
        return ScheduleStore(schedule: schedule)
    }

    private func routine(_ id: String, _ days: Set<Locale.Weekday>, hour: Int = 7) -> Routine {
        Routine(
            id: id, name: "",
            weekdayIndices: WeekdaySetCoding.encode(days),
            time: WallClockTime(hour: hour, minute: 0)
        )
    }

    /// The defect this file was written for.
    ///
    /// The id used to be `Int(Date().timeIntervalSince1970)`, so two taps of Add inside one second
    /// produced two routines with the same id. That is one second apart on a button that sits right
    /// there, and a duplicate id means both routines own the same alarm, the second one's day chips
    /// silently edit the first, deleting one deletes both, and SwiftUI drops a row.
    func testTwoRoutinesAddedBackToBackGetDifferentIDs() {
        let subject = store([])

        let first = subject.addRoutine()
        let second = subject.addRoutine()

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Set(subject.schedule.routines.map(\.id)).count,
                       subject.schedule.routines.count,
                       "every routine id has to be unique: ownership is keyed on it")
    }

    /// A new routine takes the days nothing covers yet.
    ///
    /// Rather than starting empty, which is a card that does nothing until it is filled in, and
    /// rather than taking a day from a routine he did not open.
    func testANewRoutineTakesTheUncoveredDays() {
        let subject = store([routine("weekdays", Locale.Weekday.weekdaysOnly)])

        let id = subject.addRoutine()
        let added = subject.schedule.routines.first { $0.id == id }

        XCTAssertEqual(added?.weekdays, [.saturday, .sunday])
    }

    /// When the week is already covered, the new routine starts with no days and says so, rather
    /// than taking a day from a routine he did not open.
    func testAFullyCoveredWeekGivesTheNewRoutineNoDays() {
        let subject = store([routine("all", Locale.Weekday.everyDay)])

        let id = subject.addRoutine()

        XCTAssertEqual(subject.schedule.routines.first { $0.id == id }?.weekdays, [])
        XCTAssertEqual(subject.schedule.routines.first { $0.id == "all" }?.weekdays,
                       Locale.Weekday.everyDay,
                       "the routine he did not open keeps every one of its days")
    }

    /// Deleting one routine deletes one routine.
    func testDeletingARoutineLeavesTheOthersAlone() {
        let subject = store([
            routine("weekdays", Locale.Weekday.weekdaysOnly),
            routine("weekend", [.saturday, .sunday], hour: 9),
        ])

        subject.deleteRoutine("weekend")

        XCTAssertEqual(subject.schedule.routines.map(\.id), ["weekdays"])
        XCTAssertEqual(subject.schedule.routines.first?.weekdays, Locale.Weekday.weekdaysOnly)
    }

    /// Its days become uncovered and are named, rather than being handed to a neighbour.
    ///
    /// Deleting the weekend routine must not quietly make Saturday a 07:00 workday. A day with no
    /// alarm is a state this app prints by name.
    func testDeletedDaysAreLeftUncoveredRatherThanAbsorbed() {
        let subject = store([
            routine("weekdays", Locale.Weekday.weekdaysOnly),
            routine("weekend", [.saturday, .sunday], hour: 9),
        ])

        subject.deleteRoutine("weekend")

        let uncovered = subject.uncoveredDays
        XCTAssertNotNil(uncovered)
        XCTAssertTrue(uncovered?.contains("Sat") ?? false)
        XCTAssertTrue(uncovered?.contains("Sun") ?? false)
    }

    /// A bend armed on a day the deleted routine covered has nothing left to bend away from.
    ///
    /// Left in place it would be an override pointing at a routine that no longer exists, and the
    /// screen would offer to make it permanent on nothing.
    func testDeletingARoutineClearsABendThatBelongedToIt() {
        let calendar = Calendar(identifier: .gregorian)
        let subject = store([
            routine("weekdays", Locale.Weekday.weekdaysOnly),
            routine("weekend", [.saturday, .sunday], hour: 9),
        ])

        // Bend whichever morning is next, then delete the routine that covers it.
        guard let next = subject.next else { return XCTFail("no next alarm to bend") }
        subject.bendNextMorning(to: WallClockTime(hour: 10, minute: 0))
        XCTAssertNotNil(subject.schedule.override)

        let owning = Locale.Weekday.displayOrder.first { $0 == next.weekday }
        let covering = subject.schedule.routines.first { owning.map($0.weekdays.contains) ?? false }
        subject.deleteRoutine(covering?.id ?? "weekend")

        _ = calendar
        XCTAssertNil(subject.schedule.override,
                     "an override whose routine is gone points at nothing")
    }
}
