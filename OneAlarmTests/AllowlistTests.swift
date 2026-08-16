import XCTest
@testable import OneAlarm

/// The allowlist, checked against every request the adapters actually build.
///
/// This is the safety gate, and until now nothing tested it. Both bearer tokens reach genuinely
/// destructive endpoints: on Eight Sleep, running the pump and moving the bed frame while somebody
/// may be in it. The allowlist is the only thing standing between a careless edit and those, and it
/// is a list of regular expressions, which is a thing that fails silently in both directions.
///
/// Both directions are the point. A pattern that is too tight blocks a real request, and the
/// symptom is "Blocked by allowlist" at six in the morning. A pattern that is too loose opens a path
/// nobody reviewed. Five patterns were added to the Eight Sleep leg on 16 August, in an evening with
/// no compiler, and none of them had been matched against a real URL until this file existed.
final class AllowlistTests: XCTestCase {

    private let user = "abc-123"
    private let alarm = "alarm-9"
    private let routine = "94b49169-dead-beef"

    private var client: HTTPClient {
        HTTPClient(allowedPatterns: EightSleepAdapter.allowedPatterns)
    }

    /// Every request the Eight Sleep adapter can build, read off its `URL(string:)` call sites.
    private var realRequests: [(method: String, url: String, why: String)] {
        [
            ("POST", "https://auth-api.8slp.net/v1/tokens", "token grant"),
            ("GET", "https://app-api.8slp.net/v2/users/\(user)/alarms", "fetchAlarms"),
            ("PUT", "https://app-api.8slp.net/v1/users/\(user)/alarms/\(alarm)", "alarm update"),
            ("POST", "https://app-api.8slp.net/v1/users/\(user)/alarms", "create, v1 rung"),
            ("POST", "https://app-api.8slp.net/v2/users/\(user)/alarms", "create, v2 rung"),
            ("GET", "https://app-api.8slp.net/v2/users/\(user)/routines", "routines read, v2 first"),
            ("GET", "https://app-api.8slp.net/v1/users/\(user)/routines", "routines read, v1 fallback"),
            ("PUT", "https://app-api.8slp.net/v2/users/\(user)/routines/\(routine)", "routine write"),
            ("GET", "https://client-api.8slp.net/v1/users/me", "currentBed"),
            ("GET", "https://app-api.8slp.net/v1/household/users/\(user)/summary", "pod name"),
        ]
    }

    func testEveryRequestTheAdapterBuildsIsAllowed() throws {
        for request in realRequests {
            let url = try XCTUnwrap(URL(string: request.url))
            XCTAssertTrue(
                client.isAllowed(request.method, url),
                "\(request.why) is blocked by the allowlist, so it fails at 6am with a message about a list"
            )
        }
    }

    /// The endpoints this app must never be able to reach, whatever a later edit does.
    ///
    /// Deleting an alarm is irreversible and unverified. The temperature endpoint runs the pump. The
    /// base endpoint moves the bed frame. Creating a routine is a shape nobody has captured. None of
    /// these is needed, so none of them is listed, and this test is what notices if one appears.
    func testTheDestructiveEndpointsStayUnreachable() throws {
        let forbidden = [
            ("DELETE", "https://app-api.8slp.net/v1/users/\(user)/alarms/\(alarm)", "alarm delete"),
            ("DELETE", "https://app-api.8slp.net/v2/users/\(user)/routines/\(routine)", "routine delete"),
            ("PUT", "https://app-api.8slp.net/v1/users/\(user)/temperature", "runs the pump"),
            ("PUT", "https://app-api.8slp.net/v1/users/\(user)/base", "moves the bed frame"),
            ("POST", "https://app-api.8slp.net/v2/users/\(user)/routines", "creates a routine"),
            ("GET", "https://app-api.8slp.net/v1/users/\(user)/devices", "not needed, so not open"),
        ]

        for request in forbidden {
            let url = try XCTUnwrap(URL(string: request.1))
            XCTAssertFalse(client.isAllowed(request.0, url), "\(request.2) is reachable and must not be")
        }
    }

    /// A pattern edit must never be able to authorise cleartext, whatever it says.
    func testCleartextIsRefusedEvenWhenAPatternWouldMatch() throws {
        let url = try XCTUnwrap(URL(string: "http://app-api.8slp.net/v2/users/\(user)/alarms"))

        XCTAssertFalse(client.isAllowed("GET", url))
        XCTAssertFalse(
            HTTPClient(allowedPatterns: [#"^GET http://.*$"#]).isAllowed("GET", url),
            "the scheme guard sits in front of the patterns, not behind them"
        )
    }

    /// The verb is part of the pattern, deliberately.
    ///
    /// Matching on the URL alone leaves the method free, which means a path allowlisted for `GET` is
    /// also open to `DELETE`. On this API that is the difference between reading an alarm and
    /// destroying it.
    func testThePathAllowedForOneVerbIsNotOpenToAnother() throws {
        let list = try XCTUnwrap(URL(string: "https://app-api.8slp.net/v2/users/\(user)/alarms"))

        XCTAssertTrue(client.isAllowed("GET", list))
        XCTAssertFalse(client.isAllowed("DELETE", list))
        XCTAssertFalse(client.isAllowed("PUT", list))
    }

    /// No pattern sits in the list that nothing sends.
    ///
    /// A dead pattern is an open path with no reviewer: it was added for a call that was later
    /// renamed or removed, and it stays reachable by anything that happens to match it.
    func testNoAllowlistPatternIsDead() throws {
        for pattern in EightSleepAdapter.allowedPatterns {
            let single = HTTPClient(allowedPatterns: [pattern])
            var matched = false
            for request in realRequests {
                guard let url = URL(string: request.url) else { continue }
                if single.isAllowed(request.method, url) { matched = true; break }
            }
            XCTAssertTrue(matched, "nothing this app sends matches \(pattern), so it is an open path nobody uses")
        }
    }

    /// And no real request matches two patterns, which would mean the list has drifted into overlap
    /// and one of them is broader than anybody intended.
    func testEachRequestMatchesExactlyOnePattern() throws {
        for request in realRequests {
            let url = try XCTUnwrap(URL(string: request.url))
            let hits = EightSleepAdapter.allowedPatterns.filter {
                HTTPClient(allowedPatterns: [$0]).isAllowed(request.method, url)
            }
            XCTAssertEqual(hits.count, 1, "\(request.why) matches \(hits.count) patterns")
        }
    }
}
