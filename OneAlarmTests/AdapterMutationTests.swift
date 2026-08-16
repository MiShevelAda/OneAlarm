import XCTest
@testable import OneAlarm

/// Reading an Eight Sleep alarm.
///
/// Writing one is covered by `AlarmAuthoringTests`. This class kept only the tests about what the
/// adapter reads **off** an alarm, because getting that wrong pairs a routine with the wrong alarm,
/// and the symptom is somebody not waking up.
final class EightSleepReadingTests: XCTestCase {

    private var serverAlarm: [String: Any] {
        [
            "id": "abc-123",
            "enabled": false,
            "time": "07:00:00",
            "repeat": ["enabled": true, "weekDays": ["monday": true, "saturday": true]] as [String: Any],
        ]
    }

    func testRepeatDisabledMeansNoDays() {
        var alarm = serverAlarm
        alarm["repeat"] = ["enabled": false, "weekDays": ["monday": true]] as [String: Any]

        XCTAssertTrue(
            EightSleepAdapter.weekdays(of: alarm).isEmpty,
            "a one-shot alarm must not match a recurring routine, whatever its day flags say"
        )
    }

    func testDaysAreReadFromTheSevenNamedBooleans() {
        var alarm = serverAlarm
        alarm["repeat"] = [
            "enabled": true,
            "weekDays": [
                "monday": true, "tuesday": true, "wednesday": true,
                "thursday": true, "friday": true, "saturday": false, "sunday": false,
            ],
        ] as [String: Any]

        XCTAssertEqual(EightSleepAdapter.weekdays(of: alarm), Locale.Weekday.weekdaysOnly)
    }

    /// A numeric id, or one spelled `alarmId`, used to be dropped silently, and an empty list means
    /// the app reports no alarms at all on an account that has several.
    func testTheIdIsReadWhicheverWayItIsSpelled() {
        XCTAssertEqual(EightSleepAdapter.alarmID(["id": "abc"]), "abc")
        XCTAssertEqual(EightSleepAdapter.alarmID(["alarmId": "def"]), "def")
        XCTAssertEqual(EightSleepAdapter.alarmID(["id": 42]), "42")
        XCTAssertNil(EightSleepAdapter.alarmID(["nothing": true]))
    }

    /// A payload has to survive JSONSerialization with its booleans still booleans, or every weekday
    /// flag changes meaning on the wire.
    func testAuthoredPayloadSurvivesAJSONRoundTrip() throws {
        let payload = EightSleepAdapter.author(
            serverAlarm, time: WallClockTime(hour: 6, minute: 50),
            days: Locale.Weekday.weekdaysOnly, enabled: true
        )
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(decoded["enabled"] as? Bool, true)
        let weekDays = (decoded["repeat"] as? [String: Any])?["weekDays"] as? [String: Bool]
        XCTAssertEqual(weekDays?["monday"], true)
        XCTAssertEqual(weekDays?["saturday"], false)
    }
}

final class WhoopMutationTests: XCTestCase {

    private var target: ResolvedTarget {
        ResolvedTarget(
            device: .whoop,
            localTime: WallClockTime(hour: 6, minute: 55),
            weekdays: [.monday, .wednesday],
            dayShift: 0,
            nextOccurrence: Date(timeIntervalSince1970: 1_800_000_000),
            utcOffsetSeconds: 7200
        )
    }

    /// A real Whoop schedule as the **list screen** renders it, read off the picker's diagnostic on
    /// 2026-08-15. It is a view model, not the resource.
    ///
    /// An earlier version of this comment said `day_of_week_list`, `enabled`, `time_zone_offset`
    /// and `sleep_goal` do not exist, on the evidence of this very fixture. They do exist. This is
    /// the shape the **read** returns; the shape the **write** accepts uses those four names, was
    /// confirmed against a live account on 2026-08-16, and is asserted in
    /// `testTheDomainBodyIsNotContaminatedByTheViewModel`.
    ///
    /// The two are different objects and that is the durable fact. See `docs/RESEARCH.md`, section
    /// 2.3, for the table and for how believing otherwise cost five hours.
    private var serverSchedule: [String: Any] {
        [
            "schedule_id": "uuid-1",
            "alarm_on": true,
            "scheduled_days": ["SUNDAY"],
            "latest_wake_time": "7:45 am",
            "alarm_mode": "SLEEP_GOAL",
            "alarm_mode_label_display": "Sleep goal",
            "days_scheduled_label_display": "Sun",
        ]
    }

    func testWakeTimeAndDaysAreReplaced() throws {
        let payload = try WhoopAdapter.mutate(serverSchedule, to: target)

        XCTAssertEqual(payload["latest_wake_time"] as? String, "06:55:00")
        XCTAssertEqual(payload["scheduled_days"] as? [String], ["MONDAY", "WEDNESDAY"])
        XCTAssertEqual(payload["alarm_on"] as? Bool, true)
    }

    /// The write does not mirror the read, and the reason is two different status codes rather than
    /// a preference. Sending the account's own `"7:45 am"` straight back earned a 400, a parse
    /// failure. `"07:55:00"` earned a 422, a value understood and rejected on other grounds. The
    /// endpoint renders a display string on the way out and wants a canonical one on the way in.
    func testTheOutgoingTimeIsAlwaysCanonical() throws {
        for incoming in ["7:45 am", "7:45AM", "07:45:00", "1:15 pm", "07:45"] {
            var schedule = serverSchedule
            schedule["latest_wake_time"] = incoming
            XCTAssertEqual(
                try WhoopAdapter.mutate(schedule, to: target)["latest_wake_time"] as? String,
                "06:55:00",
                "incoming \(incoming)"
            )
        }
    }

    /// This PUT replaces rather than merges, so the smart wake mode he chose in the Whoop app is
    /// lost unless it is carried through.
    func testSmartWakeModeSurvives() throws {
        let payload = try WhoopAdapter.mutate(serverSchedule, to: target)

        XCTAssertEqual(payload["alarm_mode"] as? String, "SLEEP_GOAL")
    }

    /// JSON `true` and JSON `1` both arrive as `NSNumber` and both print as `1`, so a fixture cannot
    /// be eyeballed to tell them apart. Whichever kind came in is the kind that goes back.
    func testTheEnableFlagKeepsTheKindItArrivedAs() throws {
        XCTAssertEqual(WhoopAdapter.encodeFlag(true, like: true) as? Bool, true)
        XCTAssertEqual(WhoopAdapter.encodeFlag(true, like: 0) as? Int, 1)
        XCTAssertEqual(WhoopAdapter.encodeFlag(true, like: nil) as? Bool, true)
    }

    func testIdentifiersAreNotEchoedIntoTheTrimmedBody() throws {
        let payload = WhoopAdapter.trimmed(try WhoopAdapter.mutate(serverSchedule, to: target))

        XCTAssertNil(payload["schedule_id"])
        XCTAssertNil(payload["id"])
    }

    func testDisplayLabelsAreStripped() throws {
        let payload = WhoopAdapter.trimmed(try WhoopAdapter.mutate(serverSchedule, to: target))

        XCTAssertTrue(payload.keys.allSatisfy { !$0.hasSuffix("_label_display") })
    }

    /// The spec was wrong about the names, so it is not evidence about the types either. A number
    /// goes back as a number.
    func testTheOutgoingTypeMatchesTheIncomingOne() throws {
        var numeric = serverSchedule
        numeric["latest_wake_time"] = 450          // 07:30 as minutes since midnight
        numeric["scheduled_days"] = [1]            // Sunday, Calendar's numbering

        let payload = try WhoopAdapter.mutate(numeric, to: target)

        XCTAssertEqual(payload["latest_wake_time"] as? Int, 415)
        XCTAssertEqual(payload["scheduled_days"] as? [Int], [2, 4])
        XCTAssertNil(payload["latest_wake_time"] as? String)
    }

    func testShortDaySpellingIsFollowedRatherThanImposed() throws {
        var short = serverSchedule
        short["scheduled_days"] = ["SUN"]

        let payload = try WhoopAdapter.mutate(short, to: target)

        XCTAssertEqual(payload["scheduled_days"] as? [String], ["MON", "WED"])
    }

    /// A replacing PUT built from a read we could not parse silently resets settings we never meant
    /// to touch, so a missing wake time is a refusal rather than a best effort.
    func testAnUnexpectedShapeIsRefusedRatherThanPartiallyWritten() {
        var missingWakeTime = serverSchedule
        missingWakeTime.removeValue(forKey: "latest_wake_time")
        XCTAssertThrowsError(try WhoopAdapter.mutate(missingWakeTime, to: target))

        // Present but unreadable is the same refusal. A format we cannot parse is a format we
        // cannot reproduce, and guessing one is what earned the 422 in the first place.
        var unreadable = serverSchedule
        unreadable["latest_wake_time"] = "quarter to eight"
        XCTAssertThrowsError(try WhoopAdapter.mutate(unreadable, to: target))
    }

    /// The domain body carries **only** the resource's own field names. Mixing them into the view
    /// model is what happened the first time and it proved nothing: a body that is half screen
    /// description and half resource has its own reason to be refused.
    func testTheDomainBodyIsNotContaminatedByTheViewModel() throws {
        let payload = WhoopAdapter.domainBody(serverSchedule, to: target)

        XCTAssertEqual(payload["latest_wake_time"] as? String, "06:55:00")
        XCTAssertEqual(payload["day_of_week_list"] as? [String], ["MONDAY", "WEDNESDAY"])
        XCTAssertEqual(payload["enabled"] as? Bool, true)
        XCTAssertEqual(payload["time_zone_offset"] as? String, "+0200")
        // His choice, carried across rather than reset.
        XCTAssertEqual(payload["alarm_mode"] as? String, "SLEEP_GOAL")

        // Nothing the screen invented may appear here.
        for key in ["scheduled_days", "alarm_on", "schedule_id", "alarm_mode_label_display",
                    "days_scheduled_label_display"] {
            XCTAssertNil(payload[key], "view model key \(key) leaked into the domain body")
        }
        // Six keys exactly, as captured. An extra one is an unknown field on a schema that has
        // rejected everything so far.
        XCTAssertEqual(payload.keys.count, 6)
    }

    /// A deliberate one-off refusal is not reported as a mismatch.
    ///
    /// **From Alex's bed, 19 August.** His Whoop row read "Accepted, but it reads back as Mon 07:50
    /// instead of Mon 09:36", in yellow, on a run where everything worked. A Whoop schedule carries
    /// one time for all its days, so his one time change cannot go there without moving every
    /// weekday morning, and the adapter refuses on purpose and writes the routine time. Verification
    /// then compared the read-back against the bent target.
    ///
    /// Third round lost to the same shape: a write that deliberately differs from the target,
    /// verified against the target anyway. `wroteInstead` is the general fix.
    func testARefusedOneOffIsNotAMismatch() {
        let refused = WriteReceipt(
            device: .whoop, succeededAt: Date(), remoteID: "s1",
            note: "Your one-off is not on the strap.",
            wroteInstead: WallClockTime(hour: 7, minute: 50)
        )
        // Bent target: the strap was never meant to carry this.
        XCTAssertEqual(refused.wroteInstead, WallClockTime(hour: 7, minute: 50))

        // And a normal receipt carries nothing, so the target stays the yardstick.
        let ordinary = WriteReceipt(
            device: .whoop, succeededAt: Date(), remoteID: "s1", note: "Moved Weekdays."
        )
        XCTAssertNil(ordinary.wroteInstead,
                     "only a write that intended a different time may redirect its own check")
    }

    /// **His wake strategy is never substituted to get past an error.**
    ///
    /// The write ladder used to append a retry that replaced `alarm_mode` with `IN_THE_GREEN`
    /// whenever his differed, on the theory that an unknown enum would fail the whole body. The enum
    /// is now known and has three values, so a mode already on his schedule is one the server
    /// accepted and cannot be that parse failure. The rung could only ever overwrite a choice of his.
    ///
    /// `alarm_mode` is a wake **timing strategy**: `IN_THE_GREEN` wakes him in a light sleep window,
    /// `EXACT_TIME_PEAK` at the time he asked for. Swapping them moves when he wakes up.
    func testTheWriteLadderNeverSubstitutesHisAlarmMode() throws {
        var schedule = serverSchedule
        schedule["alarm_mode"] = "EXACT_TIME_PEAK"

        let shapes = try WhoopAdapter.variants(schedule, to: target)

        for (name, body) in shapes {
            let mode = body["alarm_mode"] as? String
                ?? (body["schedule"] as? [String: Any])?["alarm_mode"] as? String
            if let mode {
                XCTAssertEqual(mode, "EXACT_TIME_PEAK", "rung \(name) rewrote his wake strategy")
            }
        }
    }

    /// A mode the write enum knows is kept. Anything else is only replaced on a create.
    func testOnlyAnUnwritableModeIsReplacedAndOnlyOnACreate() {
        XCTAssertEqual(WhoopAdapter.writableMode("EXACT_TIME_PEAK"), "EXACT_TIME_PEAK")
        XCTAssertEqual(WhoopAdapter.writableMode("IN_THE_GREEN"), "IN_THE_GREEN")
        XCTAssertEqual(WhoopAdapter.writableMode("EXACT_TIME_OPTIMIZE_SLEEP"), "EXACT_TIME_OPTIMIZE_SLEEP")

        // SLEEP_GOAL makes Whoop derive its own wake time, which would ignore the routine entirely.
        XCTAssertEqual(WhoopAdapter.writableMode("SLEEP_GOAL"), "EXACT_TIME_PEAK")
        // And the old substitute, which is not in the captured enum at all.
        XCTAssertEqual(WhoopAdapter.writableMode("EXACT_TIME"), "EXACT_TIME_PEAK")
    }

    func testTheModeRetryUsesTheOnlyValueEverAccepted() throws {
        let labels = try WhoopAdapter.variants(serverSchedule, to: target).map(\.0)

        XCTAssertEqual(labels, ["domain", "domain/IN_THE_GREEN", "viewmodel"])

        var alreadyGreen = serverSchedule
        alreadyGreen["alarm_mode"] = "IN_THE_GREEN"
        // No point sending the same body twice.
        XCTAssertEqual(try WhoopAdapter.variants(alreadyGreen, to: target).map(\.0),
                       ["domain", "viewmodel"])
    }

    /// The envelope already returns `alarm_on` as `1` rather than `true`, so a boolean-only read of
    /// the master switch would pass on a number and report a green write against a disabled alarm.
    func testTheMasterSwitchIsReadWhicheverWayItIsSpelled() {
        for off in [false, 0, "false", "0", "off"] as [Any] {
            XCTAssertTrue(WhoopAdapter.isFalse(off), "\(off) should read as off")
        }
        for on in [true, 1, "true", "ENABLED"] as [Any] {
            XCTAssertFalse(WhoopAdapter.isFalse(on), "\(on) should not read as off")
        }
    }

    func testEveryAttemptCarriesTheChangeItself() throws {
        for (label, payload) in try WhoopAdapter.variants(serverSchedule, to: target) {
            // Otherwise a later attempt proves nothing about the shape it was testing.
            XCTAssertEqual(payload["latest_wake_time"] as? String, "06:55:00", label)
        }
    }

    // MARK: Reading

    func testWakeTimeIsParsedFromEitherShape() {
        XCTAssertEqual(WhoopAdapter.wakeTime(from: "07:30:00"), WallClockTime(hour: 7, minute: 30))
        XCTAssertEqual(WhoopAdapter.wakeTime(from: "07:30"), WallClockTime(hour: 7, minute: 30))
        XCTAssertEqual(WhoopAdapter.wakeTime(from: "7:45 am"), WallClockTime(hour: 7, minute: 45))
        XCTAssertEqual(WhoopAdapter.wakeTime(from: "7:45AM"), WallClockTime(hour: 7, minute: 45))
        XCTAssertEqual(WhoopAdapter.wakeTime(from: "1:15 pm"), WallClockTime(hour: 13, minute: 15))
        XCTAssertEqual(WhoopAdapter.wakeTime(from: 450), WallClockTime(hour: 7, minute: 30))
        XCTAssertEqual(WhoopAdapter.wakeTime(from: 27_000), WallClockTime(hour: 7, minute: 30))
        XCTAssertNil(WhoopAdapter.wakeTime(from: "later"))
        XCTAssertNil(WhoopAdapter.wakeTime(from: nil))
    }

    /// Midnight and noon are where every naive 12 hour conversion breaks, and they are the two the
    /// app is most likely to be asked for.
    func testTheTwelveHourEdgesAreNotOffByTwelve() {
        XCTAssertEqual(WhoopAdapter.wakeTime(from: "12:30 am"), WallClockTime(hour: 0, minute: 30))
        XCTAssertEqual(WhoopAdapter.wakeTime(from: "12:30 pm"), WallClockTime(hour: 12, minute: 30))
        // A bare 24 hour value carries no suffix and must be left exactly as it is.
        XCTAssertEqual(WhoopAdapter.wakeTime(from: "13:30"), WallClockTime(hour: 13, minute: 30))

        // **Encoding is canonical whatever the read looked like, and these two assertions used to
        // say the opposite.** They expected "12:30 am" back, mirroring the sample's display format,
        // which is the belief `docs/RESEARCH.md` §2.3 records as costing five hours: `"1:00 pm"`
        // earned a 400 and `"07:30:00"` was accepted against the live account.
        //
        // The parsing above still has to handle 12 hour input, because that is what the READ returns.
        // The write never speaks it. A view model and a resource are allowed to disagree about
        // format, and this pair does.
        let sample = "7:45 am"
        XCTAssertEqual(
            WhoopAdapter.encodeWakeTime(WallClockTime(hour: 0, minute: 30), like: sample) as? String,
            "00:30:00"
        )
        XCTAssertEqual(
            WhoopAdapter.encodeWakeTime(WallClockTime(hour: 12, minute: 30), like: sample) as? String,
            "12:30:00"
        )
    }

    func testDaysAreParsedFromEitherShape() {
        XCTAssertEqual(WhoopAdapter.days(from: ["MONDAY", "WEDNESDAY"]), [.monday, .wednesday])
        XCTAssertEqual(WhoopAdapter.days(from: ["mon", "wed"]), [.monday, .wednesday])
        XCTAssertEqual(WhoopAdapter.days(from: [2, 4]), [.monday, .wednesday])
        XCTAssertEqual(WhoopAdapter.days(from: nil), [])
    }
}

/// The allowlist is the security boundary for two APIs that can run a pump, move a bed frame, or
/// delete an account's data. These assertions are the boundary written down.
/// Two alarms on two pods at the same time are identical on screen unless the bed is named, and
/// picking the wrong one moves the wrong bed with no symptom until somebody does not wake up.
final class AlarmGroupingTests: XCTestCase {

    private func choice(_ id: String, _ group: String?) -> RemoteAlarmChoice {
        RemoteAlarmChoice(id: id, time: WallClockTime(hour: 7, minute: 0), weekdays: [.monday],
                          isEnabled: true, detail: nil, group: group, rawKeys: [])
    }

    func testNamedBedsAreGroupedInFirstSeenOrder() {
        let grouped = [choice("a", "Alex"), choice("b", "Guest room"), choice("c", "Alex")].byGroup

        XCTAssertEqual(grouped.map(\.name), ["Alex", "Guest room"])
        XCTAssertEqual(grouped[0].choices.map(\.id), ["a", "c"])
    }

    /// Unnamed alarms go last and are labelled, so a partly labelled account does not read as a
    /// rendering bug.
    func testUnnamedGoLastAndAreLabelledOnlyWhenSomethingElseIsNamed() {
        let mixed = [choice("a", nil), choice("b", "Alex")].byGroup
        XCTAssertEqual(mixed.map(\.name), ["Alex", "Not named by the service"])

        let none = [choice("a", nil), choice("b", nil)].byGroup
        XCTAssertEqual(none.count, 1)
        XCTAssertNil(none[0].name)
        XCTAssertEqual(none[0].choices.count, 2)
    }

    /// Searched, not assumed. The write-up's alarm object carries no name, and turning that absence
    /// into "Eight Sleep does not name its alarms" is the same reasoning that was wrong about Whoop.
    func testTheBedNameIsFoundWhereverTheServicePutIt() {
        XCTAssertEqual(EightSleepAdapter.groupName(["name": "Alex"]), "Alex")
        XCTAssertEqual(EightSleepAdapter.groupName(["deviceName": "Master bedroom"]), "Master bedroom")
        XCTAssertEqual(
            EightSleepAdapter.groupName(["device": ["name": "Master bedroom"], "side": "left"]),
            "Master bedroom, left side"
        )
        XCTAssertEqual(EightSleepAdapter.groupName(["side": "right"]), "Right side")
        XCTAssertEqual(EightSleepAdapter.groupName(["deviceId": "9f3c-11ea-beef"]), "Pod beef")
        XCTAssertNil(EightSleepAdapter.groupName(["name": "   "]))
        XCTAssertNil(EightSleepAdapter.groupName(["time": "07:00:00"]))
    }
}

/// The preview gate exists so the exact outbound payload can be seen before anything is sent. It is
/// built by the same code path as the real request and performs no I/O, so it is assertable here.
final class PreviewTests: XCTestCase {

    private var target: ResolvedTarget {
        ResolvedTarget(
            device: .eightSleep,
            localTime: WallClockTime(hour: 6, minute: 50),
            weekdays: [.monday],
            dayShift: 0,
            nextOccurrence: Date(timeIntervalSince1970: 1_800_000_000),
            utcOffsetSeconds: 7200
        )
    }

    func testPreviewsNeverCarryACredential() {
        let bodies = [
            EightSleepAdapter().preview(target).body,
            WhoopAdapter().preview(target).body,
        ]

        for body in bodies {
            let text = (body ?? "").lowercased()
            for forbidden in ["password", "client_secret", "bearer", "refresh_token", "authorization"] {
                XCTAssertFalse(text.contains(forbidden), "preview body leaked \(forbidden)")
            }
        }
    }

    /// **The preview shows the days too, and asserting it did not was a stale rule.**
    ///
    /// This test used to say "days are matched on, never written, so a preview showing seven weekday
    /// booleans would describe a request this adapter can no longer send". That was true on
    /// 16 August morning and stopped being true that evening, when `RemoteAlarmLink` made ownership
    /// explicit and days became writable again on an alarm a routine owns.
    ///
    /// The point of the gate is that it describes the **actual** outbound request. A preview asserted
    /// to hide a field the app now sends is worse than no gate, because the gate is where you look to
    /// rule something out. That exact failure has already cost this project an evening on the Whoop
    /// write, and the app has now shipped five pieces of copy describing behaviour it no longer had.
    func testEightSleepPreviewShowsTheTimeAndTheDays() throws {
        let body = try XCTUnwrap(EightSleepAdapter().preview(target).body)

        XCTAssertTrue(body.contains("06:50:00"))
        XCTAssertTrue(body.contains("monday"), "days are written to an owned alarm and the gate says so")
        // The redaction is an allowlist, so a preview that renders the time as <redacted> would be
        // a regression rather than extra safety.
        XCTAssertFalse(body.contains("<redacted>"))
    }

    /// Every routine is named in the summary, so the gate describes the whole write rather than one
    /// request out of two or three.
    func testEightSleepPreviewNamesEveryRoutine() {
        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [
                RoutinePlan.Entry(routineID: "weekdays", routineName: "Weekdays",
                                  weekdays: Locale.Weekday.weekdaysOnly,
                                  localTime: WallClockTime(hour: 6, minute: 50), bentTo: nil,
                                  isOn: true, isSkippedNextMorning: false),
                RoutinePlan.Entry(routineID: "weekend", routineName: "Weekend",
                                  weekdays: [.saturday, .sunday],
                                  localTime: WallClockTime(hour: 8, minute: 50), bentTo: nil,
                                  isOn: true, isSkippedNextMorning: false),
            ],
            skipsNextMorning: false
        )
        let summary = EightSleepAdapter().preview(target, plan: plan).summary

        XCTAssertTrue(summary.contains("Weekdays"))
        XCTAssertTrue(summary.contains("08:50"))
    }

    /// A reconstruction, and it has to say so. The real body is the account's schedule with three
    /// fields replaced, so it carries `alarm_mode` and, on the first attempt, the identifier and the
    /// display strings too. There is no timezone in it at all: that field was a fiction of the
    /// reference spec.
    func testWhoopPreviewIsMarkedAsAReconstruction() throws {
        let preview = WhoopAdapter().preview(target)
        let body = try XCTUnwrap(preview.body)

        XCTAssertTrue(preview.reconstructed)
        XCTAssertTrue(body.contains("06:50:00"))
        XCTAssertTrue(body.contains("MONDAY"))
        XCTAssertFalse(body.contains("+0200"))
        // Named on screen even though its value cannot be known from here, because it is the field
        // most likely to be the reason a write is refused.
        XCTAssertTrue(body.contains("alarm_mode"))
    }

    func testAlarmKitPreviewSendsNothingRemote() {
        let preview = AlarmKitAdapter().preview(target)

        XCTAssertEqual(preview.method, "LOCAL")
        XCTAssertNil(preview.body)
    }

    /// The gate has to describe the request the app actually makes.
    ///
    /// It said "Repeating alarm at 07:00 on Mon Tue Wed Thu Fri", singular, which stopped being true
    /// the moment the phone started holding one alarm per routine. A gate that describes a request
    /// the app no longer makes is worse than no gate: it is where you go to rule something out, and
    /// this project has already lost an evening to one that did exactly that on the Whoop write.
    func testAlarmKitPreviewNamesEveryRoutineItWouldArm() {
        let plan = RoutinePlan(
            device: .iphone,
            entries: [
                RoutinePlan.Entry(routineID: "weekdays", routineName: "Weekdays",
                                  weekdays: Locale.Weekday.weekdaysOnly,
                                  localTime: WallClockTime(hour: 7, minute: 0), bentTo: nil,
                                  isOn: true, isSkippedNextMorning: false),
                RoutinePlan.Entry(routineID: "weekend", routineName: "Weekend",
                                  weekdays: [.saturday, .sunday],
                                  localTime: WallClockTime(hour: 9, minute: 0), bentTo: nil,
                                  isOn: true, isSkippedNextMorning: false),
            ],
            skipsNextMorning: false
        )
        let summary = AlarmKitAdapter().preview(target, plan: plan).summary

        XCTAssertTrue(summary.contains("2 repeating alarms"))
        XCTAssertTrue(summary.contains("07:00"))
        XCTAssertTrue(summary.contains("09:00"), "the routine that is not next has to be shown too")
    }
}
