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
        bentTo: WallClockTime? = nil,
        isOn: Bool = true,
        skipped: Bool = false
    ) -> RoutinePlan.Entry {
        RoutinePlan.Entry(
            routineID: id,
            routineName: id,
            weekdays: days,
            localTime: WallClockTime(hour: hour, minute: minute),
            bentTo: bentTo,
            isOn: isOn,
            isSkippedNextMorning: skipped
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
    // MARK: Merging and splitting routines, which is where the model was said to fall over

    /// **Merging two routines into one keeps the survivor's alarm, and does not strand it.**
    ///
    /// `LEARNED.md` and `STATUS.md` both record this case as broken: *"merged Weekdays and Weekend
    /// into Every day: both real alarms orphaned, still ringing, and a third about to be created."*
    /// That was written before ownership was recorded in `RemoteAlarmLink`, and the notes were never
    /// revisited afterwards.
    ///
    /// Written to find out which is true rather than to confirm either. If the link survives a day
    /// set change, the survivor keeps its alarm and the note is stale.
    func testMergingTwoRoutinesKeepsTheSurvivorsAlarm() {
        // He merged Weekdays and Weekend into one "Every day" routine, keeping the weekday routine's
        // identity. Its days are now all seven, which match neither alarm on the bed.
        let everyDay = entry("weekdays", Locale.Weekday.everyDay, at: 7)

        let report = RoutinePlan.match(
            entries: [everyDay],
            against: [
                weekdayAlarm,
                weekendAlarm,
            ],
            // The link recorded when this routine first adopted its alarm.
            links: ["weekdays": "a1"]
        )

        XCTAssertEqual(report.pairs.count, 1, "the link survives a day set that matches nothing")
        XCTAssertEqual(report.pairs.first?.alarmID, "a1")
        XCTAssertEqual(report.pairs.first?.weekdays, Locale.Weekday.everyDay,
                       "and the alarm's days are rewritten to the merged routine's")
        XCTAssertTrue(report.routinesWithNoAlarm.isEmpty,
                      "so nothing is created for a routine that already owns an alarm")
    }

    /// The other routine's alarm is left for the caller to clear, and is named.
    ///
    /// It is not silently adopted by the survivor and it is not silently deleted. Its link is an
    /// orphan, which the adapter resolves by provenance: deleted if OneAlarm made it, switched off if
    /// he did. What `match` must not do is pretend it is not there.
    func testTheMergedAwayAlarmIsNotAdoptedBySomebodyElse() {
        let everyDay = entry("weekdays", Locale.Weekday.everyDay, at: 7)

        let report = RoutinePlan.match(
            entries: [everyDay],
            against: [
                weekdayAlarm,
                weekendAlarm,
            ],
            // Both links still exist: the weekend routine has gone from OneAlarm, not from the bed.
            links: ["weekdays": "a1", "weekend": "a2"]
        )

        XCTAssertEqual(report.pairs.map(\.alarmID), ["a1"])
        XCTAssertFalse(report.alarmsWithNoRoutine.contains { $0.contains("Sat") },
                       "an alarm OneAlarm still owns is not reported as somebody else's")
    }

    /// **Narrowing a routine's days keeps its alarm rather than stranding it.**
    ///
    /// The second failure in the same note: *"narrowing a routine's days strands the alarm that had
    /// served it for weeks."* Same question, same answer if the link is doing its job.
    func testNarrowingARoutinesDaysKeepsItsAlarm() {
        let narrowed = entry("weekdays", [.monday, .tuesday, .wednesday], at: 7)

        let report = RoutinePlan.match(
            entries: [narrowed],
            against: [weekdayAlarm],
            links: ["weekdays": "a1"]
        )

        XCTAssertEqual(report.pairs.first?.alarmID, "a1")
        XCTAssertEqual(report.pairs.first?.weekdays, [.monday, .tuesday, .wednesday],
                       "the owned alarm is reshaped, which is the whole point of recording ownership")
    }

    /// And with no link, a changed day set correctly finds nothing. The control.
    ///
    /// This is the behaviour the notes describe, and it is right for an alarm nobody owns yet. The
    /// bug was never that matching is strict; it was that a link should stop matching being consulted
    /// at all.
    func testWithoutALinkAChangedDaySetMatchesNothing() {
        let narrowed = entry("weekdays", [.monday, .tuesday, .wednesday], at: 7)

        let report = RoutinePlan.match(
            entries: [narrowed],
            against: [weekdayAlarm],
            links: [:]
        )

        XCTAssertTrue(report.pairs.isEmpty)
        XCTAssertEqual(report.routinesWithNoAlarm, ["weekdays"])
    }

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

    /// **One routine adopts exactly one alarm, and the twin is left alone.**
    ///
    /// This test used to assert the opposite, that every alarm with matching days is moved, on the
    /// reasoning that they are all his and leaving one behind produces two Monday alarms at two
    /// different times. That reasoning is still true about the **symptom** and was wrong about the
    /// **cure**, and the difference cost him a real schedule: moving every alarm whose days happen to
    /// match means writing to alarms nobody established were OneAlarm's, which is what turned a
    /// Monday to Friday schedule into every day.
    ///
    /// The rule that replaced it is one owner per routine, recorded in `RemoteAlarmLink`. A second
    /// alarm on the same days is reported in `alarmsWithNoRoutine` so it is visible on screen and
    /// untouched on the account, which addresses the original worry without the write.
    ///
    /// He saw this on 17 August from the other side: his bed screen listed "Weekdays" twice because
    /// two alarms matched, one of them invisible in the Eight Sleep app, and OneAlarm had been
    /// maintaining the invisible one.
    func testOneRoutineAdoptsOneAlarmAndLeavesTheTwinAlone() {
        let twin = Alarm(id: "a1b", weekdays: Locale.Weekday.weekdaysOnly,
                         isEnabled: true, label: "07:15 weekdays")
        let report = RoutinePlan.match(
            entries: [entry("Weekdays", Locale.Weekday.weekdaysOnly, at: 6, minute: 50)],
            against: [weekdayAlarm, twin]
        )

        XCTAssertEqual(report.pairs.count, 1, "one routine owns one alarm")
        XCTAssertEqual(report.alarmsWithNoRoutine.count, 1,
                       "and the other is named on screen rather than written to")
    }

    /// The remote switch is no longer an input. OneAlarm is the source of truth for it, so an alarm
    /// switched off in the Eight Sleep app is switched back on by the next sync when its routine is
    /// on. That is a real cost of the goal Alex set, and it is what the routine switch is for.
    func testTheRemoteSwitchDoesNotOverrideTheRoutine() {
        let off = Alarm(id: "a4", weekdays: Locale.Weekday.weekdaysOnly,
                        isEnabled: false, label: "07:00 weekdays")
        let report = RoutinePlan.match(
            entries: [entry("Weekdays", Locale.Weekday.weekdaysOnly, at: 7)],
            against: [off]
        )

        XCTAssertTrue(report.pairs.first?.shouldBeEnabled == true,
                      "the remote switch no longer decides: the routine does")
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

    /// A switched off routine stays in the plan, carrying its switch.
    ///
    /// It used to be filtered out, which was right when the plan only described writes. It is wrong
    /// now: its alarm is still on his bed, and dropping it from the plan leaves that alarm firing on
    /// a morning he turned off in OneAlarm. Being the source of truth means switching it off there,
    /// which needs the routine to still be in the plan to switch off.
    func testASwitchedOffRoutineStaysInThePlanAndCarriesItsSwitch() {
        var routines = WakeSchedule.defaultRoutines
        routines[1].isOn = false

        let plan = RulesEngine.plan(
            for: pod,
            in: schedule(routines: routines),
            calendar: calendar,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(plan.entries.map(\.routineID), ["weekdays", "weekend"])
        XCTAssertFalse(plan.entries[1].isOn)
        XCTAssertFalse(plan.entries[1].shouldBeEnabled, "its alarm gets switched off, not abandoned")
        XCTAssertTrue(plan.entries[0].shouldBeEnabled)
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

    /// A skip reaches the bed, and only the routine it falls on.
    ///
    /// It is expressed as `enabled: false` on that routine's owned alarm, a field this adapter has
    /// read and written since the first build, rather than as `skipNext`, whose behaviour is known
    /// from its name and nothing else. This project has already paid five hours for reasoning about
    /// a field name. `skipNext` is the better long term answer and is filed as E11.
    func testASkipSuppressesOnlyTheRoutineItFallsOn() {
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
        XCTAssertNil(plan.entries.first(where: \.isBent), "a skip is not a time")

        // 1_800_000_000 is Friday 15 January 2027 in Europe/Zurich, checked rather than assumed:
        // the first version of this test said Sunday and asserted the opposite way round. So the
        // weekday routine is the one suppressed and the weekend must be untouched. A skip that took
        // the whole week down would be a routine change wearing a one day label.
        let weekdays = plan.entries.first { $0.routineID == "weekdays" }
        let weekend = plan.entries.first { $0.routineID == "weekend" }
        XCTAssertTrue(weekdays?.isSkippedNextMorning ?? false)
        XCTAssertFalse(weekdays?.shouldBeEnabled ?? true)
        XCTAssertFalse(weekend?.isSkippedNextMorning ?? true)
        XCTAssertTrue(weekend?.shouldBeEnabled ?? false)
    }
}

/// Creating an alarm, which is the most consequential thing this app does to a live account.
///
/// Alex overruled the create ban on 2026-08-16. What replaced it is not care, it is that the payload
/// is never composed: it is an alarm the server itself produced, with the identifiers stripped and
/// two fields changed. These tests are what stops a later edit turning it back into a guess.
final class AlarmCloneTests: XCTestCase {

    private var serverAlarm: [String: Any] {
        [
            "id": "abc-123",
            "enabled": false,
            "time": "07:00:00",
            "repeat": ["enabled": true, "weekDays": ["monday": true]] as [String: Any],
            "thermal": ["enabled": true, "temperature": -10] as [String: Any],
            "vibration": ["enabled": true, "level": 50, "pattern": "rise"] as [String: Any],
            "tags": ["routine-94b49169"],
            "nextTimestamp": "2026-08-16T05:00:00Z",
            "futureFieldNobodyHasSeenYet": 42,
        ]
    }

    private func clone(_ days: Set<Locale.Weekday> = [.saturday, .sunday]) -> [String: Any] {
        EightSleepAdapter.clone(serverAlarm, days: days, time: WallClockTime(hour: 9, minute: 30))
    }

    /// The server issues ids. Sending one back on a create is either ignored or an overwrite of a
    /// different alarm, and the second has no symptom until a morning is missed.
    func testEveryIdentifierIsStripped() {
        let payload = clone()

        for key in ["id", "alarmId", "alarm_id"] {
            XCTAssertNil(payload[key], "\(key) must never be sent on a create")
        }
        XCTAssertNil(payload["nextTimestamp"], "server computed fields go too")
    }

    func testTheTimeAndTheDaysAreTheOnlyThingsAuthored() {
        let payload = clone()

        XCTAssertEqual(payload["time"] as? String, "09:30:00")
        let weekDays = (payload["repeat"] as? [String: Any])?["weekDays"] as? [String: Bool]
        XCTAssertEqual(weekDays?.count, 7, "a create names all seven days, unlike an update")
        XCTAssertEqual(weekDays?["saturday"], true)
        XCTAssertEqual(weekDays?["sunday"], true)
        XCTAssertEqual(weekDays?["monday"], false)
    }

    /// The point of cloning. His vibration and thermal settings are copied from an alarm he set up,
    /// never invented, because the reference library contradicts itself about their field names.
    func testHisSettingsAreCopiedRatherThanComposed() {
        let payload = clone()

        let thermal = payload["thermal"] as? [String: Any]
        XCTAssertEqual(thermal?["temperature"] as? Int, -10)
        let vibration = payload["vibration"] as? [String: Any]
        XCTAssertEqual(vibration?["level"] as? Int, 50)
        XCTAssertEqual(vibration?["pattern"] as? String, "rise")
        XCTAssertEqual(payload["futureFieldNobodyHasSeenYet"] as? Int, 42)
    }

    /// A new alarm is on, whatever the template's switch said. Copying `enabled: false` would create
    /// an alarm that silently never fires, which is worse than not creating one.
    func testTheNewAlarmIsSwitchedOn() {
        XCTAssertEqual(clone()["enabled"] as? Bool, true)
        XCTAssertEqual((clone()["repeat"] as? [String: Any])?["enabled"] as? Bool, true)
    }

    /// `tags` is **stripped**, and this test used to assert the exact opposite.
    ///
    /// **It was `testTheRoutineTagIsCarried` until 17 August**, asserting that `tags` survives a
    /// clone, filed as `E14` with a prediction because it was reasoning about a field name. The
    /// prediction was wrong and Alex's own bed proved it: their app lists the alarm he made by hand,
    /// which carries no tags, and hides the two OneAlarm created, which carry `temporary-mode` and
    /// `oneOff-napMode`. Copying `tags` stamped "nap timer" onto a real alarm and their app filtered
    /// it out, and each clone then inherited the stamp from the clone before it.
    ///
    /// Inverted rather than deleted, and kept in the same place, because the old assertion is the
    /// most direct statement of what was wrong for a fortnight. A test that flips is a better record
    /// than one that quietly disappears.
    func testTheRoutineTagIsStripped() {
        XCTAssertNil(clone()["tags"], "the tag that hides an alarm from his own app is never copied")
        // The settings that are genuinely his still travel. Stripping tags is not licence to strip.
        XCTAssertNotNil(clone()["vibration"])
        XCTAssertNotNil(clone()["thermal"])
    }

    /// An inert alarm, no days and switched off, is the one Eight Sleep's own app hides. Copying it
    /// would clone whatever made it inert.
    func testTemplatePrefersAnAlarmThatCanActuallyFire() {
        let inert: [String: Any] = ["id": "dead", "enabled": false, "repeat": ["enabled": false]]
        let live: [String: Any] = [
            "id": "live", "enabled": true,
            "repeat": ["enabled": true, "weekDays": ["monday": true]] as [String: Any],
        ]

        let picked = EightSleepAdapter.template(from: [inert, live])
        XCTAssertEqual(picked?["id"] as? String, "live")
    }

    func testTemplateFallsBackRatherThanReturningNothing() {
        let inert: [String: Any] = ["id": "dead", "enabled": false, "repeat": ["enabled": false]]
        XCTAssertEqual(EightSleepAdapter.template(from: [inert])?["id"] as? String, "dead")
        XCTAssertNil(EightSleepAdapter.template(from: []))
    }
}

/// Recorded ownership, which is what makes OneAlarm the source of truth rather than a guesser.
///
/// Alex, 2026-08-16: *"OneAlarm is my one single source of truth for alarm setting... whenever I
/// change something on the routine or one time off, it should be done in the OneAlarm app and
/// should be written into the other apps."*
///
/// Day set matching alone cannot reach that goal, and these tests are the proof. Change a routine's
/// days and the match is gone; the link survives.
final class AlarmOwnershipTests: XCTestCase {

    private typealias Alarm = RoutinePlan.CandidateAlarm

    private func entry(_ id: String, _ days: Set<Locale.Weekday>, isOn: Bool = true, skipped: Bool = false)
    -> RoutinePlan.Entry {
        RoutinePlan.Entry(
            routineID: id, routineName: id, weekdays: days,
            localTime: WallClockTime(hour: 7, minute: 0), bentTo: nil,
            isOn: isOn, isSkippedNextMorning: skipped
        )
    }

    private let weekdayAlarm = Alarm(id: "a1", weekdays: Locale.Weekday.weekdaysOnly,
                                     isEnabled: true, label: "07:00 weekdays")

    /// The case the whole design exists for.
    ///
    /// He changes Monday to Friday into Monday to Wednesday. By days, the alarm that has served that
    /// routine is no longer a match and would be abandoned, leaving his bed on the old days forever
    /// while OneAlarm creates a second alarm beside it. By link, it is still his routine's alarm and
    /// its days get rewritten to follow.
    func testALinkedAlarmSurvivesTheRoutineChangingItsDays() {
        let report = RoutinePlan.match(
            entries: [entry("weekdays", [.monday, .tuesday, .wednesday])],
            against: [weekdayAlarm],
            links: ["weekdays": "a1"]
        )

        XCTAssertEqual(report.pairs.count, 1)
        XCTAssertEqual(report.pairs.first?.alarmID, "a1")
        XCTAssertEqual(report.pairs.first?.weekdays, [.monday, .tuesday, .wednesday],
                       "the owned alarm takes the routine's new days")
        XCTAssertTrue(report.routinesWithNoAlarm.isEmpty)
        XCTAssertFalse(report.pairs.first?.isAdoption ?? true)
    }

    /// The first run, before anything is linked. Days find the alarm once, and the caller records it.
    func testAnUnlinkedAlarmIsAdoptedByItsDaysAndFlagged() {
        let report = RoutinePlan.match(
            entries: [entry("weekdays", Locale.Weekday.weekdaysOnly)],
            against: [weekdayAlarm]
        )

        XCTAssertEqual(report.pairs.first?.alarmID, "a1")
        XCTAssertTrue(report.pairs.first?.isAdoption ?? false, "the caller has to record this link")
    }

    /// A link always beats a day match, even when another alarm looks like a better fit. Otherwise
    /// two routines fight over one alarm every time their days happen to coincide.
    func testALinkBeatsABetterLookingDayMatch() {
        let tempting = Alarm(id: "a2", weekdays: Locale.Weekday.weekdaysOnly,
                             isEnabled: true, label: "06:00 weekdays")
        let report = RoutinePlan.match(
            entries: [entry("weekdays", Locale.Weekday.weekdaysOnly)],
            against: [weekdayAlarm, tempting],
            links: ["weekdays": "a2"]
        )

        XCTAssertEqual(report.pairs.first?.alarmID, "a2")
        XCTAssertEqual(report.alarmsWithNoRoutine, ["07:00 weekdays"], "the other one stays his")
    }

    /// One alarm cannot end up owned by two routines. A routine with no link must not adopt an alarm
    /// another routine already owns, whatever its days say.
    func testAnOwnedAlarmIsNotAdoptedByAnotherRoutine() {
        let report = RoutinePlan.match(
            entries: [entry("owner", Locale.Weekday.weekdaysOnly),
                      entry("intruder", Locale.Weekday.weekdaysOnly)],
            against: [weekdayAlarm],
            links: ["owner": "a1"]
        )

        XCTAssertEqual(report.pairs.count, 1)
        XCTAssertEqual(report.pairs.first?.routineID, "owner")
        XCTAssertEqual(report.routinesWithNoAlarm, ["intruder"], "the second one gets its own created")
    }

    /// An alarm whose routine was deleted is not reported as "left alone".
    ///
    /// It is still OneAlarm's, it is on its way to being switched off by the orphan pass, and saying
    /// "left alone" about it in the same sentence that says "switched off" is a receipt contradicting
    /// itself. It is also not adoptable by a routine that happens to share its days: that would be
    /// two decisions fighting over one alarm.
    func testAnOrphanedButOwnedAlarmIsNeitherStrandedNorAdopted() {
        let orphan = Alarm(id: "orphan", weekdays: [.saturday, .sunday],
                           isEnabled: true, label: "09:00 Sat Sun")
        let report = RoutinePlan.match(
            entries: [entry("weekdays", Locale.Weekday.weekdaysOnly)],
            against: [weekdayAlarm, orphan],
            links: ["weekdays": "a1", "deleted-weekend": "orphan"]
        )

        XCTAssertEqual(report.pairs.map(\.alarmID), ["a1"])
        XCTAssertTrue(report.alarmsWithNoRoutine.isEmpty,
                      "it is ours, so it is not somebody else's alarm we are leaving alone")
    }

    /// The routine's switch drives the alarm's switch. This is the cost of the goal, stated: an
    /// alarm switched off in the Eight Sleep app comes back on if its routine is on.
    func testTheRoutineSwitchDrivesTheAlarm() {
        let offRemotely = Alarm(id: "a1", weekdays: Locale.Weekday.weekdaysOnly,
                                isEnabled: false, label: "07:00 weekdays")
        let on = RoutinePlan.match(entries: [entry("r", Locale.Weekday.weekdaysOnly)],
                                   against: [offRemotely], links: ["r": "a1"])
        XCTAssertTrue(on.pairs.first?.shouldBeEnabled ?? false)

        let off = RoutinePlan.match(entries: [entry("r", Locale.Weekday.weekdaysOnly, isOn: false)],
                                    against: [weekdayAlarm], links: ["r": "a1"])
        XCTAssertFalse(off.pairs.first?.shouldBeEnabled ?? true)
    }

    /// A skip reaches the bed now. One morning off, and the routine is untouched.
    func testASkipSwitchesTheOwnedAlarmOff() {
        let report = RoutinePlan.match(
            entries: [entry("r", Locale.Weekday.weekdaysOnly, skipped: true)],
            against: [weekdayAlarm], links: ["r": "a1"]
        )

        XCTAssertFalse(report.pairs.first?.shouldBeEnabled ?? true)
        XCTAssertTrue(report.note.contains("switched off"))
    }

    /// A routine emptied of days owns nothing and asks for nothing. Not a gap: he took every day off
    /// it, which is a setting.
    func testARoutineWithNoDaysIsNeitherPairedNorReported() {
        let report = RoutinePlan.match(entries: [entry("r", [])], against: [weekdayAlarm])

        XCTAssertTrue(report.pairs.isEmpty)
        XCTAssertTrue(report.routinesWithNoAlarm.isEmpty)
    }
}

/// Authoring an owned alarm, and what is deliberately left alone.
final class AlarmAuthoringTests: XCTestCase {

    private var serverAlarm: [String: Any] {
        [
            "id": "abc-123",
            "enabled": false,
            "time": "07:00:00",
            "repeat": ["enabled": true, "weekDays": ["monday": true]] as [String: Any],
            "thermal": ["enabled": true, "temperature": -10] as [String: Any],
            "vibration": ["enabled": true, "level": 50, "pattern": "rise"] as [String: Any],
            "nextTimestamp": "2026-08-16T05:00:00Z",
            "futureFieldNobodyHasSeenYet": 42,
        ]
    }

    private func authored(
        days: Set<Locale.Weekday> = Locale.Weekday.weekdaysOnly,
        enabled: Bool = true
    ) -> [String: Any] {
        EightSleepAdapter.author(serverAlarm, time: WallClockTime(hour: 6, minute: 50),
                                 days: days, enabled: enabled)
    }

    func testTheThreeScheduleFieldsAreAuthored() {
        let payload = authored()

        XCTAssertEqual(payload["time"] as? String, "06:50:00")
        XCTAssertEqual(payload["enabled"] as? Bool, true)
        let weekDays = (payload["repeat"] as? [String: Any])?["weekDays"] as? [String: Bool]
        XCTAssertEqual(weekDays?.count, 7, "all seven are named: this API replaces rather than merges")
        XCTAssertEqual(weekDays?["friday"], true)
        XCTAssertEqual(weekDays?["saturday"], false)
    }

    /// The line between owning the schedule and owning his account.
    func testEverythingHeOwnsComesBackUntouched() {
        let payload = authored()

        XCTAssertEqual((payload["thermal"] as? [String: Any])?["temperature"] as? Int, -10)
        XCTAssertEqual((payload["vibration"] as? [String: Any])?["level"] as? Int, 50)
        XCTAssertEqual((payload["vibration"] as? [String: Any])?["pattern"] as? String, "rise")
        XCTAssertEqual(payload["futureFieldNobodyHasSeenYet"] as? Int, 42)
        XCTAssertNil(payload["nextTimestamp"], "server computed, never sent back")
    }

    func testASkippedOrOffRoutineSwitchesTheAlarmOff() {
        XCTAssertEqual(authored(enabled: false)["enabled"] as? Bool, false)
    }

    /// A routine with no days must not leave a recurring alarm behind claiming to repeat on nothing.
    func testNoDaysTurnsOffTheRepeatBlock() {
        let payload = authored(days: [])

        XCTAssertEqual((payload["repeat"] as? [String: Any])?["enabled"] as? Bool, false)
    }

    /// Silencing an orphan changes exactly one field. Its days and its settings are left intact so
    /// he can switch it back on in their app and get what he had.
    func testSilencingChangesOnlyTheSwitch() {
        let payload = EightSleepAdapter.silence(serverAlarm)

        XCTAssertEqual(payload["enabled"] as? Bool, false)
        XCTAssertEqual(payload["time"] as? String, "07:00:00")
        let weekDays = (payload["repeat"] as? [String: Any])?["weekDays"] as? [String: Any]
        XCTAssertEqual(weekDays?.count, 1, "the server sent one key and gets one key back")
    }
}
