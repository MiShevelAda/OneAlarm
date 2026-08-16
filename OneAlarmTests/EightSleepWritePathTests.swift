import XCTest
@testable import OneAlarm

/// The whole Eight Sleep write path, against a fake Eight Sleep.
///
/// **Why this file exists.** Every round on 16 August ended the same way: code was written, pushed,
/// and then Alex had to build it, run it, look at his bed and report back. Nothing in between could
/// say whether it worked. That loop is expensive and it is why a create that succeeded was about to
/// be reported to him as a failure, twice, before anybody noticed.
///
/// These tests move most of that check to `Cmd+U`. They exercise the real `write(_:plan:)`, through
/// the real `HTTPClient` and its real allowlist, against a stub that answers like Eight Sleep. What
/// they cannot check is the API contract itself: whether their server accepts these bodies is a fact
/// about their server and still needs one run on a real account. Everything else is here.
///
/// So a failure in this file means OneAlarm is wrong. A pass means OneAlarm does what it intends,
/// and the remaining question is whether Eight Sleep agrees.
final class EightSleepWritePathTests: XCTestCase {

    // MARK: The fake

    /// Answers requests from a table, and records every one it was asked for.
    ///
    /// Deliberately goes through `URLProtocol` rather than stubbing `HTTPClient`, so the allowlist,
    /// the redirect blocker and the JSON encoding are all in the path being tested. A stub that
    /// replaced the client would pass while the allowlist blocked every request.
    final class StubServer: URLProtocol {
        struct Call: Equatable {
            let method: String
            let path: String
        }

        nonisolated(unsafe) static var responses: [String: (Int, Any)] = [:]
        /// Answers that change between calls to the same address.
        ///
        /// Needed because the create path reads the account, writes, and reads again to find what
        /// appeared. A stub that answers identically both times cannot express that, and a test
        /// written against one would fail for a reason that has nothing to do with the code. The
        /// first version of the create test did exactly that.
        ///
        /// Consumed front to back; once empty, `responses` answers.
        nonisolated(unsafe) static var sequences: [String: [(Int, Any)]] = [:]
        nonisolated(unsafe) static var calls: [Call] = []
        nonisolated(unsafe) static var bodies: [String: [String: Any]] = [:]

        static func reset() {
            responses = [:]
            sequences = [:]
            calls = []
            bodies = [:]
        }

        static func next(_ key: String) -> (Int, Any)? {
            guard var queued = sequences[key], !queued.isEmpty else { return nil }
            let head = queued.removeFirst()
            sequences[key] = queued
            return head
        }

        static func key(_ method: String, _ path: String) -> String { "\(method) \(path)" }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            Self.calls.append(Call(method: method, path: path))

            // `httpBody` is nil once URLSession has taken the request, so it is read from the stream.
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                stream.close()
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    Self.bodies[Self.key(method, path)] = object
                }
            }

            let lookup = Self.key(method, path)
            let (status, payload) = Self.next(lookup) ?? Self.responses[lookup] ?? (404, ["error": "no stub"])
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// A 200 with an empty body.
    ///
    /// Spelled out rather than written as `(200, [:])`. An empty collection literal in an `Any`
    /// position is a hard Swift error, "empty collection literal requires an explicit type", and
    /// this file exists precisely because there is no compiler in the session to catch that.
    private let accepted: (Int, Any) = (200, [String: Any]())

    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return URLSession(configuration: config)
    }

    private let userID = "user-1"

    private func adapter() async -> EightSleepAdapter {
        let adapter = EightSleepAdapter(session: session)
        await adapter.seedSessionForTesting(token: "test-token", userID: userID)
        return adapter
    }

    override func setUp() {
        super.setUp()
        StubServer.reset()
        RemoteAlarmLink.forget(for: .eightSleep)
    }

    override func tearDown() {
        RemoteAlarmLink.forget(for: .eightSleep)
        super.tearDown()
    }

    // MARK: Fixtures

    private func alarm(
        id: String,
        time: String,
        days: [String],
        routine: String? = nil,
        enabled: Bool = true
    ) -> [String: Any] {
        var weekDays: [String: Bool] = [:]
        for day in ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"] {
            weekDays[day] = days.contains(day)
        }
        var object: [String: Any] = [
            "id": id,
            "time": time,
            "enabled": enabled,
            "repeat": ["enabled": true, "weekDays": weekDays] as [String: Any],
            "vibration": ["enabled": true, "powerLevel": 50, "pattern": "RISE"] as [String: Any],
            "thermal": ["enabled": true, "level": 20] as [String: Any],
            "futureFieldNobodyHasSeenYet": 42,
        ]
        if let routine { object["tags"] = ["routine-\(routine)"] }
        return object
    }

    /// An alarm carrying the tags Eight Sleep's app uses to hide one, read off Alex's real account.
    private func hiddenAlarm(id: String, time: String, days: [String]) -> [String: Any] {
        var object = alarm(id: id, time: time, days: days, routine: nil)
        object["tags"] = ["temporary-mode", "oneOff-napMode"]
        return object
    }

    private func routine(id: String, days: [String], bedtime: String = "23:00:00") -> [String: Any] {
        [
            "id": id,
            "enabled": true,
            "days": days,
            // The field that must survive untouched. When he goes to bed is not an alarm setting.
            //
            // `dayOffset` is `"MinusOne"` here, a string, and it was `0` until 17 August. The echo
            // test passed either way, because the adapter sends this back without looking at it,
            // which is exactly why a wrong fixture was able to sit here. The harm is that a fixture
            // is read as evidence: somebody comparing this against `RESEARCH.md` §1.5b, which says
            // `dayOffset` is a string enum, would have found the project contradicting itself and
            // had no way to tell which side was right. Fixtures are part of the record.
            //
            // `"MinusOne"` and not `"Zero"`: a bedtime belongs to the evening before the morning its
            // routine wakes him on.
            "bedtime": ["time": bedtime, "dayOffset": "MinusOne"] as [String: Any],
            "alarms": [Any](),
        ]
    }

    private func entry(
        _ id: String,
        _ name: String,
        _ days: Set<Locale.Weekday>,
        hour: Int,
        minute: Int = 0,
        isOn: Bool = true
    ) -> RoutinePlan.Entry {
        RoutinePlan.Entry(
            routineID: id, routineName: name, weekdays: days,
            localTime: WallClockTime(hour: hour, minute: minute), bentTo: nil,
            isOn: isOn, isSkippedNextMorning: false
        )
    }

    private var target: ResolvedTarget {
        ResolvedTarget(
            device: .eightSleep,
            localTime: WallClockTime(hour: 6, minute: 50),
            weekdays: Locale.Weekday.weekdaysOnly,
            dayShift: 0,
            // Friday 15 January 2027, checked rather than assumed.
            nextOccurrence: Date(timeIntervalSince1970: 1_800_000_000),
            utcOffsetSeconds: 3600
        )
    }

    private let weekdayNames = ["monday", "tuesday", "wednesday", "thursday", "friday"]

    // MARK: The case Alex hit

    /// A weekday alarm exists, a weekend routine has none, and the weekend alarm must be created
    /// **inside** a routine so their app lists it.
    func testAWeekendRoutineWithNoAlarmGetsOneInsideItsRoutine() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [alarm(id: "a1", time: "07:00:00", days: weekdayNames, routine: "r1")],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, [
                "routines": [
                    routine(id: "r1", days: weekdayNames),
                    routine(id: "r2", days: ["saturday", "sunday"]),
                ],
            ]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/a1"): accepted,
            StubServer.key("PUT", "/v2/users/\(userID)/routines/r2"): accepted,
            StubServer.key("PUT", "/v2/users/\(userID)/routines/r1"): accepted,
        ]

        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [
                entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50),
                entry("weekend", "Weekend", [.saturday, .sunday], hour: 8, minute: 50),
            ],
            skipsNextMorning: false
        )

        let receipt = try await adapter().write(target, plan: plan)

        // The weekend alarm went into the routine that already runs on those days, not out as a
        // standalone POST that their app would never list.
        let body = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v2/users/\(userID)/routines/r2")])
        let pending = try XCTUnwrap(body["alarmsToCreate"] as? [[String: Any]])
        XCTAssertEqual(pending.count, 1)
        let timeWithOffset = pending[0]["timeWithOffset"] as? [String: Any]
        XCTAssertEqual(timeWithOffset?["time"] as? String, "08:50:00")

        // `dayOffset` is a string enum, not a number. The first version of this payload sent `0`,
        // read too quickly off one public capture; two independent implementations spell it
        // `"Zero"`. An integer here comes back as a bare 400 and gets blamed on the endpoint.
        XCTAssertEqual(timeWithOffset?["dayOffset"] as? String, "Zero")
        XCTAssertNil(timeWithOffset?["dayOffset"] as? Int)

        // Both sources send these as the epoch. This API replaces rather than merges, so a field
        // the server expects and does not get is a field it loses.
        XCTAssertEqual(pending[0]["dismissedUntil"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(pending[0]["snoozedUntil"] as? String, "1970-01-01T00:00:00Z")

        // His vibration and thermal, copied from a real alarm rather than composed.
        let settings = pending[0]["settings"] as? [String: Any]
        let vibration = settings?["vibration"] as? [String: Any]
        XCTAssertEqual(vibration?["powerLevel"] as? Int, 50)

        XCTAssertFalse(
            StubServer.calls.contains { $0.method == "POST" },
            "a standalone POST creates an alarm belonging to no routine, which is the bug"
        )
        XCTAssertTrue(receipt.note?.contains("Weekend") ?? false)
    }

    /// The defect found by reading the path back: a create that worked was thrown as a failure.
    func testACreateThatSucceededIsNotReportedAsAFailure() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [alarm(id: "a1", time: "07:00:00", days: weekdayNames, routine: "r1")],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, [
                "routines": [routine(id: "r2", days: ["saturday", "sunday"])],
            ]),
            StubServer.key("PUT", "/v2/users/\(userID)/routines/r2"): accepted,
        ]

        // One routine, and it has no alarm. Before the fix this threw `noMatchingDays` one line
        // after creating the alarm successfully, so Alex would have seen the same failure message
        // as the two rounds before, on a run that worked.
        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [entry("weekend", "Weekend", [.saturday, .sunday], hour: 8, minute: 50)],
            skipsNextMorning: false
        )

        let receipt = try await adapter().write(target, plan: plan)
        XCTAssertTrue(receipt.note?.contains("Weekend") ?? false)
    }

    // MARK: The line Alex drew

    /// His bedtime is not an alarm setting, and neither is anything else on the routine.
    ///
    /// *"Only the modifications of temperature, vibration etc should be done in the respective app."*
    func testTheRoutineWriteLeavesHisBedtimeAndSettingsAlone() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [alarm(id: "a1", time: "07:00:00", days: weekdayNames, routine: "r1")],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, [
                "routines": [routine(id: "r1", days: weekdayNames, bedtime: "22:45:00")],
            ]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/a1"): accepted,
            StubServer.key("PUT", "/v2/users/\(userID)/routines/r1"): accepted,
        ]

        // Monday to Wednesday: the change that day set matching could never have made.
        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [entry("weekdays", "Weekdays", [.monday, .tuesday, .wednesday], hour: 6, minute: 50)],
            skipsNextMorning: false
        )
        RemoteAlarmLink.link(routine: "weekdays", to: "a1", on: .eightSleep)

        _ = try await adapter().write(target, plan: plan)

        let routineBody = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v2/users/\(userID)/routines/r1")])
        XCTAssertEqual(routineBody["days"] as? [String], ["monday", "tuesday", "wednesday"],
                       "the routine's days follow OneAlarm")
        let bedtime = routineBody["bedtime"] as? [String: Any]
        XCTAssertEqual(bedtime?["time"] as? String, "22:45:00", "his bedtime is his")
        // The whole sub-object comes back, not just the field the assertion above happens to name.
        // `dayOffset` is the one most likely to be silently retyped on the way through, because a
        // JSON round trip through a decoder that guesses would turn a string enum into something
        // else, and the server replaces rather than merges.
        XCTAssertEqual(bedtime?["dayOffset"] as? String, "MinusOne",
                       "the bedtime object echoes whole, string enum included")

        let alarmBody = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/a1")])
        XCTAssertEqual(alarmBody["time"] as? String, "06:50:00")
        let vibration = alarmBody["vibration"] as? [String: Any]
        XCTAssertEqual(vibration?["powerLevel"] as? Int, 50, "vibration is his")
        XCTAssertEqual(alarmBody["futureFieldNobodyHasSeenYet"] as? Int, 42, "unknown fields survive")
    }

    /// An alarm OneAlarm has never owned is never written to, and neither is its routine.
    func testAnUnownedAlarmAndItsRoutineAreNeverTouched() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [
                    alarm(id: "a1", time: "07:00:00", days: weekdayNames, routine: "r1"),
                    alarm(id: "stranger", time: "05:30:00", days: ["wednesday"], routine: "r9"),
                ],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, [
                "routines": [routine(id: "r1", days: weekdayNames), routine(id: "r9", days: ["wednesday"])],
            ]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/a1"): accepted,
        ]

        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50)],
            skipsNextMorning: false
        )

        _ = try await adapter().write(target, plan: plan)

        XCTAssertFalse(StubServer.calls.contains { $0.path.hasSuffix("/alarms/stranger") })
        XCTAssertFalse(StubServer.calls.contains { $0.path.hasSuffix("/routines/r9") })
    }

    /// A refusal is reported with the server's own words rather than swallowed.
    func testARefusedCreateNamesTheStatusAndTheBody() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [alarm(id: "a1", time: "07:00:00", days: weekdayNames, routine: "r1")],
            ]),
            // Annotated: the tuple's second element is `Any`, so the inner `[]` has no contextual
            // type and Swift rejects it. Same trap as `(200, [:])`, one level deeper.
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/a1"): accepted,
            StubServer.key("POST", "/v1/users/\(userID)/alarms"): (422, ["message": "bad shape"]),
            StubServer.key("POST", "/v2/users/\(userID)/alarms"): (404, ["message": "no route"]),
        ]

        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [
                entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50),
                entry("weekend", "Weekend", [.saturday, .sunday], hour: 8, minute: 50),
            ],
            skipsNextMorning: false
        )

        let receipt = try await adapter().write(target, plan: plan)
        let note = try XCTUnwrap(receipt.note)

        XCTAssertTrue(note.contains("422"), "the status has to reach the screen")
        XCTAssertTrue(note.contains("bad shape"), "and so does what the server said")
        XCTAssertTrue(receipt.isPartial, "a week with a hole in it is not a done write")
    }

    /// The create must not repeat itself on the next sync.
    ///
    /// An alarm created through `alarmsToCreate` takes its days from the **routine**, so its own
    /// `repeat.weekDays` can come back empty. An empty day set matches no routine, so a second sync
    /// would see the same routine with no alarm and create another, and the sync after that another,
    /// until the ceiling stopped it at eight. Eight unwanted alarms on his bed, from a feature
    /// reporting success every time.
    ///
    /// The fix is to re-read the account and link whichever id was not there before. This test is
    /// the one that fails if that is ever removed as an extra request nobody needs.
    func testACreatedAlarmIsOwnedImmediatelyRatherThanNextTime() async throws {
        let before = [alarm(id: "a1", time: "07:00:00", days: weekdayNames, routine: "r1")]
        // The created alarm comes back with **no days of its own**, which is the whole hazard.
        let after = before + [alarm(id: "brand-new", time: "08:50:00", days: [], routine: "r2")]

        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, [
                "routines": [routine(id: "r2", days: ["saturday", "sunday"])],
            ]),
            StubServer.key("PUT", "/v2/users/\(userID)/routines/r2"): accepted,
            // Every read after the first one sees the new alarm.
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, ["alarms": after]),
        ]
        // The **first** read is the account before the create. Sequenced rather than mutated
        // mid-test: `write` reads, writes, then reads again, and the whole point is that the second
        // read differs from the first.
        StubServer.sequences[StubServer.key("GET", "/v2/users/\(userID)/alarms")] = [
            (200, ["alarms": before] as Any),
        ]

        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [entry("weekend", "Weekend", [.saturday, .sunday], hour: 8, minute: 50)],
            skipsNextMorning: false
        )

        _ = try await adapter().write(target, plan: plan)

        XCTAssertEqual(
            RemoteAlarmLink.alarmID(for: "weekend", on: .eightSleep), "brand-new",
            "the new alarm is owned now, not left to a day set match that cannot happen"
        )
    }

    /// A sync that did everything asked reports as done, not as a warning.
    ///
    /// The success message for a create used to sit in the same list as the failures, so creating an
    /// alarm successfully set `isPartial` and the row went yellow. Reporting success as a warning is
    /// the same class of lie as reporting failure as done, one step further from useful: it teaches
    /// him to stop reading the row, and the row is the only thing that tells him whether his bed is
    /// set.
    func testAFullySuccessfulRunIsNotFlaggedAsPartial() async throws {
        let before = [alarm(id: "a1", time: "07:00:00", days: weekdayNames, routine: "r1")]
        let after = before + [alarm(id: "brand-new", time: "08:50:00", days: [], routine: "r2")]

        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, [
                "routines": [routine(id: "r2", days: ["saturday", "sunday"])],
            ]),
            StubServer.key("PUT", "/v2/users/\(userID)/routines/r2"): accepted,
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, ["alarms": after]),
        ]
        StubServer.sequences[StubServer.key("GET", "/v2/users/\(userID)/alarms")] = [
            (200, ["alarms": before] as Any),
        ]

        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [entry("weekend", "Weekend", [.saturday, .sunday], hour: 8, minute: 50)],
            skipsNextMorning: false
        )

        let receipt = try await adapter().write(target, plan: plan)

        XCTAssertFalse(receipt.isPartial, "everything asked for happened, so the row says done")
        XCTAssertTrue(receipt.note?.contains("Added the Weekend alarm") ?? false)
    }

    /// The routines read is `v2` and only `v2`, even when `v1` would have answered.
    ///
    /// **This test asserts the reverse of the one it replaces**, and the reason is worth keeping.
    /// The first version read v2, then fell back to v1, on the reasoning that whichever answered was
    /// the right address. `docs/RESEARCH.md` §1.1 says three times that `/v1/users/{id}/routines` is
    /// the **retired** Routines feature, deleted from their app. §1.5b is the current `/v2` object,
    /// the one with `alarmsToCreate` in it. They share a word and are not the same thing.
    ///
    /// So a fallback that fires hands the caller the retired object, whose fields are then echoed
    /// into a `PUT /v2/.../routines/{id}`. Reading object A and writing it to endpoint B is the shape
    /// of the mistake that cost five hours on the Whoop leg. The stub here answers v1 happily, and
    /// the assertion is that OneAlarm never asks.
    func testTheRoutinesReadNeverFallsBackToTheRetiredVersion() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [alarm(id: "a1", time: "07:00:00", days: weekdayNames, routine: "r1")],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (404, ["message": "no route"]),
            // Answers, and must still never be called on a write path.
            StubServer.key("GET", "/v1/users/\(userID)/routines"): (200, [
                "routines": [routine(id: "r1", days: weekdayNames)],
            ]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/a1"): accepted,
            StubServer.key("PUT", "/v2/users/\(userID)/routines/r1"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "a1", on: .eightSleep)

        let subject = await adapter()
        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [entry("weekdays", "Weekdays", [.monday, .tuesday], hour: 6, minute: 50)],
            skipsNextMorning: false
        )

        _ = try await subject.write(target, plan: plan)

        XCTAssertFalse(StubServer.calls.contains { $0.path == "/v1/users/\(userID)/routines" },
                       "the retired Routines API must not be read on a write path, however willingly it answers")
        // The routine write is skipped rather than sent from the wrong object. The alarm time still
        // goes out, which is the deliberate part: a routine read that fails must not take the times
        // down with it.
        XCTAssertNil(StubServer.bodies[StubServer.key("PUT", "/v2/users/\(userID)/routines/r1")],
                     "no routine was read, so no routine may be written")
        XCTAssertNotNil(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/a1")],
                        "the alarm time still goes out")

        let failure = await subject.lastRoutineReadFailure
        XCTAssertEqual(failure, "v2: HTTP 404", "the refusal is named with its status, not swallowed")
    }

    /// A refused read must not pass as "you have no routines".
    ///
    /// The two are indistinguishable from the outside and mean opposite things. One is a setting,
    /// the other is OneAlarm calling the wrong address, and only the second is a bug.
    func testARefusedRoutinesReadIsNamedRatherThanReadAsEmpty() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [alarm(id: "a1", time: "07:00:00", days: weekdayNames, routine: "r1")],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (404, ["message": "no route"]),
            StubServer.key("GET", "/v1/users/\(userID)/routines"): (404, ["message": "no route"]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/a1"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "a1", on: .eightSleep)

        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50)],
            skipsNextMorning: false
        )

        let receipt = try await adapter().write(target, plan: plan)
        let note = try XCTUnwrap(receipt.note)

        XCTAssertTrue(note.contains("Could not read your Eight Sleep routines"))
        XCTAssertTrue(note.contains("404"), "with the status, so it can be diagnosed in one look")
    }

    /// Deleting a routine switches off **its** alarm and nothing else.
    ///
    /// This is the only destructive thing OneAlarm does to his bed, so it is the one that has to be
    /// exactly right. The failure it guards against has no symptom until a morning nobody is woken
    /// on, and by then the cause is a week old.
    ///
    /// **Off rather than deleted, and after 17 August that is a sharper claim than when it was
    /// written.** Deleting now exists, so this passing is no longer a statement about the app having
    /// no DELETE at all. It is a statement about provenance: neither alarm here is on
    /// `RemoteAlarmLink.created`, so neither was made by OneAlarm, so neither may be destroyed however
    /// abandoned it is. This is the adopted case, and it is the one that must never change.
    func testDeletingARoutineSwitchesOffOnlyItsOwnAlarm() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [
                    alarm(id: "keep", time: "07:00:00", days: weekdayNames, routine: "r1"),
                    alarm(id: "abandoned", time: "09:00:00", days: ["saturday", "sunday"], routine: "r2"),
                    alarm(id: "his-own", time: "05:30:00", days: ["wednesday"], routine: "r9"),
                ],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, [
                "routines": [routine(id: "r1", days: weekdayNames)],
            ]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/keep"): accepted,
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/abandoned"): accepted,
        ]
        // Both were OneAlarm's to **manage**, and neither was OneAlarm's to **destroy**: they are
        // linked but not marked created, which is what an adopted alarm looks like. The weekend
        // routine has since been deleted in the app.
        RemoteAlarmLink.link(routine: "weekdays", to: "keep", on: .eightSleep)
        RemoteAlarmLink.link(routine: "weekend", to: "abandoned", on: .eightSleep)

        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50)],
            skipsNextMorning: false
        )

        let receipt = try await adapter().write(target, plan: plan)

        // The abandoned one is switched off, and only its switch changed: its time and its days are
        // sent back exactly as they came, so turning it back on in their app gives him what he had.
        let body = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/abandoned")])
        XCTAssertEqual(body["enabled"] as? Bool, false)
        XCTAssertEqual(body["time"] as? String, "09:00:00", "its time is not ours to change on the way out")

        // His own alarm, which OneAlarm never owned, is untouched.
        XCTAssertFalse(StubServer.calls.contains { $0.path.hasSuffix("/alarms/his-own") })
        // And nothing is ever deleted.
        XCTAssertFalse(StubServer.calls.contains { $0.method == "DELETE" })

        // The link is dropped, so the next sync does not go looking for it again.
        XCTAssertNil(RemoteAlarmLink.alarmID(for: "weekend", on: .eightSleep))
        XCTAssertEqual(RemoteAlarmLink.alarmID(for: "weekdays", on: .eightSleep), "keep")

        XCTAssertTrue(receipt.note?.contains("Switched off") ?? false,
                      "switching off an alarm on his bed is never silent")
    }

    /// The whole point of recording ownership: nothing is created twice.
    func testALinkedAlarmIsUpdatedRatherThanDuplicated() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [alarm(id: "a1", time: "07:00:00", days: ["monday"], routine: "r1")],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, [
                "routines": [routine(id: "r1", days: ["monday"])],
            ]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/a1"): accepted,
            StubServer.key("PUT", "/v2/users/\(userID)/routines/r1"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "a1", on: .eightSleep)

        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50)],
            skipsNextMorning: false
        )

        _ = try await adapter().write(target, plan: plan)

        XCTAssertFalse(StubServer.calls.contains { $0.method == "POST" },
                       "its days changed, but it is still the same alarm")
        XCTAssertTrue(StubServer.calls.contains { $0.method == "PUT" && $0.path.hasSuffix("/alarms/a1") })
    }

    // MARK: One morning only

    // Alex's goal has two halves: *"whenever I change something on the routine **or one time off**,
    // it should be done in the 1 alarm app and should be written into the other apps."*
    //
    // The routine half was confirmed on his bed on 17 August. The one-off half had **no test on this
    // path at all**, on either leg of it. `AlarmKitReconcilerTests` covers what the phone does with a
    // bend; nothing covered what reaches Eight Sleep. So the three cases below are the ones his own
    // two minute check on the phone is about to exercise, written first.

    /// A bend writes the bent time to the bed, and leaves the routine's days and switch alone.
    func testABendWritesTheOneOffTimeToTheBed() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [alarm(id: "his", time: "05:51:00", days: weekdayNames, routine: nil)],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)

        var bent = entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 5)
        bent = RoutinePlan.Entry(
            routineID: bent.routineID, routineName: bent.routineName, weekdays: bent.weekdays,
            localTime: bent.localTime,
            // +15 on his home screen, carried through the bed's 10 minute lead by the rules engine.
            bentTo: WallClockTime(hour: 6, minute: 20),
            isOn: true, isSkippedNextMorning: false
        )

        _ = try await adapter().write(
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [bent], skipsNextMorning: false)
        )

        let body = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/his")])
        XCTAssertEqual(body["time"] as? String, "06:20:00", "the bed follows the one-off, not the routine")
        XCTAssertEqual(body["enabled"] as? Bool, true, "a bend moves an alarm, it does not switch it off")
        let days = (body["repeat"] as? [String: Any])?["weekDays"] as? [String: Bool]
        XCTAssertEqual(days?["monday"], true, "and the routine's days are untouched")
        XCTAssertEqual(days?["saturday"], false)
    }

    /// A skip switches the bed's alarm off, and changes nothing else about it.
    ///
    /// Off rather than deleted, and off rather than moved, because an Eight Sleep alarm has no way to
    /// say "not this one Tuesday". The time and days must survive so that clearing the skip is a
    /// single field going back.
    func testASkipSwitchesTheBedsAlarmOffAndNothingElse() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [alarm(id: "his", time: "05:51:00", days: weekdayNames, routine: nil)],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)

        let base = entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 5)
        let skipped = RoutinePlan.Entry(
            routineID: base.routineID, routineName: base.routineName, weekdays: base.weekdays,
            localTime: base.localTime, bentTo: nil, isOn: true, isSkippedNextMorning: true
        )

        _ = try await adapter().write(
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [skipped], skipsNextMorning: true)
        )

        let body = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/his")])
        XCTAssertEqual(body["enabled"] as? Bool, false, "a skip switches it off")
        XCTAssertEqual(body["time"] as? String, "06:05:00", "and leaves the routine time on it")
        let days = (body["repeat"] as? [String: Any])?["weekDays"] as? [String: Bool]
        XCTAssertEqual(days?["monday"], true, "and the days, so clearing the skip is one field back")
        // His settings are not collateral. This is the whole "temperature and vibration are yours"
        // line, tested on the path most likely to break it.
        XCTAssertNotNil(body["vibration"])
        XCTAssertNotNil(body["thermal"])
    }

    /// Clearing the bend puts the routine time back. The second half of his two minute check.
    ///
    /// This is the failure that would matter most: a one-off that strands his bed on a time he chose
    /// for one morning. It is the same write with `bentTo` gone, so what it really asserts is that
    /// nothing about the bend was persisted anywhere on the way through.
    func testClearingTheBendPutsTheRoutineTimeBack() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [alarm(id: "his", time: "06:20:00", days: weekdayNames, routine: nil)],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)

        _ = try await adapter().write(
            target,
            plan: RoutinePlan(
                device: .eightSleep,
                entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 5, minute: 51)],
                skipsNextMorning: false
            )
        )

        let body = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/his")])
        XCTAssertEqual(body["time"] as? String, "05:51:00", "back to the routine, not stranded on the bend")
        XCTAssertEqual(body["enabled"] as? Bool, true)
    }

    // MARK: Alarms his own app hides

    /// A created alarm never carries the tags that hide it.
    ///
    /// **E14, answered on his account on 17 August in the opposite direction from the prediction.**
    /// `clone` used to keep `tags`, on the reasoning that it pointed at a routine and copying it
    /// would put the new alarm where their app could see it. His account carries no routine tag on
    /// any alarm. What it carries is `temporary-mode` and `oneOff-napMode` on the two alarms OneAlarm
    /// created, both invisible in the Eight Sleep app, while the one he made by hand has no tags and
    /// is the only one listed.
    ///
    /// So the tag was not neutral cargo. It marked a real alarm as a nap timer, their app filtered it
    /// out, and the next clone inherited the mark from the clone before it. That is how one hidden
    /// alarm became two.
    func testACreatedAlarmCarriesNoTags() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [hiddenAlarm(id: "ghost", time: "07:00:00", days: weekdayNames)],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("POST", "/v1/users/\(userID)/alarms"): (201, ["id": "fresh"]),
        ]

        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [entry("weekend", "Weekend", [.saturday, .sunday], hour: 8, minute: 50)],
            skipsNextMorning: false
        )

        _ = try? await adapter().write(target, plan: plan)

        let body = try XCTUnwrap(StubServer.bodies[StubServer.key("POST", "/v1/users/\(userID)/alarms")])
        XCTAssertNil(body["tags"], "the tag that hides an alarm is never copied onto a new one")
        // The settings that ARE his still travel. Stripping tags is not licence to strip everything.
        XCTAssertNotNil(body["vibration"], "his vibration is still copied from a real alarm")
        XCTAssertNotNil(body["thermal"], "and his thermal")
    }

    /// A hidden alarm is never adopted, so his week is never bound to something he cannot see.
    ///
    /// The bed screen listed "Weekdays" twice on 17 August. Two alarms had identical weekday sets,
    /// one visible and one hidden, and OneAlarm adopted whichever the server returned first. It then
    /// maintained the invisible one while his real alarm drifted away from it.
    func testAHiddenAlarmIsNeverAdopted() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [
                    // Deliberately first, which is what made this happen on his account.
                    hiddenAlarm(id: "ghost", time: "05:55:00", days: weekdayNames),
                    alarm(id: "his", time: "05:57:00", days: weekdayNames, routine: nil),
                ],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/ghost"): accepted,
        ]

        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50)],
            skipsNextMorning: false
        )

        _ = try await adapter().write(target, plan: plan)

        XCTAssertNotNil(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/his")],
                        "the alarm he can see is the one that moves")
        XCTAssertNil(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/ghost")],
                     "nothing is ever written to an alarm his own app will not show him")
        XCTAssertNil(RemoteAlarmLink.alarmID(for: "weekdays", on: .eightSleep).flatMap { $0 == "ghost" ? $0 : nil },
                     "and it is not recorded as owned either")
    }

    /// A link already pointing at a hidden alarm is dropped rather than honoured.
    ///
    /// His account is already in this state, so the fix has to repair it rather than only prevent it.
    /// Dropping the link lets the routine fall through to a visible alarm on the same run.
    func testALinkToAHiddenAlarmIsDropped() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [
                    hiddenAlarm(id: "ghost", time: "05:55:00", days: weekdayNames),
                    alarm(id: "his", time: "05:57:00", days: weekdayNames, routine: nil),
                ],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/ghost"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "ghost", on: .eightSleep)

        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50)],
            skipsNextMorning: false
        )

        _ = try await adapter().write(target, plan: plan)

        XCTAssertNil(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/ghost")],
                     "an old link is not a reason to keep writing to something he cannot see")
        XCTAssertEqual(RemoteAlarmLink.alarmID(for: "weekdays", on: .eightSleep), "his",
                       "the routine re-homes onto the alarm his app actually lists")
    }

    /// The picker marks a hidden alarm as hidden, so the screen can give the true reason.
    ///
    /// The bed screen said "no routine has these days, so OneAlarm never touches it" about both of
    /// the hidden alarms on his account. That is false: `05:55, weekdays` has exactly the days his
    /// Weekdays routine has. The true reason is that his Eight Sleep app will not show it. A screen
    /// giving the wrong reason is worse than one giving none, because it is where somebody goes to
    /// rule a cause out.
    func testThePickerMarksAlarmsHisOwnAppWillNotShow() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [
                    hiddenAlarm(id: "ghost", time: "05:55:00", days: weekdayNames),
                    alarm(id: "his", time: "05:51:00", days: weekdayNames, routine: nil),
                ],
            ]),
        ]

        let choices = try await adapter().availableAlarms()

        XCTAssertEqual(choices.count, 2, "a hidden alarm is still listed, because he needs to know it exists")
        XCTAssertEqual(choices.first { $0.id == "ghost" }?.isHidden, true)
        XCTAssertEqual(choices.first { $0.id == "his" }?.isHidden, false)
    }

    // MARK: Clearing up after ourselves

    /// Only the hidden, recurring, still-on alarms are offered for switching off.
    ///
    /// The nap filter is the one that matters. A nap Alex starts from the Nap tool in the Eight Sleep
    /// app would carry the same tags, and switching off something he just set going is exactly the
    /// "never silently change a setting Alex chose" failure this project has a rule about. A real nap
    /// is a one-off with no day set; both of the alarms this exists for carry days.
    func testOnlyHiddenRecurringAlarmsAreOfferedForSwitchingOff() async throws {
        var oneOffNap = hiddenAlarm(id: "nap", time: "14:00:00", days: [])
        oneOffNap["repeat"] = ["enabled": false, "weekDays": [String: Bool]()] as [String: Any]
        var alreadyOff = hiddenAlarm(id: "done", time: "09:56:00", days: ["saturday", "sunday"])
        alreadyOff["enabled"] = false

        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [
                    alarm(id: "his", time: "05:51:00", days: weekdayNames, routine: nil),
                    hiddenAlarm(id: "ghost", time: "05:55:00", days: weekdayNames),
                    oneOffNap,
                    alreadyOff,
                ],
            ]),
        ]

        let retired = try await adapter().retiredAlarms()

        XCTAssertEqual(retired.map(\.id), ["ghost"])
        XCTAssertFalse(retired.contains { $0.id == "his" }, "never an alarm he can see")
        XCTAssertFalse(retired.contains { $0.id == "nap" }, "never a nap he started himself")
        XCTAssertFalse(retired.contains { $0.id == "done" }, "and running it twice is not a second write")
    }

    /// Switching off writes `enabled: false` and changes nothing else about the alarm.
    func testSwitchingOffKeepsEverythingButTheSwitch() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [hiddenAlarm(id: "ghost", time: "05:55:00", days: weekdayNames)],
            ]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/ghost"): accepted,
        ]

        let report = try await adapter().silenceAlarms(["ghost"])

        let body = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/ghost")])
        XCTAssertEqual(body["enabled"] as? Bool, false)
        XCTAssertEqual(body["time"] as? String, "05:55:00", "off, not deleted, and not moved")
        XCTAssertNotNil(body["vibration"])
        XCTAssertNotNil(body["thermal"])
        XCTAssertEqual(report, ["05:55 weekdays is off"])
    }

    /// An id that names a visible alarm is refused, even though the caller asked for it.
    ///
    /// The ids come from a confirmation dialog, and a dialog is not evidence about what is on the
    /// account by the time the write runs. This is the assertion that stands between a bug in that
    /// screen and Alex's real alarm being switched off in the night.
    func testSwitchingOffRefusesAnAlarmHeCanSee() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [alarm(id: "his", time: "05:51:00", days: weekdayNames, routine: nil)],
            ]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
        ]

        let report = try await adapter().silenceAlarms(["his"])

        XCTAssertNil(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/his")],
                     "his own alarm is never switched off, whatever the caller passed")
        XCTAssertEqual(report, ["05:51 weekdays was left alone, it is not one of these"])
    }

    // MARK: Deleting, which only ever applies to alarms OneAlarm made

    /// An alarm OneAlarm created, whose routine is gone, is deleted.
    ///
    /// Alex, 17 August: *"the one alarm app should be able to delete alarms if there are changes
    /// because right now for whatever reason I had three alarms in my sleep app and I had to delete
    /// all the alarms in the eight sleep app and set all alarms again from the one alarm app."*
    /// Before this, an orphan was switched off, which left litter on his bed that only he could tidy.
    func testAnAlarmOneAlarmCreatedIsDeletedWhenItsRoutineIsGone() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [
                    alarm(id: "live", time: "06:50:00", days: weekdayNames, routine: nil),
                    alarm(id: "ours", time: "09:00:00", days: ["saturday", "sunday"], routine: nil),
                ],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/live"): accepted,
            StubServer.key("DELETE", "/v1/users/\(userID)/alarms/ours"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "live", on: .eightSleep)
        RemoteAlarmLink.link(routine: "weekend", to: "ours", on: .eightSleep)
        RemoteAlarmLink.markCreated("ours", on: .eightSleep)

        // The weekend routine has been deleted in OneAlarm: it is absent from the plan.
        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50)],
            skipsNextMorning: false
        )

        let receipt = try await adapter().write(target, plan: plan)

        XCTAssertTrue(StubServer.calls.contains(StubServer.Call(method: "DELETE", path: "/v1/users/\(userID)/alarms/ours")),
                      "an alarm OneAlarm made, for a routine that is gone, is removed rather than left switched off")
        XCTAssertNil(RemoteAlarmLink.alarmID(for: "weekend", on: .eightSleep))
        XCTAssertFalse(RemoteAlarmLink.created(for: .eightSleep).contains("ours"),
                       "and it leaves the created list, so a later id reuse cannot inherit permission to delete")
        XCTAssertTrue((receipt.note ?? "").contains("Deleted"), "a delete is never silent")
    }

    /// **The one that matters most.** An alarm Alex made himself is never deleted, whatever happens.
    ///
    /// Same situation as the test above in every respect except provenance: the orphan is not on the
    /// created list, because he made it or because OneAlarm adopted it for matching days. Adoption is
    /// not authorship. It is switched off, which he can undo in the Eight Sleep app in one tap.
    func testAnAlarmHeMadeIsNeverDeleted() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [
                    alarm(id: "live", time: "06:50:00", days: weekdayNames, routine: nil),
                    alarm(id: "his", time: "09:00:00", days: ["saturday", "sunday"], routine: nil),
                ],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/live"): accepted,
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
            StubServer.key("DELETE", "/v1/users/\(userID)/alarms/his"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "live", on: .eightSleep)
        RemoteAlarmLink.link(routine: "weekend", to: "his", on: .eightSleep)
        // Deliberately NOT marked created.

        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50)],
            skipsNextMorning: false
        )

        _ = try await adapter().write(target, plan: plan)

        XCTAssertFalse(StubServer.calls.contains { $0.method == "DELETE" },
                       "OneAlarm never deletes an alarm it did not make, even with the endpoint stubbed to succeed")
        let body = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/his")])
        XCTAssertEqual(body["enabled"] as? Bool, false, "his is switched off instead, which is reversible")
    }

    /// A refused delete falls back to switching off rather than reporting success.
    ///
    /// The delete address is the PUT path with a different verb, which is a REST convention and not a
    /// captured request. Nothing public documents a delete on this API and no session can reach the
    /// host to probe it. So the failure path is the one that has to be right: `E20`.
    func testARefusedDeleteFallsBackToSwitchingOff() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [
                    alarm(id: "live", time: "06:50:00", days: weekdayNames, routine: nil),
                    alarm(id: "ours", time: "09:00:00", days: ["saturday", "sunday"], routine: nil),
                ],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/live"): accepted,
            StubServer.key("DELETE", "/v1/users/\(userID)/alarms/ours"): (405, ["message": "method not allowed"]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/ours"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "live", on: .eightSleep)
        RemoteAlarmLink.link(routine: "weekend", to: "ours", on: .eightSleep)
        RemoteAlarmLink.markCreated("ours", on: .eightSleep)

        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50)],
            skipsNextMorning: false
        )

        let receipt = try await adapter().write(target, plan: plan)
        let note = try XCTUnwrap(receipt.note)

        XCTAssertTrue(note.contains("405"), "the status is named, so one round trip settles E20")
        let body = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/ours")])
        XCTAssertEqual(body["enabled"] as? Bool, false, "and it ends up switched off, no worse than before delete existed")
    }

    /// A live routine's alarm is never deleted, however it was made.
    ///
    /// The orphan check is what gates this, and getting it backwards would delete the alarm that is
    /// about to ring. Cheap to assert, and the failure has no symptom until a morning is missed.
    func testAnAlarmWithALivingRoutineIsNeverDeleted() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [alarm(id: "ours", time: "06:50:00", days: weekdayNames, routine: nil)],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/ours"): accepted,
            StubServer.key("DELETE", "/v1/users/\(userID)/alarms/ours"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "ours", on: .eightSleep)
        RemoteAlarmLink.markCreated("ours", on: .eightSleep)

        let plan = RoutinePlan(
            device: .eightSleep,
            entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50)],
            skipsNextMorning: false
        )

        _ = try await adapter().write(target, plan: plan)

        XCTAssertFalse(StubServer.calls.contains { $0.method == "DELETE" },
                       "the routine is alive, so its alarm is written to and never removed")
    }

    /// The template for a create is an alarm he can see, so the settings copied are ones he chose.
    ///
    /// Stripping `tags` breaks the inheritance loop on its own. This closes the other half: copying
    /// a hidden alarm's vibration and thermal would copy whatever state made it a nap timer.
    func testTheCreateTemplateIsAVisibleAlarm() {
        let hidden = hiddenAlarm(id: "ghost", time: "05:55:00", days: weekdayNames)
        let his = alarm(id: "his", time: "05:57:00", days: weekdayNames, routine: nil)

        let chosen = EightSleepAdapter.template(from: [hidden, his])
        XCTAssertEqual(chosen?["id"] as? String, "his", "a visible alarm wins even when listed second")

        // With nothing visible there is still a template, because a real object from his account
        // always beats one composed here. The tag is stripped by `clone` either way.
        let onlyHidden = EightSleepAdapter.template(from: [hidden])
        XCTAssertEqual(onlyHidden?["id"] as? String, "ghost", "and absence of a visible one is not a crash")
    }
}
