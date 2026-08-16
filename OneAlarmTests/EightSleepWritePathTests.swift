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

    /// The Monday to Friday routine with a one day override armed on a given January 2027 date.
    ///
    /// The date is what makes these tests real. `bentTo` on its own says what time and not which
    /// morning, which is precisely why this leg could only ever rewrite the routine's own alarm.
    private func bent(onDay day: Int, at hour: Int, _ minute: Int) -> RoutinePlan.Entry {
        var base = entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 5)
        base.overrideDay = RoutinePlan.OverrideDay(
            date: CalendarDay(year: 2027, month: 1, day: day),
            weekday: Locale.Weekday.from(
                calendarIndex: Calendar(identifier: .gregorian).component(
                    .weekday,
                    from: CalendarDay(year: 2027, month: 1, day: day)
                        .date(in: Calendar(identifier: .gregorian)) ?? Date()
                )
            )
        )
        return RoutinePlan.Entry(
            routineID: base.routineID, routineName: base.routineName, weekdays: base.weekdays,
            localTime: base.localTime, bentTo: WallClockTime(hour: hour, minute: minute),
            isOn: base.isOn, isSkippedNextMorning: false, overrideDay: base.overrideDay
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

    /// A bend leaves the routine's own alarm alone and adds a single day alarm beside it.
    ///
    /// **This test asserted the opposite until 18 August, and the opposite was the bug.** It checked
    /// that the bent time landed on the routine's own alarm, which is exactly what Alex reported:
    /// *"the one time change, even though it's placed correctly on the OneAlarm app, instead of
    /// changing it for one time, it changes the entire Monday to Friday routine on Eight Sleep."*
    /// An Eight Sleep alarm has one wall clock for its whole day set, so writing the override into
    /// `time` moves every morning that routine covers, and only a later sync puts it back.
    ///
    /// A green test asserting the broken behaviour is worse than no test. It is the reason nobody
    /// looked here.
    func testABendLeavesTheRoutineAlarmAloneAndAddsItsOwn() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [alarm(id: "his", time: "05:51:00", days: weekdayNames, routine: nil)],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
            StubServer.key("POST", "/v1/users/\(userID)/alarms"): (200, ["id": "oneoff-1"] as [String: Any]),
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)

        _ = try await adapter().write(
            target,
            // Tuesday 19 January 2027, and the routine runs Monday to Friday, so the override falls
            // on a morning this routine actually covers.
            plan: RoutinePlan(device: .eightSleep, entries: [bent(onDay: 19, at: 6, 20)],
                              skipsNextMorning: false)
        )

        let weekly = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/his")])
        XCTAssertEqual(weekly["time"] as? String, "06:05:00",
                       "the routine keeps its own time. Bending it moves every weekday, which is the bug")
        XCTAssertEqual(weekly["enabled"] as? Bool, true, "and is not switched off")
        let weeklyDays = (weekly["repeat"] as? [String: Any])?["weekDays"] as? [String: Bool]
        XCTAssertEqual(weeklyDays?["monday"], true, "and keeps all five days")
        XCTAssertEqual(weeklyDays?["friday"], true)

        let created = try XCTUnwrap(StubServer.bodies[StubServer.key("POST", "/v1/users/\(userID)/alarms")],
                                    "the override has to go somewhere, and its own alarm is the only place")
        XCTAssertEqual(created["time"] as? String, "06:20:00", "the new alarm carries the override time")
        let oneDay = (created["repeat"] as? [String: Any])?["weekDays"] as? [String: Bool]
        XCTAssertEqual(oneDay?["tuesday"], true, "on the one weekday the override falls on")
        XCTAssertEqual(oneDay?["monday"], false, "and on no other")
        XCTAssertEqual(oneDay?["wednesday"], false)
        // His settings ride along, because the new alarm is a copy of one he already has.
        XCTAssertNotNil(created["vibration"])
        XCTAssertNotNil(created["thermal"])
    }

    /// The override's alarm is recorded as OneAlarm's, which is the only thing that can delete it.
    ///
    /// Without the link it is litter: an alarm on his bed that rings every Tuesday at 06:20 forever,
    /// that OneAlarm will not touch because it cannot prove it made it. The expiry sweep is driven
    /// entirely off this record.
    func testTheOverrideAlarmIsRecordedSoItCanBeCleanedUp() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [alarm(id: "his", time: "05:51:00", days: weekdayNames, routine: nil)],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
            StubServer.key("POST", "/v1/users/\(userID)/alarms"): (200, ["id": "oneoff-1"] as [String: Any]),
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)

        _ = try await adapter().write(
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [bent(onDay: 19, at: 6, 20)],
                              skipsNextMorning: false)
        )

        XCTAssertTrue(RemoteAlarmLink.created(for: .eightSleep).contains("oneoff-1"),
                      "provenance, or it can never be deleted")
        let key = "oneoff:weekdays:20270119"
        XCTAssertEqual(RemoteAlarmLink.all(for: .eightSleep)[key], "oneoff-1",
                       "filed under a key carrying the date, which is what expires it")
    }

    /// A second sync moves the override's alarm rather than making another one.
    ///
    /// He changes his mind about the time. The first version of this feature would have posted a
    /// second alarm, and the one after that a third, until the eight alarm ceiling stopped it. The
    /// recorded link is what makes the difference.
    func testChangingTheOverrideMovesTheSameAlarm() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [
                    alarm(id: "his", time: "05:51:00", days: weekdayNames, routine: nil),
                    alarm(id: "oneoff-1", time: "06:20:00", days: ["tuesday"], routine: nil),
                ],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/oneoff-1"): accepted,
            StubServer.key("POST", "/v1/users/\(userID)/alarms"): (200, ["id": "oneoff-2"] as [String: Any]),
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)
        RemoteAlarmLink.link(routine: "oneoff:weekdays:20270119", to: "oneoff-1", on: .eightSleep)

        _ = try await adapter().write(
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [bent(onDay: 19, at: 7, 30)],
                              skipsNextMorning: false)
        )

        XCTAssertNil(StubServer.bodies[StubServer.key("POST", "/v1/users/\(userID)/alarms")],
                     "no second override alarm")
        let moved = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/oneoff-1")])
        XCTAssertEqual(moved["time"] as? String, "07:30:00", "the one he already has is moved")
    }

    /// The override's alarm is not adopted by another routine, and is not reported as stranded.
    ///
    /// It has exactly one day, so a one day routine of his could match it on days alone and take it
    /// over, and then the expiry sweep would be deleting an alarm somebody else was using. The
    /// recorded link claims it before matching runs.
    func testTheOverrideAlarmIsNotAdoptedByARoutine() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [
                    alarm(id: "his", time: "05:51:00", days: weekdayNames, routine: nil),
                    alarm(id: "oneoff-1", time: "06:20:00", days: ["tuesday"], routine: nil),
                ],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/oneoff-1"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)
        RemoteAlarmLink.link(routine: "oneoff:weekdays:20270119", to: "oneoff-1", on: .eightSleep)

        // A Tuesday-only routine of his own, with nothing to match but the override's alarm.
        let tuesday = entry("tuesdays", "Tuesdays", [.tuesday], hour: 8)
        let receipt = try await adapter().write(
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [bent(onDay: 19, at: 6, 20), tuesday],
                              skipsNextMorning: false)
        )

        let stillTheOverride = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/oneoff-1")])
        XCTAssertEqual(stillTheOverride["time"] as? String, "06:20:00",
                       "the override's alarm was not taken over and rewritten to 08:00")
        XCTAssertFalse(receipt.note.contains("match no routine"),
                       "and it is not reported to him as an alarm nobody is using")
    }

    // MARK: The week, checked morning by morning

    // Alex's diagnosis of the last weakness, 18 August: *"if you set it up this way to match the
    // actual settings in the apps, then it usually works because then it gets the right data. The
    // problem is when something changes, if one alarm would change the entire thing then it usually
    // doesn't work."*
    //
    // One finding only: a morning a routine covers with nothing on the bed to ring on it. That is
    // the direction with no other symptom until he does not wake up. The loud direction, an alarm
    // ringing that nothing asked for, is left to the stranded-alarm line on the same row.
    //
    // Most of these tests assert **silence**. This line sits next to ONE TIME CHECK, and a check
    // that fires on a healthy week is one he learns to scroll past.

    /// A week where every morning agrees says nothing at all.
    func testAWholeWeekReportsNothing() {
        let findings = EightSleepAdapter.weekFindings(
            alarms: [
                alarm(id: "week", time: "06:05:00", days: weekdayNames, routine: nil),
                alarm(id: "wend", time: "09:55:00", days: ["saturday", "sunday"], routine: nil),
            ],
            entries: [
                entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 5),
                entry("weekend", "Weekend", [.saturday, .sunday], hour: 9, minute: 55),
            ]
        )
        XCTAssertEqual(findings, [], "a healthy week is silent, or the check gets ignored")
    }

    /// A morning a routine covers with nothing on the bed to ring is named.
    ///
    /// The dangerous direction, and the one with no other symptom until he does not wake up. It is
    /// what a refused create leaves behind, and what widening a routine's days produces when the
    /// alarm that used to serve it no longer matches.
    func testASilentMorningIsNamed() {
        let findings = EightSleepAdapter.weekFindings(
            alarms: [alarm(id: "week", time: "06:05:00", days: ["monday", "tuesday"], routine: nil)],
            entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 5)]
        )
        XCTAssertEqual(findings.count, 3, "Wednesday, Thursday and Friday")
        XCTAssertTrue(findings.contains { $0.contains("We") && $0.contains("not be woken") }, "\(findings)")
    }

    /// An alarm ringing at a time nothing asked for is deliberately NOT reported here.
    ///
    /// The first version of `weekFindings` did report it, and it was cut before shipping: the
    /// stranded-alarm line on the same row already says it, by alarm rather than by day, and it says
    /// what to do about it. Two sentences about one alarm in two vocabularies is how a row stops
    /// being read. This test pins the decision so it is not quietly re-added.
    func testTheWeekCheckLeavesTheLoudDirectionToTheStrandedLine() {
        let findings = EightSleepAdapter.weekFindings(
            alarms: [
                alarm(id: "week", time: "06:05:00", days: weekdayNames, routine: nil),
                alarm(id: "ghost", time: "05:30:00", days: ["monday"], routine: nil),
            ],
            entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 5)]
        )
        XCTAssertEqual(findings, [], "Monday is covered. That the extra alarm exists is said elsewhere")
    }

    /// A morning covered only by the one day override still counts as covered.
    ///
    /// The override can fall on a morning no routine covers, and its own alarm is real coverage for
    /// that day. A week check that ignored it would report "you will not be woken" on the one morning
    /// the app is most likely to be asked about.
    func testTheOverridesOwnAlarmCountsAsCoverage() {
        let override = bent(onDay: 19, at: 6, 20)
        // No routines at all, so Tuesday is expected only because the override says so.
        XCTAssertEqual(
            EightSleepAdapter.weekFindings(
                alarms: [alarm(id: "oneoff-1", time: "06:20:00", days: ["tuesday"], routine: nil)],
                entries: [],
                overrides: [override]
            ),
            [], "the override's own alarm covers that morning"
        )
        // And the same morning with nothing on the bed is a real gap, not an ignored day.
        let gap = EightSleepAdapter.weekFindings(alarms: [], entries: [], overrides: [override])
        XCTAssertEqual(gap.count, 1, "\(gap)")
        XCTAssertTrue(gap[0].contains("Tu"), gap[0])
    }

    /// A skipped morning is judged neither way.
    ///
    /// **Two opposite false positives from one feature.** Eight Sleep's native skip leaves the alarm
    /// switched on at its ordinary time, so the stranger check would report the routine's own alarm.
    /// The fallback switches it off, so the silent check would report a morning he cleared on purpose
    /// as one he will not wake up on. Both are wrong, so the day is not judged.
    func testASkippedMorningIsNotJudged() {
        let base = entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 5)
        let skipped = RoutinePlan.Entry(
            routineID: base.routineID, routineName: base.routineName, weekdays: base.weekdays,
            localTime: base.localTime, bentTo: nil, isOn: true, isSkippedNextMorning: true
        )
        // The fallback path: the alarm is switched off, so no weekday has anything ringing.
        let findings = EightSleepAdapter.weekFindings(
            alarms: [alarm(id: "week", time: "06:05:00", days: weekdayNames, routine: nil, enabled: false)],
            entries: [skipped]
        )
        XCTAssertEqual(findings, [], "a skip is a choice, not a broken morning")
    }

    /// A switched off routine is not a silent morning.
    ///
    /// Turning a routine off in OneAlarm means no alarm that morning, so nothing is missing. Firing
    /// here would put a warning on his screen for a setting he chose.
    func testASwitchedOffRoutineIsNotAMissingMorning() {
        let off = entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 5, isOn: false)
        XCTAssertEqual(
            EightSleepAdapter.weekFindings(alarms: [], entries: [off]), [],
            "a routine he turned off is not a morning he is missing"
        )
    }

    /// An alarm Eight Sleep's own app hides is not counted as covering a morning.
    ///
    /// Two of these are on his real account, both enabled and both ringing. Counting one as coverage
    /// would report a genuinely silent morning as fine, on the strength of an alarm he cannot see or
    /// switch off.
    func testAHiddenAlarmDoesNotCountAsCoverage() {
        let findings = EightSleepAdapter.weekFindings(
            alarms: [hiddenAlarm(id: "nap", time: "06:05:00", days: weekdayNames)],
            entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 5)]
        )
        XCTAssertEqual(findings.count, 5, "all five mornings are genuinely uncovered")
    }

    /// A morning no routine covers is left alone entirely.
    ///
    /// Saturday is his, and an alarm on it is his business. The stranded-alarm line already reports
    /// these by alarm rather than by day, and saying the same thing twice in two vocabularies is
    /// worse than saying it once.
    func testAMorningNoRoutineCoversIsNotJudged() {
        let findings = EightSleepAdapter.weekFindings(
            alarms: [
                alarm(id: "week", time: "06:05:00", days: weekdayNames, routine: nil),
                // Saturday is his. Nothing in OneAlarm describes it.
                alarm(id: "his", time: "11:00:00", days: ["saturday"], routine: nil),
            ],
            entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 5)]
        )
        XCTAssertEqual(findings, [], "\(findings)")
    }

    // MARK: The app answers "did it work", instead of asking him to

    /// The verdict when it worked: routine intact, override present.
    func testTheVerdictNamesASuccess() {
        let verdict = EightSleepAdapter.oneOffVerdict(
            alarms: [
                alarm(id: "his", time: "06:05:00", days: weekdayNames, routine: nil),
                alarm(id: "oneoff-1", time: "06:20:00", days: ["tuesday"], routine: nil),
            ],
            routineAlarmID: "his",
            routineTime: WallClockTime(hour: 6, minute: 5),
            overrideTime: WallClockTime(hour: 6, minute: 20),
            weekday: .tuesday
        )
        XCTAssertTrue(verdict.contains("This worked"), verdict)
    }

    /// The verdict when the bug is back: the routine's own alarm carries the override's time.
    ///
    /// **The one that matters.** This is the failure Alex found on his bed on 17 August, and the
    /// whole rebuild exists to prevent it. If this string ever appears on his screen, the fix has
    /// regressed, and it says so in the words he used rather than leaving him to compare times.
    func testTheVerdictNamesTheWholeSeriesMoving() {
        let verdict = EightSleepAdapter.oneOffVerdict(
            alarms: [alarm(id: "his", time: "06:20:00", days: weekdayNames, routine: nil)],
            routineAlarmID: "his",
            routineTime: WallClockTime(hour: 6, minute: 5),
            overrideTime: WallClockTime(hour: 6, minute: 20),
            weekday: .tuesday
        )
        XCTAssertTrue(verdict.contains("moved the whole series"), verdict)
    }

    /// The verdict when the routine is safe but the override never arrived.
    ///
    /// A different failure from the one above and a much less serious one, which is exactly why they
    /// must not share a message: this one means he wakes at his normal time, the other means his
    /// whole week moved.
    func testTheVerdictNamesAMissingOverride() {
        let verdict = EightSleepAdapter.oneOffVerdict(
            alarms: [alarm(id: "his", time: "06:05:00", days: weekdayNames, routine: nil)],
            routineAlarmID: "his",
            routineTime: WallClockTime(hour: 6, minute: 5),
            overrideTime: WallClockTime(hour: 6, minute: 20),
            weekday: .tuesday
        )
        XCTAssertTrue(verdict.contains("did not land"), verdict)
    }

    /// An alarm at the right time on the wrong days does not count as the override.
    ///
    /// The loose version of this check would match any alarm reading 06:20, including his weekend
    /// one. Then a verdict of "this worked" would be produced by an alarm that has nothing to do
    /// with the override, which is the failure mode of every check that matches on one field.
    func testTheVerdictDoesNotAcceptTheRightTimeOnTheWrongDays() {
        let verdict = EightSleepAdapter.oneOffVerdict(
            alarms: [
                alarm(id: "his", time: "06:05:00", days: weekdayNames, routine: nil),
                alarm(id: "wend", time: "06:20:00", days: ["saturday", "sunday"], routine: nil),
            ],
            routineAlarmID: "his",
            routineTime: WallClockTime(hour: 6, minute: 5),
            overrideTime: WallClockTime(hour: 6, minute: 20),
            weekday: .tuesday
        )
        XCTAssertTrue(verdict.contains("did not land"), verdict)
    }

    /// Seconds are not part of the comparison. The account spells the same time both ways.
    func testTheVerdictIgnoresSeconds() {
        var short = alarm(id: "his", time: "06:05:00", days: weekdayNames, routine: nil)
        short["time"] = "06:05"
        let verdict = EightSleepAdapter.oneOffVerdict(
            alarms: [short, alarm(id: "oneoff-1", time: "06:20", days: ["tuesday"], routine: nil)],
            routineAlarmID: "his",
            routineTime: WallClockTime(hour: 6, minute: 5),
            overrideTime: WallClockTime(hour: 6, minute: 20),
            weekday: .tuesday
        )
        XCTAssertTrue(verdict.contains("This worked"), verdict)
    }

    /// The verdict reaches the row he actually reads, and is not merely computable.
    ///
    /// A check nobody sees is not a check. This is the assertion that fails if the wiring is dropped
    /// while the pure function keeps passing its own tests.
    func testTheVerdictReachesTheReceipt() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [alarm(id: "his", time: "06:05:00", days: weekdayNames, routine: nil)],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
            StubServer.key("POST", "/v1/users/\(userID)/alarms"): (200, ["id": "oneoff-1"] as [String: Any]),
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)

        let receipt = try await adapter().write(
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [bent(onDay: 19, at: 6, 20)],
                              skipsNextMorning: false)
        )

        XCTAssertTrue(receipt.note.contains("ONE TIME CHECK"), receipt.note)
        // The stub keeps returning the pre-create list, so the override is genuinely absent from the
        // read back and the honest verdict is that it did not land. Asserting the negative here on
        // purpose: a check that cannot say no is not a check.
        XCTAssertTrue(receipt.note.contains("did not land"), receipt.note)
    }

    /// A one time change that worked perfectly still reaches the screen.
    ///
    /// **The bug this pins would have wasted his whole test.** A clean write reports as
    /// `isPartial == false`, and on that path `ScheduleStore` throws `note` away and prints
    /// "Set for 06:05" alone. So a one time change that went exactly right said nothing at all, and
    /// he had been asked to read that line back and send it.
    ///
    /// `highlights` is the channel that survives a success. Anything he must see whether or not
    /// something went wrong goes in it, and nothing else does: the rest of `note` is routine chatter
    /// that a successful row already says in its own words.
    func testTheVerdictSurvivesAWriteThatWentPerfectly() async throws {
        let created = alarm(id: "oneoff-1", time: "06:20:00", days: ["tuesday"], routine: nil)
        StubServer.sequences = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): [
                (200, ["alarms": [alarm(id: "his", time: "06:05:00", days: weekdayNames, routine: nil)]] as [String: Any]),
                (200, ["alarms": [alarm(id: "his", time: "06:05:00", days: weekdayNames, routine: nil)]] as [String: Any]),
                // The final read back, after the create: both alarms are really there.
                (200, ["alarms": [alarm(id: "his", time: "06:05:00", days: weekdayNames, routine: nil), created]] as [String: Any]),
            ],
        ]
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
            StubServer.key("POST", "/v1/users/\(userID)/alarms"): (200, ["id": "oneoff-1"] as [String: Any]),
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)

        let receipt = try await adapter().write(
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [bent(onDay: 19, at: 6, 20)],
                              skipsNextMorning: false)
        )

        XCTAssertFalse(receipt.isPartial, "everything worked, so this is not a warning")
        XCTAssertTrue(receipt.highlights.contains { $0.contains("This worked") },
                      "\(receipt.highlights)")
    }

    /// A silent morning is a highlight too, not only a note.
    ///
    /// It makes the write partial, so it would reach the screen either way today. It is in
    /// `highlights` so that stays true if the partial rules ever change: a morning with no alarm on
    /// it is the one sentence that must never depend on another flag being set.
    func testASilentMorningIsAHighlight() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                // Covers Monday and Tuesday only, against a Monday to Friday routine.
                "alarms": [alarm(id: "his", time: "06:05:00", days: ["monday", "tuesday"], routine: nil)],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)

        let receipt = try await adapter().write(
            target,
            plan: RoutinePlan(
                device: .eightSleep,
                entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 5)],
                skipsNextMorning: false
            )
        )

        XCTAssertTrue(receipt.isPartial, "a hole in the week is never a green tick")
        XCTAssertTrue(receipt.highlights.contains { $0.contains("not be woken") }, "\(receipt.highlights)")
    }

    /// A create that returns no id is found by reading the account back.
    ///
    /// **The one path that used to leave litter on his bed.** The alarm is real either way; without
    /// an id it cannot be linked, and an alarm OneAlarm cannot prove it made is never deleted by the
    /// sweep. So a one time change would have rung every week at the override time until he noticed
    /// and cleared it by hand, which is the chore he asked never to do again: *"I had to delete all
    /// the alarms in the eight sleep app and set all alarms again from the one alarm app."*
    ///
    /// Solved the way the routine create path already solves it: take the id that was not there
    /// before.
    func testACreateWithNoIdIsIdentifiedByReadingBack() async throws {
        let his = alarm(id: "his", time: "06:05:00", days: weekdayNames, routine: nil)
        let mystery = alarm(id: "oneoff-1", time: "06:20:00", days: ["tuesday"], routine: nil)
        StubServer.sequences = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): [
                (200, ["alarms": [his]] as [String: Any]),            // the first read
                (200, ["alarms": [his]] as [String: Any]),            // before the one-off pass
                (200, ["alarms": [his, mystery]] as [String: Any]),   // the hunt for the new id
                (200, ["alarms": [his, mystery]] as [String: Any]),   // the final read back
            ],
        ]
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
            // Accepted, and the body carries no id anywhere.
            StubServer.key("POST", "/v1/users/\(userID)/alarms"): (200, ["ok": true] as [String: Any]),
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)

        let receipt = try await adapter().write(
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [bent(onDay: 19, at: 6, 20)],
                              skipsNextMorning: false)
        )

        XCTAssertEqual(RemoteAlarmLink.all(for: .eightSleep)["oneoff:weekdays:20270119"], "oneoff-1")
        XCTAssertTrue(RemoteAlarmLink.created(for: .eightSleep).contains("oneoff-1"),
                      "provenance, or the sweep can never remove it")
        XCTAssertFalse(receipt.note.contains("Delete it in the Eight Sleep app"), receipt.note)
    }

    /// Two new alarms at once claims neither, and says so.
    ///
    /// Guessing which of two is the override would put a delete licence on an alarm that might be
    /// his. Being told to tidy one thing by hand is a far smaller cost than an alarm of his being
    /// deleted by a sweep that was sure.
    func testTwoNewAlarmsAtOnceClaimsNeither() async throws {
        let his = alarm(id: "his", time: "06:05:00", days: weekdayNames, routine: nil)
        let a = alarm(id: "new-a", time: "06:20:00", days: ["tuesday"], routine: nil)
        let b = alarm(id: "new-b", time: "06:20:00", days: ["tuesday"], routine: nil)
        StubServer.sequences = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): [
                (200, ["alarms": [his]] as [String: Any]),
                (200, ["alarms": [his]] as [String: Any]),
                (200, ["alarms": [his, a, b]] as [String: Any]),
                (200, ["alarms": [his, a, b]] as [String: Any]),
            ],
        ]
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
            StubServer.key("POST", "/v1/users/\(userID)/alarms"): (200, ["ok": true] as [String: Any]),
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)

        let receipt = try await adapter().write(
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [bent(onDay: 19, at: 6, 20)],
                              skipsNextMorning: false)
        )

        XCTAssertTrue(RemoteAlarmLink.created(for: .eightSleep).isEmpty,
                      "neither is claimed, because either could be his")
        XCTAssertTrue(receipt.isPartial, "and it is a warning, not a green tick")
        XCTAssertTrue(receipt.note.contains("could not tell which one it is"), receipt.note)
    }

    // MARK: The gate has to describe what will actually be sent

    /// The preview shows the routine's own time, not the override's.
    ///
    /// **A gate that lies is worse than no gate**, because it is where you go to rule something out.
    /// This project paid for that once: the preview claimed to be built by the same code as the real
    /// request, was a reconstruction, and omitted the field most likely to be causing a refusal.
    ///
    /// It said "Weekdays to 08:05" from 18 August, because it read `timeToWrite`, which returns the
    /// bent time. The write sends 06:05. The one number the gate exists to show was the one it had
    /// wrong.
    func testThePreviewShowsTheRoutineTimeNotTheOverride() async {
        let preview = await adapter().preview(
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [bent(onDay: 19, at: 8, 5)],
                              skipsNextMorning: false)
        )

        XCTAssertTrue(preview.summary.contains("06:05"), preview.summary)
        XCTAssertFalse(preview.summary.contains("Weekdays (5 days) to 08:05"), preview.summary)
    }

    /// The preview names the two extra requests a one time change makes.
    ///
    /// It described "one PUT per routine" while the write was about to POST a new alarm and PUT a
    /// skip. Two requests to his live account that the safety screen did not mention.
    func testThePreviewNamesTheOverridesOwnRequests() async {
        let preview = await adapter().preview(
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [bent(onDay: 19, at: 8, 5)],
                              skipsNextMorning: false)
        )

        XCTAssertTrue(preview.summary.contains("POST"), preview.summary)
        XCTAssertTrue(preview.summary.contains("skipNext"), preview.summary)
        XCTAssertTrue(preview.summary.contains("Tu 08:05"), preview.summary)
    }

    /// With no override, the gate says nothing about one. The control.
    func testThePreviewIsQuietWithNoOverride() async {
        let preview = await adapter().preview(
            target,
            plan: RoutinePlan(
                device: .eightSleep,
                entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 5)],
                skipsNextMorning: false
            )
        )

        XCTAssertFalse(preview.summary.contains("one time change"), preview.summary)
    }

    /// Signing out forgets which alarms OneAlarm made, not just which routine owns which.
    ///
    /// The created list is the only thing that licenses a delete. Left behind across a sign out it
    /// would be a list of ids from a previous account marked safe to delete, checked against a new
    /// account's alarms. Eight Sleep ids are opaque and nothing promises they do not collide.
    func testSigningOutForgetsProvenanceAndNotJustLinks() {
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)
        RemoteAlarmLink.markCreated("his", on: .eightSleep)

        RemoteAlarmLink.forget(for: .eightSleep)

        XCTAssertTrue(RemoteAlarmLink.all(for: .eightSleep).isEmpty)
        XCTAssertTrue(RemoteAlarmLink.created(for: .eightSleep).isEmpty,
                      "or the next account inherits a licence to delete")
    }

    /// The override's alarm is deleted once its morning has passed.
    ///
    /// `RulesEngine` stops emitting an override whose day is behind, so its key stops appearing among
    /// the living routines and the sweep that clears alarms belonging to deleted routines finds it.
    /// Deleted rather than switched off, because OneAlarm made it: leaving it switched off is the
    /// litter Alex cleared by hand and asked never to do again.
    func testTheOverrideAlarmIsDeletedOnceItsMorningHasPassed() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [
                    alarm(id: "his", time: "05:51:00", days: weekdayNames, routine: nil),
                    alarm(id: "oneoff-1", time: "06:20:00", days: ["tuesday"], routine: nil),
                ],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
            StubServer.key("DELETE", "/v1/users/\(userID)/alarms/oneoff-1"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)
        RemoteAlarmLink.link(routine: "oneoff:weekdays:20270119", to: "oneoff-1", on: .eightSleep)
        RemoteAlarmLink.markCreated("oneoff-1", on: .eightSleep)

        // The override is gone from the plan, which is what an expired one looks like from here.
        _ = try await adapter().write(
            target,
            plan: RoutinePlan(
                device: .eightSleep,
                entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 5)],
                skipsNextMorning: false
            )
        )

        XCTAssertTrue(StubServer.calls.contains { $0.method == "DELETE" && $0.path.hasSuffix("/oneoff-1") },
                      "the override's alarm goes away by itself")
        XCTAssertNil(RemoteAlarmLink.all(for: .eightSleep)["oneoff:weekdays:20270119"],
                     "and its link with it")
    }

    /// The routine's own alarm is skipped for that one morning, so the bed does not ring twice.
    ///
    /// Only when the override's morning is genuinely the next one, checked against the server's own
    /// `nextTimestamp` rather than against a calendar of ours. `skipNext` skips the next occurrence
    /// and nothing else, so asking for it three days early would silence the wrong morning.
    func testTheRoutineAlarmIsSkippedOnTheOverrideMorning() async throws {
        // Midday UTC rather than an early morning instant, deliberately. `fires(_:on:)` compares
        // calendar days in the **local** zone, and 05:05Z falls on the day before anywhere west of
        // about UTC-6. A test that passes in Zurich and fails in New York is a test nobody trusts.
        let before = alarm(id: "his", time: "05:51:00", days: weekdayNames, routine: nil)
        var withStamp = before
        withStamp["nextTimestamp"] = "2027-01-19T12:00:00Z"
        var afterSkip = before
        afterSkip["nextTimestamp"] = "2027-01-20T12:00:00Z"

        // **Four reads, counted against the code rather than guessed.** The write reads once at the
        // start, once before the one-off pass, once to check the skip moved `nextTimestamp`, and once
        // at the end for the verdict. A sequence one short does not fail loudly: it falls through to
        // `responses`, which has no alarms entry, so the final read 404s and the verdict quietly does
        // not happen. The test would still pass while testing less than it claims.
        StubServer.sequences = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): [
                (200, ["alarms": [withStamp]] as [String: Any]),   // the first read
                (200, ["alarms": [withStamp]] as [String: Any]),   // re-read before the one-off pass
                (200, ["alarms": [afterSkip]] as [String: Any]),   // the check that the skip took
                (200, ["alarms": [afterSkip]] as [String: Any]),   // the final read back
            ],
        ]
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
            StubServer.key("POST", "/v1/users/\(userID)/alarms"): (200, ["id": "oneoff-1"] as [String: Any]),
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)

        let receipt = try await adapter().write(
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [bent(onDay: 19, at: 6, 20)],
                              skipsNextMorning: false)
        )

        let last = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/his")])
        XCTAssertEqual(last["skipNext"] as? Bool, true, "Eight Sleep's own skip, not enabled: false")
        XCTAssertNotEqual(last["enabled"] as? Bool, false,
                          "and never switched off: no next sync would mean a week with no alarm")
        XCTAssertTrue(receipt.note.contains("Skipped"), "and he is told, on the row he reads")
    }

    /// A skip that does nothing leaves the weekly alarm ringing, and says so.
    ///
    /// The deliberate asymmetry in this leg. Everywhere else a failed skip falls back to switching the
    /// alarm off and repairing it later, and here it does not: if there is no next sync, that costs a
    /// whole week with no alarm, against one morning rung at 06:05 instead of 06:20. Between an alarm
    /// that rings early and an alarm that does not ring, this picks early.
    func testAFailedSkipLeavesTheWeeklyAlarmOn() async throws {
        var withStamp = alarm(id: "his", time: "05:51:00", days: weekdayNames, routine: nil)
        withStamp["nextTimestamp"] = "2027-01-19T12:00:00Z"

        StubServer.responses = [
            // Same answer every time, so `nextTimestamp` never moves: the skip was taken and ignored.
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, ["alarms": [withStamp]] as [String: Any]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
            StubServer.key("POST", "/v1/users/\(userID)/alarms"): (200, ["id": "oneoff-1"] as [String: Any]),
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)

        let receipt = try await adapter().write(
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [bent(onDay: 19, at: 6, 20)],
                              skipsNextMorning: false)
        )

        let last = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/his")])
        XCTAssertNotEqual(last["enabled"] as? Bool, false, "the weekly alarm is never switched off here")
        XCTAssertTrue(receipt.note.contains("Could not skip"), "and the failure is named, not swallowed")
    }

    /// A refused create leaves the routine exactly as it was, and says the override did not land.
    ///
    /// The dangerous version of this would silence the routine's alarm first and then fail to add the
    /// replacement, which ends with no alarm at all on a morning he asked to be woken.
    func testARefusedOverrideLeavesTheRoutineRinging() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [alarm(id: "his", time: "05:51:00", days: weekdayNames, routine: nil)],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
            StubServer.key("POST", "/v1/users/\(userID)/alarms"): (400, ["error": "no"] as [String: Any]),
            StubServer.key("POST", "/v2/users/\(userID)/alarms"): (400, ["error": "no"] as [String: Any]),
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)

        let receipt = try await adapter().write(
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [bent(onDay: 19, at: 6, 20)],
                              skipsNextMorning: false)
        )

        let weekly = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/his")])
        XCTAssertEqual(weekly["time"] as? String, "06:05:00", "the routine is untouched")
        XCTAssertNotEqual(weekly["enabled"] as? Bool, false, "and still rings")
        XCTAssertNotEqual(weekly["skipNext"] as? Bool, true, "and was not skipped for a morning nothing replaces")
        XCTAssertTrue(receipt.note.contains("refused"), "and he is told the one time change did not land")
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

    /// A bend on one routine leaves the other routine's alarm completely alone.
    ///
    /// **The gap the three tests above leave, and it is the shape his real account has.** All of them
    /// use a single routine, so none can catch a bend leaking sideways. His bed carries two alarms
    /// driven by two routines, and the thing that makes this worth asserting is that a bend **does**
    /// narrow the week upstream: `ScheduleStore.recompute` sets `schedule.weekdays = [next.weekday]`
    /// while one is armed, because AlarmKit has no way to say "this Monday" otherwise.
    ///
    /// That narrowing already deleted four mornings of Whoop schedule on 17 August, because Whoop
    /// holds one schedule for the whole account. This leg is supposed to be immune, since it takes
    /// days from the plan rather than from the target and each routine owns its own alarm. Supposed
    /// to be is not the same as tested, and the symptom would be a weekend alarm quietly moved to a
    /// weekday time with nothing on any screen saying so.
    func testABendOnOneRoutineDoesNotDisturbTheOther() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [
                    alarm(id: "week", time: "05:51:00", days: weekdayNames, routine: nil),
                    alarm(id: "wend", time: "10:45:00", days: ["saturday", "sunday"], routine: nil),
                ],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/week"): accepted,
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/wend"): accepted,
            StubServer.key("POST", "/v1/users/\(userID)/alarms"): (200, ["id": "oneoff-1"] as [String: Any]),
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "week", on: .eightSleep)
        RemoteAlarmLink.link(routine: "weekend", to: "wend", on: .eightSleep)

        let weekend = entry("weekend", "Weekend", [.saturday, .sunday], hour: 10, minute: 45)

        _ = try await adapter().write(
            // `target` carries the collapsed single day a bend produces upstream. If this leg ever
            // starts taking days from the target rather than the plan, this is where it shows.
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [bent(onDay: 19, at: 6, 20), weekend],
                              skipsNextMorning: false)
        )

        let bentBody = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/week")])
        XCTAssertEqual(bentBody["time"] as? String, "06:05:00",
                       "the bent routine keeps its own time. The override rides its own alarm now")

        let otherBody = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/wend")])
        XCTAssertEqual(otherBody["time"] as? String, "10:45:00", "the other routine keeps its own time")
        XCTAssertEqual(otherBody["enabled"] as? Bool, true, "and is not switched off by somebody else's bend")
        let days = (otherBody["repeat"] as? [String: Any])?["weekDays"] as? [String: Bool]
        XCTAssertEqual(days?["saturday"], true, "and keeps its own days, not the bend's single day")
        XCTAssertEqual(days?["sunday"], true)
        XCTAssertEqual(days?["monday"], false)
    }

    /// A skip on one routine leaves the other ringing.
    ///
    /// The dangerous direction of the same gap. A skip is expressed as `enabled: false`, and one
    /// routine's skip reaching another routine's alarm is a silently missed morning: nothing fails,
    /// nothing is reported, and it is only discovered by not waking up.
    func testASkipOnOneRoutineLeavesTheOtherRinging() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [
                    alarm(id: "week", time: "05:51:00", days: weekdayNames, routine: nil),
                    alarm(id: "wend", time: "10:45:00", days: ["saturday", "sunday"], routine: nil),
                ],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/week"): accepted,
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/wend"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "week", on: .eightSleep)
        RemoteAlarmLink.link(routine: "weekend", to: "wend", on: .eightSleep)

        let plain = entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 5, minute: 51)
        let skipped = RoutinePlan.Entry(
            routineID: plain.routineID, routineName: plain.routineName, weekdays: plain.weekdays,
            localTime: plain.localTime, bentTo: nil,
            isOn: true, isSkippedNextMorning: true
        )
        let weekend = entry("weekend", "Weekend", [.saturday, .sunday], hour: 10, minute: 45)

        _ = try await adapter().write(
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [skipped, weekend], skipsNextMorning: true)
        )

        let skippedBody = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/week")])
        XCTAssertEqual(skippedBody["enabled"] as? Bool, false, "the skipped routine's alarm goes quiet")
        XCTAssertEqual(skippedBody["time"] as? String, "05:51:00", "and keeps its time, so clearing the skip is one field")

        let otherBody = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/wend")])
        XCTAssertEqual(otherBody["enabled"] as? Bool, true, "the other routine still rings")
    }

    /// An alarm that matches no routine, and still rings, is named on the row after a write.
    ///
    /// Alex, 18 August: *"the problem is when something changes, if one alarm would change the entire
    /// thing then it usually doesn't work."* On 17 August he merged his two routines into one "Every
    /// day" routine, which left `09:30 weekdays` and `10:55 Sa Su` matching nothing. OneAlarm
    /// correctly stopped touching them and they correctly kept ringing, and the only place that was
    /// said was a panel three taps away in Connections. He reads the row.
    func testAnAlarmMatchingNoRoutineIsNamedOnTheRow() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [
                    alarm(id: "his", time: "06:50:00", days: weekdayNames, routine: nil),
                    alarm(id: "stranded", time: "09:00:00", days: ["saturday"], routine: nil),
                ],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)

        let receipt = try await adapter().write(
            target,
            plan: RoutinePlan(
                device: .eightSleep,
                entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50)],
                skipsNextMorning: false
            )
        )
        let note = try XCTUnwrap(receipt.note)

        XCTAssertTrue(note.contains("still rings"), "the part that decides whether he wakes up")
        XCTAssertTrue(note.contains("09:00"), "named, so he knows which one to go and look at")
    }

    /// An alarm that matches no routine and is already switched off is not mentioned.
    ///
    /// A warning that fires on a harmless state teaches him to skim past the one that matters, which
    /// is the mistake the hidden-alarm row made for an hour on 17 August.
    func testAStrandedAlarmThatIsSwitchedOffIsNotMentioned() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [
                    alarm(id: "his", time: "06:50:00", days: weekdayNames, routine: nil),
                    alarm(id: "quiet", time: "09:00:00", days: ["saturday"], routine: nil, enabled: false),
                ],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)

        let receipt = try await adapter().write(
            target,
            plan: RoutinePlan(
                device: .eightSleep,
                entries: [entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50)],
                skipsNextMorning: false
            )
        )

        XCTAssertFalse((receipt.note ?? "").contains("still ring"),
                       "a switched off alarm is not a problem and saying it is trains him to ignore this")
    }

    // MARK: The override detector

    /// An alarm firing at its weekly time reports no override.
    ///
    /// Alex's dump of 18 August: `time = 07:45:00` with `nextTimestamp = 2026-08-17T05:45:00Z`, which
    /// is 07:45 in Zurich. They agree, so nothing was overriding it, which is the fact three rounds of
    /// reading raw field lists could not establish.
    func testAnAlarmFiringAtItsWeeklyTimeReportsNoOverride() {
        let line = EightSleepAdapter.agreementLine(
            time: "07:45:00", nextTimestamp: "2026-08-17T05:45:00Z"
        )

        XCTAssertTrue(line.contains("NO override"), line)
    }

    /// An alarm firing at a different moment reports one, without knowing which field did it.
    ///
    /// This is the whole point. `UPCOMING ALARM ONLY` moves when the alarm fires, so `nextTimestamp`
    /// stops matching `time`, **whatever field carries the override and wherever it lives**. Three
    /// dumps came back with the same sixteen keys, which left "he never set it" and "it is not on this
    /// object" indistinguishable by reading. This tells them apart.
    func testAnAlarmFiringEarlyReportsAnOverride() {
        // 05:45Z is 07:45 local; 05:25Z is 07:25, twenty minutes earlier than the weekly 07:45.
        let line = EightSleepAdapter.agreementLine(
            time: "07:45:00", nextTimestamp: "2026-08-17T05:25:00Z"
        )

        XCTAssertTrue(line.contains("SOMETHING is overriding"), line)
        XCTAssertTrue(line.contains("20 min earlier"), line)
    }

    /// Across midnight it reports the small number, not the complement.
    ///
    /// "20 minutes earlier" and "1420 minutes later" are the same fact and only one of them reads as
    /// one. A detector that says the second is technically right and useless.
    func testTheOverrideDetectorWrapsAcrossMidnight() {
        // Weekly 00:10 local; firing 23:50 local the previous evening, 21:50Z.
        let line = EightSleepAdapter.agreementLine(
            time: "00:10:00", nextTimestamp: "2026-08-17T21:50:00Z"
        )

        XCTAssertTrue(line.contains("20 min earlier"), line)
        XCTAssertFalse(line.contains("1420"), line)
    }

    /// Unreadable input says so rather than reporting agreement.
    ///
    /// A detector that reports "no override" on data it could not parse is worse than none, because
    /// this panel exists to answer a question nothing else can.
    func testTheOverrideDetectorRefusesToGuess() {
        XCTAssertTrue(
            EightSleepAdapter.agreementLine(time: "07:45:00", nextTimestamp: "not a date")
                .contains("cannot compare")
        )
        XCTAssertTrue(
            EightSleepAdapter.agreementLine(time: "quarter to eight", nextTimestamp: "2026-08-17T05:45:00Z")
                .contains("cannot compare")
        )
    }

    // MARK: Skip, through Eight Sleep's own field

    /// A skip uses `skipNext` and leaves the weekly alarm switched on.
    ///
    /// `E11`. Their object has carried `skipNext` and `skippedUntil` in every dump Alex has sent,
    /// unused, while OneAlarm switched the weekly alarm off and repaired it later. That is the same
    /// edit-and-repair shape as the bend, and on 17 August he watched the bend version move his whole
    /// Monday to Friday series on the bed.
    func testASkipUsesEightSleepsOwnSkipAndLeavesTheAlarmOn() async throws {
        let before = alarm(id: "his", time: "05:51:00", days: weekdayNames, routine: nil)
        var after = before
        // The server moved the next firing a week on, which is what a skip looks like from outside.
        after["nextTimestamp"] = "2027-01-25T05:51:00Z"

        StubServer.sequences = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): [
                (200, ["alarms": [before]] as [String: Any]),
                (200, ["alarms": [after]] as [String: Any]),
            ],
        ]
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)

        let plain = entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 5, minute: 51)
        let skipped = RoutinePlan.Entry(
            routineID: plain.routineID, routineName: plain.routineName, weekdays: plain.weekdays,
            localTime: plain.localTime, bentTo: nil,
            isOn: true, isSkippedNextMorning: true
        )

        let receipt = try await adapter().write(
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [skipped], skipsNextMorning: true)
        )

        let body = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/his")])
        XCTAssertEqual(body["skipNext"] as? Bool, true, "the skip goes through their own field")
        XCTAssertNotEqual(body["enabled"] as? Bool, false,
                          "and the weekly alarm is NOT switched off, which is the whole point")
        XCTAssertTrue((receipt.note ?? "").contains("Eight Sleep's own skip"))
    }

    /// **The case that must never read as success.** The server accepts `skipNext` and does nothing.
    ///
    /// A 200 with an unmoved `nextTimestamp` means the field was stored and not acted on. Treating
    /// that as a skip would let him sleep through a morning he thought was handled, which is the
    /// worst outcome this app has. So the check is the absolute instant, never the status code, and
    /// the old behaviour runs instead.
    func testASkipThatDoesNotMoveTheNextFiringFallsBackToSwitchingOff() async throws {
        let unchanged = alarm(id: "his", time: "05:51:00", days: weekdayNames, routine: nil)

        StubServer.sequences = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): [
                (200, ["alarms": [unchanged]] as [String: Any]),
                // Same object back, so `nextTimestamp` has not moved.
                (200, ["alarms": [unchanged]] as [String: Any]),
            ],
        ]
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": [Any]()] as [String: Any]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/his"): accepted,
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "his", on: .eightSleep)

        let plain = entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 5, minute: 51)
        let skipped = RoutinePlan.Entry(
            routineID: plain.routineID, routineName: plain.routineName, weekdays: plain.weekdays,
            localTime: plain.localTime, bentTo: nil,
            isOn: true, isSkippedNextMorning: true
        )

        let receipt = try await adapter().write(
            target,
            plan: RoutinePlan(device: .eightSleep, entries: [skipped], skipsNextMorning: true)
        )

        let body = try XCTUnwrap(StubServer.bodies[StubServer.key("PUT", "/v1/users/\(userID)/alarms/his")])
        XCTAssertEqual(body["enabled"] as? Bool, false, "it falls back to switching the alarm off")
        let note = try XCTUnwrap(receipt.note)
        XCTAssertTrue(note.contains("did not move"), "and says why, rather than claiming a skip")
        XCTAssertFalse(note.contains("Eight Sleep's own skip"), "never both stories at once")
    }

    /// Only the instant decides. A `skipNext` echoed back as true proves nothing.
    func testSkipIsJudgedOnTheInstantNotOnTheEchoedField() {
        var before = alarm(id: "a", time: "05:51:00", days: weekdayNames, routine: nil)
        before["nextTimestamp"] = "2027-01-18T05:51:00Z"

        var storedButIgnored = before
        storedButIgnored["skipNext"] = true

        XCTAssertFalse(
            EightSleepAdapter.skipTookEffect(before: before, after: storedButIgnored),
            "the field came back set and the alarm still fires at the same moment, so nothing was skipped"
        )

        var moved = before
        moved["skipNext"] = false
        moved["nextTimestamp"] = "2027-01-25T05:51:00Z"

        XCTAssertTrue(
            EightSleepAdapter.skipTookEffect(before: before, after: moved),
            "the next firing moved, which is the only thing that proves a morning is off"
        )
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
