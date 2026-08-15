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

    private var serverSchedule: [String: Any] {
        [
            "schedule_id": "uuid-1",
            "enabled": false,
            "day_of_week_list": ["SUNDAY"],
            "latest_wake_time": "07:30:00",
            "alarm_mode": "IN_THE_GREEN",
            "sleep_goal": "",
            "time_zone_offset": "-0700",
        ]
    }

    func testWakeTimeDaysAndOffsetAreReplaced() throws {
        let payload = try WhoopAdapter.mutate(serverSchedule, to: target)

        XCTAssertEqual(payload["latest_wake_time"] as? String, "06:55:00")
        XCTAssertEqual(payload["day_of_week_list"] as? [String], ["MONDAY", "WEDNESDAY"])
        XCTAssertEqual(payload["enabled"] as? Bool, true)
        XCTAssertEqual(payload["time_zone_offset"] as? String, "+0200")
    }

    /// This PUT replaces rather than merges, so the smart wake mode he chose in the Whoop app is
    /// lost unless it is carried through.
    func testSmartWakeModeAndGoalSurvive() throws {
        let payload = try WhoopAdapter.mutate(serverSchedule, to: target)

        XCTAssertEqual(payload["alarm_mode"] as? String, "IN_THE_GREEN")
        XCTAssertEqual(payload["sleep_goal"] as? String, "")
    }

    func testIdentifiersAreNotEchoedIntoTheBody() throws {
        let payload = try WhoopAdapter.mutate(serverSchedule, to: target)

        XCTAssertNil(payload["schedule_id"])
        XCTAssertNil(payload["id"])
    }

    /// The read shape here is the least verified thing in the whole app. If the fields we depend on
    /// are not where we expect, refusing is the honest outcome, because a replacing PUT built from
    /// a partial read silently resets settings we never meant to touch.
    func testAnUnexpectedShapeIsRefusedRatherThanPartiallyWritten() {
        var missingMode = serverSchedule
        missingMode.removeValue(forKey: "alarm_mode")
        XCTAssertThrowsError(try WhoopAdapter.mutate(missingMode, to: target))

        var missingWakeTime = serverSchedule
        missingWakeTime.removeValue(forKey: "latest_wake_time")
        XCTAssertThrowsError(try WhoopAdapter.mutate(missingWakeTime, to: target))
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

    func testWhoopPreviewShowsTheOffsetItWouldSend() throws {
        let body = try XCTUnwrap(WhoopAdapter().preview(target).body)

        XCTAssertTrue(body.contains("06:50:00"))
        XCTAssertTrue(body.contains("MONDAY"))
        XCTAssertTrue(body.contains("+0200"))
    }

    func testAlarmKitPreviewSendsNothingRemote() {
        let preview = AlarmKitAdapter().preview(target)

        XCTAssertEqual(preview.method, "LOCAL")
        XCTAssertNil(preview.body)
    }
}
