import XCTest
@testable import OneAlarm

/// The Whoop create, against a fake Whoop.
///
/// **Why this file exists.** On 17 August Alex deleted every schedule on his Whoop account, could not
/// remake one from Whoop's own app, and asked why this leg cannot behave like Eight Sleep. The answer
/// was that it could not create, and the reason it could not create is that **no public source
/// documents the address**. Research on 17 August found that every public capture of the Whoop app
/// records a schedule **update** and no create and no delete, which points at the update being an
/// upsert. So the ladder tries a PUT to an id it mints first, then two inferred POST paths, and
/// reports what each one was told. A third POST rung was removed the same day: `POST /schedule/all`
/// is the one candidate where "a create cannot destroy anything" is false.
///
/// A ladder against an unknown endpoint is only as good as its stopping rules, and those are pure
/// logic that needs no network to check. Which is the point: until today this adapter had no seam at
/// all, so every question about what it sends could only be answered by Alex running it against his
/// real account and screenshotting the result.
///
/// What these cannot check is whether Whoop accepts any of it. That is a fact about their server.
final class WhoopCreatePathTests: XCTestCase {

    /// Answers from a table and records every request, so the ladder's order is assertable.
    final class Stub: URLProtocol {
        struct Call: Equatable {
            let method: String
            let path: String
        }

        nonisolated(unsafe) static var responses: [String: (Int, Any)] = [:]
        nonisolated(unsafe) static var calls: [Call] = []
        nonisolated(unsafe) static var bodies: [String: [String: Any]] = [:]
        /// Whether a PUT to a schedule id nobody stubbed succeeds.
        ///
        /// This is how the upsert hypothesis is expressed. The create's first rung PUTs to an id the
        /// client mints at random, so it cannot be named in the table above, and a stub that 404s
        /// everything unlisted would make "the upsert works" untestable. Off by default, so the other
        /// tests still see the minted PUT refused and fall through to the POST rungs.
        nonisolated(unsafe) static var upsertWorks = false

        static func reset() {
            responses = [:]
            calls = []
            bodies = [:]
            upsertWorks = false
        }

        static func key(_ method: String, _ path: String) -> String { "\(method) \(path)" }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            Self.calls.append(Call(method: method, path: path))

            // `httpBody` is nil once URLSession has taken the request, so it comes off the stream.
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

            // Split into plain statements rather than one ternary, and it is not a style choice.
            // A multi-line condition choosing between two heterogeneous `(Int, Any)` tuple literals
            // made the Swift type checker give up entirely: "Failed to produce diagnostic for
            // expression; please submit a bug report". Not an error in the code, an error about not
            // being able to describe the code, which is the least useful failure a compiler has.
            let isNewSchedulePut = Self.upsertWorks
                && method == "PUT"
                && path.hasPrefix("/smart-alarm-bff/v1/schedule/")
            var fallback: (Int, Any) = (404, ["message": "no stub"] as [String: Any])
            if isNewSchedulePut {
                fallback = (200, [String: Any]())
            }
            let (status, payload) = Self.responses[lookup] ?? fallback
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

    /// Spelled out rather than `(200, [:])`. An empty collection literal in an `Any` position is a
    /// hard Swift error, and there is no compiler in the session that writes these.
    private let accepted: (Int, Any) = (200, [String: Any]())

    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return URLSession(configuration: config)
    }

    private func adapter() async -> WhoopAdapter {
        let adapter = WhoopAdapter(session: session)
        await adapter.seedSessionForTesting(token: "test-token")
        return adapter
    }

    override func setUp() {
        super.setUp()
        Stub.reset()
        RemoteAlarmLink.forget(for: .whoop)
    }

    override func tearDown() {
        RemoteAlarmLink.forget(for: .whoop)
        super.tearDown()
    }

    // MARK: Fixtures

    private let listPath = "/smart-alarm-bff/v1/schedule/all"
    private let createPath = "/smart-alarm-bff/v1/schedule"

    /// A schedule row as the list screen renders it, using the field names off Alex's real account.
    private func schedule(id: String, time: String, days: [String]) -> [String: Any] {
        [
            "schedule_id": id,
            "latest_wake_time": time,
            "scheduled_days": days,
            "alarm_on": 1,
            "alarm_mode": "EXACT_TIME",
            "alarm_mode_label_display": "Exact time",
            "days_scheduled_label_display": days.joined(separator: ", "),
            "delete_label_display": "Delete",
            "edit_label_display": "Edit",
        ]
    }

    private func envelope(_ schedules: [[String: Any]]) -> [String: Any] {
        ["alarm_schedule_list": schedules, "schedule_enabled": true]
    }

    private func entry(
        _ id: String,
        _ name: String,
        _ days: Set<Locale.Weekday>,
        hour: Int,
        minute: Int = 0
    ) -> RoutinePlan.Entry {
        RoutinePlan.Entry(
            routineID: id, routineName: name, weekdays: days,
            localTime: WallClockTime(hour: hour, minute: minute), bentTo: nil,
            isOn: true, isSkippedNextMorning: false
        )
    }

    private var target: ResolvedTarget {
        ResolvedTarget(
            device: .whoop,
            localTime: WallClockTime(hour: 6, minute: 50),
            weekdays: Locale.Weekday.weekdaysOnly,
            dayShift: 0,
            nextOccurrence: Date(timeIntervalSince1970: 1_800_000_000),
            utcOffsetSeconds: 7200
        )
    }

    // MARK: The ladder

    /// The upsert rung is tried first, and a success stops the ladder there.
    ///
    /// Reordered on 17 August after research rather than before it. Every public Whoop project was
    /// searched and none contains a schedule POST or DELETE, including `thebriangao/totem`, built
    /// from mitmproxy captures whose author deliberately exercised Smart Alarm CRUD. If the app never
    /// POSTs but the UI plainly creates, the update is probably an **upsert**, so a PUT to an id the
    /// client mints is the best founded rung available: confirmed address, confirmed body, only the
    /// id is new.
    func testASuccessfulCreateStopsAtTheFirstAddress() async throws {
        Stub.responses = [
            Stub.key("GET", listPath): (200, envelope([
                schedule(id: "week", time: "06:50:00", days: ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY"]),
                schedule(id: "spare", time: "09:00:00", days: ["SATURDAY"]),
            ])),
            Stub.key("PUT", "/smart-alarm-bff/v1/schedule/week"): accepted,
        ]
        Stub.upsertWorks = true
        RemoteAlarmLink.link(routine: "weekdays", to: "week", on: .whoop)

        let plan = RoutinePlan(
            device: .whoop,
            entries: [
                entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50),
                entry("weekend", "Weekend", [.saturday, .sunday], hour: 10, minute: 45),
            ],
            skipsNextMorning: false
        )

        _ = try await adapter().write(target, plan: plan)

        XCTAssertFalse(Stub.calls.contains { $0.method == "POST" },
                       "the upsert rung succeeded, so no POST is ever sent")
        let minted = Stub.calls.filter {
            $0.method == "PUT" && $0.path != "/smart-alarm-bff/v1/schedule/week"
        }
        XCTAssertEqual(minted.count, 1, "exactly one PUT to a brand new id")
    }

    /// The body is the six field object confirmed on his account, carrying the routine's days.
    ///
    /// The address is a guess. The body must not be. `alarm_mode` in particular is **copied** from a
    /// schedule he already has rather than chosen here, because choosing it would be silently
    /// changing a setting he made, which this project has done once already and written a rule about.
    func testTheCreateBodyIsTheConfirmedShapeAndCarriesTheRoutine() async throws {
        Stub.responses = [
            Stub.key("GET", listPath): (200, envelope([
                schedule(id: "week", time: "06:50:00", days: ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY"]),
                schedule(id: "spare", time: "09:00:00", days: ["SATURDAY"]),
            ])),
            Stub.key("PUT", "/smart-alarm-bff/v1/schedule/week"): accepted,
        ]
        Stub.upsertWorks = true
        RemoteAlarmLink.link(routine: "weekdays", to: "week", on: .whoop)

        let plan = RoutinePlan(
            device: .whoop,
            entries: [
                entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50),
                entry("weekend", "Weekend", [.saturday, .sunday], hour: 10, minute: 45),
            ],
            skipsNextMorning: false
        )

        _ = try await adapter().write(target, plan: plan)

        // The minted id is random, so the body is found by taking the one PUT that is not the
        // weekday schedule's rather than by naming a key.
        let mintedKey = try XCTUnwrap(Stub.bodies.keys.first {
            $0.hasPrefix("PUT /smart-alarm-bff/v1/schedule/") && !$0.hasSuffix("/week")
        })
        let body = try XCTUnwrap(Stub.bodies[mintedKey])
        XCTAssertEqual(Set(body.keys), [
            "latest_wake_time", "day_of_week_list", "enabled", "time_zone_offset", "alarm_mode", "sleep_goal",
        ], "exactly the six keys confirmed against his live account, no more and no fewer")
        XCTAssertEqual(body["latest_wake_time"] as? String, "10:45:00", "the routine's time, canonical")
        XCTAssertEqual(body["day_of_week_list"] as? [String], ["SATURDAY", "SUNDAY"], "the routine's days")
        XCTAssertEqual(body["alarm_mode"] as? String, "EXACT_TIME", "his own mode, copied, never chosen here")
        XCTAssertEqual(body["sleep_goal"] as? String, "", "an empty string in the capture, so an empty string here")
    }

    /// A 404 means wrong address, so the ladder moves on. A 422 means the address read the body, so
    /// it stops.
    ///
    /// **This stopping rule is the whole value of the ladder.** Firing two more writes at an endpoint
    /// that has already said "I understand you and this body is wrong" answers nothing and spends
    /// requests against a private API this project keeps a rate discipline for.
    func testTheLadderMovesPastAWrongAddressAndStopsAtAWrongBody() async throws {
        Stub.responses = [
            Stub.key("GET", listPath): (200, envelope([
                schedule(id: "week", time: "06:50:00", days: ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY"]),
                // **Two schedules, not one, and that is what this test was missing.** `write(_:plan:)`
                // only takes the per routine path when the account holds more than one; with a single
                // schedule it falls to `writeSingle`, which has no create in it at all. So the ladder
                // was never reached and the assertion compared an empty list against two paths.
                schedule(id: "spare", time: "09:00:00", days: ["SATURDAY"]),
            ])),
            Stub.key("PUT", "/smart-alarm-bff/v1/schedule/week"): accepted,
            Stub.key("POST", createPath): (404, ["message": "not found"]),
            Stub.key("POST", "/smart-alarm-bff/v1/schedule/create"): (422, ["message": "day_of_week_list invalid"]),
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "week", on: .whoop)

        let plan = RoutinePlan(
            device: .whoop,
            entries: [
                entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50),
                entry("weekend", "Weekend", [.saturday, .sunday], hour: 10, minute: 45),
            ],
            skipsNextMorning: false
        )

        let receipt = try await adapter().write(target, plan: plan)
        let note = try XCTUnwrap(receipt.note)

        // `POST /schedule/all` was a third rung and was removed on 17 August: it is the one candidate
        // where "a create cannot destroy anything" is false, because a POST to a collection endpoint
        // named `all` is as plausibly a bulk replace as a create.
        let posts = Stub.calls.filter { $0.method == "POST" }.map(\.path)
        XCTAssertEqual(posts, [createPath, "/smart-alarm-bff/v1/schedule/create"],
                       "past the 404, stopped by the 422")
        XCTAssertTrue(note.contains("404"), "every rung is reported, so one round trip settles it")
        XCTAssertTrue(note.contains("422"))
        XCTAssertTrue(note.contains("day_of_week_list invalid"), "including what the server actually said")
    }

    /// A create that fails does not take the schedules that DID write down with it.
    ///
    /// The Eight Sleep leg shipped the opposite of this on 16 August: a create raised, and the alarm
    /// times that had already been written correctly were reported to Alex as a total failure.
    func testAFailedCreateStillReportsTheSchedulesThatMoved() async throws {
        Stub.responses = [
            Stub.key("GET", listPath): (200, envelope([
                schedule(id: "week", time: "06:00:00", days: ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY"]),
                // Two, so the per routine path runs and the create is actually reached. See above.
                schedule(id: "spare", time: "09:00:00", days: ["SATURDAY"]),
            ])),
            Stub.key("PUT", "/smart-alarm-bff/v1/schedule/week"): accepted,
            Stub.key("PUT", "/smart-alarm-bff/v1/schedule/spare"): accepted,
            Stub.key("POST", createPath): (403, ["message": "forbidden"]),
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "week", on: .whoop)

        let plan = RoutinePlan(
            device: .whoop,
            entries: [
                entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50),
                entry("weekend", "Weekend", [.saturday, .sunday], hour: 10, minute: 45),
            ],
            skipsNextMorning: false
        )

        let receipt = try await adapter().write(target, plan: plan)
        let note = try XCTUnwrap(receipt.note)

        XCTAssertNotNil(Stub.bodies[Stub.key("PUT", "/smart-alarm-bff/v1/schedule/week")],
                        "the weekday schedule still moved")
        XCTAssertTrue(note.contains("Weekdays"), "and is named")
        XCTAssertTrue(note.contains("403"), "alongside why the other one could not be made")
    }

    /// Nothing is ever created past the ceiling.
    ///
    /// A create against an address nobody has captured can succeed in ways nobody predicted, and the
    /// failure that matters is not a refusal, it is a silent duplicate on every sync filling his
    /// account with schedules he did not ask for.
    func testTheCeilingIsRespected() async throws {
        let seven = (0..<7).map { schedule(id: "s\($0)", time: "0\($0):00:00", days: ["MONDAY"]) }
        Stub.responses = [
            Stub.key("GET", listPath): (200, envelope(seven)),
            Stub.key("PUT", "/smart-alarm-bff/v1/schedule/s0"): accepted,
            Stub.key("POST", createPath): (201, ["schedule_id": "eighth"]),
        ]
        RemoteAlarmLink.link(routine: "weekdays", to: "s0", on: .whoop)

        let plan = RoutinePlan(
            device: .whoop,
            entries: [
                entry("weekdays", "Weekdays", [.monday], hour: 6, minute: 50),
                entry("weekend", "Weekend", [.saturday, .sunday], hour: 10, minute: 45),
            ],
            skipsNextMorning: false
        )

        let receipt = try await adapter().write(target, plan: plan)

        XCTAssertFalse(Stub.calls.contains { $0.method == "POST" },
                       "at the ceiling, nothing is created however willingly the stub would accept it")
        XCTAssertTrue((receipt.note ?? "").contains("\(WhoopAdapter.scheduleCeiling)"),
                      "and he is told why rather than left with a routine that silently did nothing")
    }

    /// The create never fires for a routine that already owns a schedule.
    ///
    /// The duplicate this guards against has no symptom on the day it happens. It shows up as two
    /// schedules on the same days, one of them drifting, and only a morning explains which.
    func testNoCreateWhenEveryRoutineAlreadyHasASchedule() async throws {
        Stub.responses = [
            Stub.key("GET", listPath): (200, envelope([
                schedule(id: "week", time: "06:50:00", days: ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY"]),
                schedule(id: "wend", time: "10:45:00", days: ["SATURDAY", "SUNDAY"]),
            ])),
            Stub.key("PUT", "/smart-alarm-bff/v1/schedule/week"): accepted,
            Stub.key("PUT", "/smart-alarm-bff/v1/schedule/wend"): accepted,
            Stub.key("POST", createPath): (201, ["schedule_id": "unwanted"]),
        ]

        let plan = RoutinePlan(
            device: .whoop,
            entries: [
                entry("weekdays", "Weekdays", Locale.Weekday.weekdaysOnly, hour: 6, minute: 50),
                entry("weekend", "Weekend", [.saturday, .sunday], hour: 10, minute: 45),
            ],
            skipsNextMorning: false
        )

        _ = try await adapter().write(target, plan: plan)

        XCTAssertFalse(Stub.calls.contains { $0.method == "POST" },
                       "both routines matched by days, so there is nothing to make")
    }
}
