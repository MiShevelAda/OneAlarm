import XCTest
@testable import OneAlarm

/// What happens to the bed and the strap when a bend or a skip runs out.
///
/// **The hazard, in one paragraph.** A skip is expressed on Eight Sleep by switching the covering
/// routine's alarm **off**, because an alarm object has no way to say "not this one Tuesday". That is
/// correct while the skip is live and wrong the moment it expires: the routine is back, the bed's
/// alarm is still off, and it is off for every weekday rather than the one he skipped.
///
/// The phone protects itself. `phoneNeedsRearm` fires on the next foreground and re-arms it locally,
/// which is safe precisely because it needs no account and no network. The two remote legs
/// deliberately do not do that, because an unattended write to a live account is a different act.
/// See the note on `phoneNeedsRearm`.
///
/// So the remote legs need Alex to press Set all alarms, and until 17 August **nothing told him so**.
/// `needsApply` is set on every edit, and an expiring override is the one case where the plan changes
/// without him touching anything. The banner said "Last set 14:21" in calm grey while his bed sat
/// switched off.
@MainActor
final class OverrideExpiryTests: XCTestCase {

    /// His real routines, put back after every test in this class.
    ///
    /// **This nearly repeated the most expensive mistake in the project.** `ScheduleStore.init`
    /// calls `recompute`, which purges an expired override and then **persists**, to
    /// `UserDefaults.standard` under `OneAlarm.schedule.v2`. XCTest runs inside the app, so that is
    /// the same defaults store the real app reads. Constructing a store here with `WakeSchedule
    /// .default` and letting it persist would have replaced Alex's Weekdays 06:05 and Weekend 10:05
    /// with the shipped defaults of 07:00 and 09:00, on his own phone, the moment he pressed Cmd+U.
    ///
    /// `docs/LEARNED.md` already carries this rule, learned when a Whoop ring test rewrote his real
    /// schedule to every day: **a test that mutates a live account is a change.** It says restore
    /// first, and this is what restoring looks like when the account is a phone.
    private var savedSchedule: Data?

    override func setUp() {
        super.setUp()
        savedSchedule = UserDefaults.standard.data(forKey: "OneAlarm.schedule.v2")
    }

    override func tearDown() {
        if let savedSchedule {
            UserDefaults.standard.set(savedSchedule, forKey: "OneAlarm.schedule.v2")
        } else {
            // He had none, so leaving one behind is also a change.
            UserDefaults.standard.removeObject(forKey: "OneAlarm.schedule.v2")
        }
        super.tearDown()
    }

    private var yesterday: CalendarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return CalendarDay(Date().addingTimeInterval(-86_400), in: calendar)
    }

    private func store(with override: DayOverride?) -> ScheduleStore {
        var schedule = WakeSchedule.default
        schedule.override = override
        // `init` calls `recompute`, which is where the purge runs.
        return ScheduleStore(schedule: schedule)
    }

    /// An expired **skip** leaves the remote legs holding a switched-off alarm, and says so.
    func testAnExpiredSkipAsksToBeReapplied() {
        let subject = store(with: DayOverride(day: yesterday, time: nil,
                                             routineTime: WallClockTime(hour: 7, minute: 0),
                                             routineName: "Weekdays"))

        XCTAssertNil(subject.schedule.override, "an override for a past day can never fire again")
        XCTAssertTrue(subject.phoneNeedsRearm, "the phone re-arms itself, locally, with no request")
        XCTAssertTrue(
            subject.needsApply,
            "and the bed is still switched off, so the screen has to say it is out of date"
        )
    }

    /// An expired **bend** is the same shape: the bed still holds yesterday's one-off time.
    func testAnExpiredBendAsksToBeReapplied() {
        let subject = store(with: DayOverride(day: yesterday,
                                             time: WallClockTime(hour: 8, minute: 30),
                                             routineTime: WallClockTime(hour: 7, minute: 0),
                                             routineName: "Weekdays"))

        XCTAssertNil(subject.schedule.override)
        XCTAssertTrue(subject.needsApply, "the bed is holding 08:30 and the routine says 07:00")
    }

    /// A **live** override is not an out-of-date one. Without this the banner would be permanent,
    /// and a banner that is always on is a banner nobody reads.
    func testALiveOverrideDoesNotAskToBeReapplied() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let tomorrow = CalendarDay(Date().addingTimeInterval(86_400), in: calendar)

        let subject = store(with: DayOverride(day: tomorrow,
                                             time: WallClockTime(hour: 8, minute: 30),
                                             routineTime: WallClockTime(hour: 7, minute: 0),
                                             routineName: "Weekdays"))

        XCTAssertNotNil(subject.schedule.override)
        XCTAssertFalse(subject.phoneNeedsRearm)
        XCTAssertFalse(subject.needsApply, "nothing has expired, so nothing is out of date")
    }

    /// And no override at all is quiet. The negative control for the two above.
    func testNoOverrideIsQuiet() {
        let subject = store(with: nil)

        XCTAssertFalse(subject.phoneNeedsRearm)
        XCTAssertFalse(subject.needsApply)
    }
}
