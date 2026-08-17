import XCTest
@testable import OneAlarm

/// Temperature, vibration and smart wake, and the rule that makes writing them safe.
final class ComfortTests: XCTestCase {
    /// An alarm shaped like the ones his account actually returns.
    private let his: [String: Any] = [
        "time": "07:45:00",
        "vibration": ["enabled": true, "powerLevel": 100, "pattern": "INTENSE"],
        "thermal": ["enabled": false, "level": 0],
        "smart": ["lightSleepEnabled": false, "sleepCapEnabled": false, "sleepCapMinutes": 480],
    ]

    /// Nothing set changes nothing. The default for every routine he has never opened.
    func testUnchangedComfortTouchesNothing() {
        let out = Comfort.apply(.unchanged, to: his)
        XCTAssertEqual((out["vibration"] as? [String: Any])?["powerLevel"] as? Int, 100)
        XCTAssertEqual((out["thermal"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertEqual((out["smart"] as? [String: Any])?["lightSleepEnabled"] as? Bool, false)
    }

    /// What he sets is written, and only what he sets.
    func testOnlyTheFieldsHeSetAreChanged() {
        var comfort = Comfort.unchanged
        comfort.thermalEnabled = true
        comfort.smartEnabled = true

        let out = Comfort.apply(comfort, to: his)
        XCTAssertEqual((out["thermal"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual((out["smart"] as? [String: Any])?["lightSleepEnabled"] as? Bool, true)
        // Untouched, because he set nothing for it.
        XCTAssertEqual((out["vibration"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual((out["vibration"] as? [String: Any])?["powerLevel"] as? Int, 100)
    }

    /// **A key the server did not send is never introduced.** This is the whole safety argument.
    ///
    /// The reference documentation contradicts itself about these names thirty lines apart:
    /// `vibration.powerLevel` against `vibration.level`, `thermal.level` against
    /// `thermal.temperature`. Composing the wrong one would succeed, show a changed value in the app,
    /// and leave his bed doing what it did before. Writing only into keys that came back means the
    /// account settles the argument.
    func testAKeyTheServerDidNotSendIsNeverAdded() {
        var comfort = Comfort.unchanged
        comfort.vibrationPower = 40
        comfort.thermalLevel = 20

        let out = Comfort.apply(comfort, to: his)
        let vibration = out["vibration"] as? [String: Any]
        let thermal = out["thermal"] as? [String: Any]

        XCTAssertEqual(vibration?["powerLevel"] as? Int, 40, "his account spells it powerLevel")
        XCTAssertNil(vibration?["level"], "so the other spelling must not appear")
        XCTAssertEqual(thermal?["level"] as? Int, 20, "his account spells it level")
        XCTAssertNil(thermal?["temperature"], "so the other spelling must not appear")
    }

    /// And on an account using the other spelling, the other spelling is what gets written.
    ///
    /// The same `Comfort` value against a differently shaped alarm. Neither doc had to be right.
    func testTheOtherSpellingIsHonouredWhenThatIsWhatCameBack() {
        let otherShape: [String: Any] = [
            "vibration": ["enabled": true, "level": 50],
            "thermal": ["enabled": true, "temperature": -10],
        ]
        var comfort = Comfort.unchanged
        comfort.vibrationPower = 40
        comfort.thermalLevel = 20

        let out = Comfort.apply(comfort, to: otherShape)
        XCTAssertEqual((out["vibration"] as? [String: Any])?["level"] as? Int, 40)
        XCTAssertNil((out["vibration"] as? [String: Any])?["powerLevel"])
        XCTAssertEqual((out["thermal"] as? [String: Any])?["temperature"] as? Int, 20)
        XCTAssertNil((out["thermal"] as? [String: Any])?["level"])
    }

    /// A block the account does not have is not created either.
    func testAMissingBlockIsLeftMissing() {
        var comfort = Comfort.unchanged
        comfort.smartEnabled = true
        let out = Comfort.apply(comfort, to: ["time": "07:45:00"])
        XCTAssertNil(out["smart"], "inventing a smart block would be composing a whole object")
        XCTAssertEqual(out["time"] as? String, "07:45:00")
    }

    /// The summary says only what he actually set, so an untouched routine says nothing.
    func testTheSummaryIsEmptyUntilHeSetsSomething() {
        XCTAssertTrue(Comfort.unchanged.summary.isEmpty)
        XCTAssertTrue(Comfort.unchanged.isUnchanged)

        var comfort = Comfort.unchanged
        comfort.thermalEnabled = false
        XCTAssertEqual(comfort.summary, ["temperature wake off"])
        XCTAssertFalse(comfort.isUnchanged)
    }
}
