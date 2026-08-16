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
        nonisolated(unsafe) static var calls: [Call] = []
        nonisolated(unsafe) static var bodies: [String: [String: Any]] = [:]

        static func reset() {
            responses = [:]
            calls = []
            bodies = [:]
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

            let (status, payload) = Self.responses[Self.key(method, path)] ?? (404, ["error": "no stub"])
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
            "alarms": [],
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
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/a1"): (200, [:]),
            StubServer.key("PUT", "/v2/users/\(userID)/routines/r2"): (200, [:]),
            StubServer.key("PUT", "/v2/users/\(userID)/routines/r1"): (200, [:]),
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
            StubServer.key("PUT", "/v2/users/\(userID)/routines/r2"): (200, [:]),
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
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/a1"): (200, [:]),
            StubServer.key("PUT", "/v2/users/\(userID)/routines/r1"): (200, [:]),
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
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/a1"): (200, [:]),
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
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, ["routines": []]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/a1"): (200, [:]),
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

    /// The whole point of recording ownership: nothing is created twice.
    func testALinkedAlarmIsUpdatedRatherThanDuplicated() async throws {
        StubServer.responses = [
            StubServer.key("GET", "/v2/users/\(userID)/alarms"): (200, [
                "alarms": [alarm(id: "a1", time: "07:00:00", days: ["monday"], routine: "r1")],
            ]),
            StubServer.key("GET", "/v2/users/\(userID)/routines"): (200, [
                "routines": [routine(id: "r1", days: ["monday"])],
            ]),
            StubServer.key("PUT", "/v1/users/\(userID)/alarms/a1"): (200, [:]),
            StubServer.key("PUT", "/v2/users/\(userID)/routines/r1"): (200, [:]),
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
