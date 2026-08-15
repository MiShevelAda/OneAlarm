import XCTest
@testable import OneAlarm

/// Both remote legs work by read modify write, so the thing worth testing without a network is that
/// the modify step changes what it should and leaves everything else exactly as the server sent it.
///
/// This is the test that protects the Eight Sleep design decision. Its reference library's create
/// payload and its documented read shape disagree about field names, so the adapter never names
/// those fields at all and echoes them back untouched. If a future edit "tidies" that into a typed
/// struct, unknown fields start disappearing and this test is what notices.
final class EightSleepMutationTests: XCTestCase {

    private func target(
        hour: Int = 6,
        minute: Int = 50,
        weekdays: Set<Locale.Weekday> = Locale.Weekday.weekdaysOnly
    ) -> ResolvedTarget {
        ResolvedTarget(
            device: .eightSleep,
            localTime: WallClockTime(hour: hour, minute: minute),
            weekdays: weekdays,
            dayShift: 0,
            nextOccurrence: Date(timeIntervalSince1970: 1_800_000_000),
            utcOffsetSeconds: 7200
        )
    }

    /// The read shape as captured in the research, plus a field nobody has seen yet.
    private var serverAlarm: [String: Any] {
        [
            "id": "abc-123",
            "enabled": false,
            "time": "07:00:00",
            "repeat": [
                "enabled": true,
                "weekDays": ["monday": true, "saturday": true],
            ] as [String: Any],
            "thermal": ["enabled": true, "temperature": -10] as [String: Any],
            "vibration": [
                "enabled": true, "level": 50, "pattern": "rise", "duration": 300,
            ] as [String: Any],
            "snoozing": false,
            "snoozedUntil": NSNull(),
            "nextTimestamp": "2026-08-16T05:00:00Z",
            "startTimestamp": "2026-08-16T04:55:00Z",
            "endTimestamp": "2026-08-16T05:30:00Z",
            "dismissedUntil": NSNull(),
            "futureFieldNobodyHasSeenYet": 42,
        ]
    }

    func testAllFiveComputedFieldsAreStripped() {
        let payload = EightSleepAdapter.mutate(serverAlarm, to: target())

        for field in ["nextTimestamp", "startTimestamp", "endTimestamp", "dismissedUntil", "snoozedUntil"] {
            XCTAssertNil(payload[field], "\(field) is server computed and must not be sent back")
        }
    }

    func testTheThreeFieldsWeOwnAreChanged() {
        let payload = EightSleepAdapter.mutate(serverAlarm, to: target())

        XCTAssertEqual(payload["time"] as? String, "06:50:00")
        XCTAssertEqual(payload["enabled"] as? Bool, true)

        let repeatBlock = payload["repeat"] as? [String: Any]
        XCTAssertEqual(repeatBlock?["enabled"] as? Bool, true)

        let weekDays = repeatBlock?["weekDays"] as? [String: Bool]
        XCTAssertEqual(weekDays?.count, 7, "all seven days must be named, not only the true ones")
        XCTAssertEqual(weekDays?["monday"], true)
        XCTAssertEqual(weekDays?["friday"], true)
        XCTAssertEqual(weekDays?["saturday"], false)
        XCTAssertEqual(weekDays?["sunday"], false)
    }

    /// The whole point of the design. Vibration and thermal settings are his, we never asked what
    /// they mean, and they have to come back unchanged.
    func testEverythingElseSurvivesUntouched() {
        let payload = EightSleepAdapter.mutate(serverAlarm, to: target())

        XCTAssertEqual(payload["id"] as? String, "abc-123")
        XCTAssertEqual(payload["snoozing"] as? Bool, false)
        XCTAssertEqual(payload["futureFieldNobodyHasSeenYet"] as? Int, 42)

        let thermal = payload["thermal"] as? [String: Any]
        XCTAssertEqual(thermal?["enabled"] as? Bool, true)
        XCTAssertEqual(thermal?["temperature"] as? Int, -10)

        let vibration = payload["vibration"] as? [String: Any]
        XCTAssertEqual(vibration?["level"] as? Int, 50)
        XCTAssertEqual(vibration?["pattern"] as? String, "rise")
        XCTAssertEqual(vibration?["duration"] as? Int, 300)
    }

    /// A round trip through JSONSerialization has to preserve booleans as booleans rather than
    /// collapsing them to 1 and 0, or every weekday flag changes meaning on the wire.
    func testPayloadSurvivesAJSONRoundTrip() throws {
        let payload = EightSleepAdapter.mutate(serverAlarm, to: target())
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(decoded["enabled"] as? Bool, true)
        XCTAssertEqual(decoded["snoozing"] as? Bool, false)
        XCTAssertEqual(decoded["futureFieldNobodyHasSeenYet"] as? Int, 42)
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

    /// This is a real Whoop schedule, read off the diagnostic the picker showed on 2026-08-15. Two
    /// things in it contradict the reference spec, and both cost a 422:
    ///
    /// The names. `day_of_week_list`, `enabled`, `time_zone_offset` and `sleep_goal` do not exist.
    /// The format. The spec showed `"07:30:00"`; the account returns `"7:45 am"`.
    ///
    /// Do not restore either from a document. This fixture is the evidence.
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

        let sample = "7:45 am"
        XCTAssertEqual(
            WhoopAdapter.encodeWakeTime(WallClockTime(hour: 0, minute: 30), like: sample) as? String,
            "12:30 am"
        )
        XCTAssertEqual(
            WhoopAdapter.encodeWakeTime(WallClockTime(hour: 12, minute: 30), like: sample) as? String,
            "12:30 pm"
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
final class AllowlistTests: XCTestCase {

    private let eightSleep = HTTPClient(allowedPatterns: [
        #"^POST https://auth-api\.8slp\.net/v1/tokens$"#,
        #"^GET https://app-api\.8slp\.net/v2/users/[^/]+/alarms$"#,
        #"^PUT https://app-api\.8slp\.net/v1/users/[^/]+/alarms/[^/]+$"#,
    ])

    private let whoop = HTTPClient(allowedPatterns: [
        #"^POST https://api\.prod\.whoop\.com/auth-service/v3/whoop/$"#,
        #"^GET https://api\.prod\.whoop\.com/smart-alarm-bff/v1/schedule/all\?apiVersion=7$"#,
        #"^PUT https://api\.prod\.whoop\.com/smart-alarm-bff/v1/schedule/[^/?]+\?apiVersion=7$"#,
    ])

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string))
    }

    func testTheThreeCallsWeActuallyMakeArePermitted() throws {
        XCTAssertTrue(eightSleep.isAllowed("POST", try url("https://auth-api.8slp.net/v1/tokens")))
        XCTAssertTrue(eightSleep.isAllowed("GET", try url("https://app-api.8slp.net/v2/users/u1/alarms")))
        XCTAssertTrue(eightSleep.isAllowed("PUT", try url("https://app-api.8slp.net/v1/users/u1/alarms/a1")))

        XCTAssertTrue(whoop.isAllowed("POST", try url("https://api.prod.whoop.com/auth-service/v3/whoop/")))
        XCTAssertTrue(whoop.isAllowed("GET", try url("https://api.prod.whoop.com/smart-alarm-bff/v1/schedule/all?apiVersion=7")))
        XCTAssertTrue(whoop.isAllowed("PUT", try url("https://api.prod.whoop.com/smart-alarm-bff/v1/schedule/s1?apiVersion=7")))
    }

    /// The verb is part of the check. Without this, a path allowlisted for reading is open to
    /// deleting, which on these two APIs is the whole difference.
    func testAnAllowedPathIsStillBlockedWithTheWrongVerb() throws {
        XCTAssertFalse(eightSleep.isAllowed("DELETE", try url("https://app-api.8slp.net/v1/users/u1/alarms/a1")))
        XCTAssertFalse(eightSleep.isAllowed("POST", try url("https://app-api.8slp.net/v1/users/u1/alarms")))
        XCTAssertFalse(whoop.isAllowed("DELETE", try url("https://api.prod.whoop.com/smart-alarm-bff/v1/schedule/s1?apiVersion=7")))
    }

    /// Every one of these is a real endpoint reachable with the same bearer token.
    func testDestructiveEndpointsAreUnreachable() throws {
        let forbidden = [
            ("POST", "https://app-api.8slp.net/v1/devices/d1/priming/tasks"),
            ("POST", "https://app-api.8slp.net/v1/users/u1/base/angle"),
            ("PUT", "https://app-api.8slp.net/v1/users/u1/temperature"),
            ("PUT", "https://app-api.8slp.net/v1/users/u1/away-mode"),
            ("PUT", "https://app-api.8slp.net/v1/users/u1/audio/player/play"),
            ("PUT", "https://client-api.8slp.net/v1/users/u1/current-device"),
        ]
        for (method, address) in forbidden {
            XCTAssertFalse(eightSleep.isAllowed(method, try url(address)), "\(method) \(address)")
        }

        let forbiddenWhoop = [
            ("DELETE", "https://api.prod.whoop.com/v2/user/access"),
            // Telemetry reporting device and firmware state. Not destructive, but the single most
            // fingerprintable thing this app could send.
            ("POST", "https://api.prod.whoop.com/smart-alarm-service/v1/smartalarm/wbl"),
            ("PUT", "https://api.prod.whoop.com/smart-alarm-service/v1/strap-status"),
            ("PUT", "https://api.prod.whoop.com/onboarding-service/v1/account/profile"),
        ]
        for (method, address) in forbiddenWhoop {
            XCTAssertFalse(whoop.isAllowed(method, try url(address)), "\(method) \(address)")
        }
    }

    func testCleartextIsRefusedEvenIfAPatternWouldMatch() throws {
        let permissive = HTTPClient(allowedPatterns: [#"^GET http://example\.com/thing$"#])
        XCTAssertFalse(permissive.isAllowed("GET", try url("http://example.com/thing")))
    }

    /// Anchors have to prevent a substring match, since the matcher searches rather than matches.
    func testAnchorsPreventPrefixAndSuffixSmuggling() throws {
        XCTAssertFalse(eightSleep.isAllowed("GET", try url("https://app-api.8slp.net/v2/users/u1/alarms/extra")))
        XCTAssertFalse(eightSleep.isAllowed("GET", try url("https://evil.example.com/https://app-api.8slp.net/v2/users/u1/alarms")))
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

    func testEightSleepPreviewShowsTheScheduleItWouldSend() throws {
        let body = try XCTUnwrap(EightSleepAdapter().preview(target).body)

        XCTAssertTrue(body.contains("06:50:00"))
        XCTAssertTrue(body.contains("monday"))
        // The redaction is an allowlist, so a preview that renders every day as <redacted> would be
        // a regression rather than extra safety.
        XCTAssertFalse(body.contains("<redacted>"))
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
}
