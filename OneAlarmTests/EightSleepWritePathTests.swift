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

    private func routine(id: String, days: [String], bedtime: String = "23:00:00") -> [String: Any] {
        [
            "id": id,
            "enabled": true,
            "days": days,
            // The field that must survive untouched. When he goes to bed is not an alarm setting.
            "bedtime": ["time": bedtime, "dayOffset": 0] as [String: Any],
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
    /// Off, never deleted: there is no DELETE on either service and there is not going to be one.
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
        // Both were OneAlarm's. The weekend routine has since been deleted in the app.
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
}
