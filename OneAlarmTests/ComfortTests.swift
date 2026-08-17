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

    /// **The regression that shipped: a boxed nil overwriting a setting he never touched.**
    ///
    /// Alex within the hour: *"now it sets the eight sleep alarm always to heavy."* `apply` took
    /// `[String: Any?]` and skipped nils with `guard let value`, which does not skip: putting an
    /// `Int?` into an `Any?` dictionary double wraps it, so the unwrap peels the outer layer and
    /// succeeds. Every field left on `Leave` was written back as `Optional.none` boxed as `Any`.
    ///
    /// `testUnchangedComfortTouchesNothing` above did not catch it, because it only checked the
    /// values were unchanged and a boxed nil compares unequal to nothing it was asked about. This
    /// checks the **types** that survive, which is where the damage was.
    func testNothingIsEverWrittenAsABoxedOptional() {
        let out = Comfort.apply(.unchanged, to: his)

        for block in ["vibration", "thermal", "smart"] {
            let dict = try? XCTUnwrap(out[block] as? [String: Any])
            for (key, value) in dict ?? [:] {
                // A boxed `Optional.none` is not a Bool, Int or String, and is what JSON refuses.
                let isConcrete = value is Bool || value is Int || value is String || value is Double
                XCTAssertTrue(isConcrete, "\(block).\(key) survived as \(type(of: value)), not a value")
            }
        }
    }

    /// And with values set, the same holds: real types out, no wrappers.
    func testSetValuesArriveAsConcreteTypes() throws {
        var comfort = Comfort.unchanged
        comfort.vibrationEnabled = false
        comfort.vibrationPower = 40
        comfort.vibrationPattern = "RISE"

        let out = Comfort.apply(comfort, to: his)
        let vibration = try XCTUnwrap(out["vibration"] as? [String: Any])

        XCTAssertEqual(vibration["enabled"] as? Bool, false)
        XCTAssertEqual(vibration["powerLevel"] as? Int, 40)
        XCTAssertEqual(vibration["pattern"] as? String, "RISE")
    }

    /// **At most one numeric spelling, even when the account carries both.**
    ///
    /// `powerLevel` and `level` both map to `vibrationPower` so that whichever name his account uses
    /// is the one written. That argument only holds while exactly one is present. His account returns
    /// `powerLevel: 100`, a percentage; the other shape returns `temperature: -10`, a signed offset.
    /// Writing one integer to both would be the wrong-temperature failure this design prevents.
    func testOnlyOneSpellingIsWrittenWhenBothArePresent() throws {
        let both: [String: Any] = [
            "vibration": ["enabled": true, "powerLevel": 100, "level": 50],
            "thermal": ["enabled": true, "level": 0, "temperature": -10],
        ]
        var comfort = Comfort.unchanged
        comfort.vibrationPower = 40
        comfort.thermalLevel = 20

        let out = Comfort.apply(comfort, to: both)
        let vibration = try XCTUnwrap(out["vibration"] as? [String: Any])
        let thermal = try XCTUnwrap(out["thermal"] as? [String: Any])

        let vibrationChanged = [vibration["powerLevel"] as? Int, vibration["level"] as? Int]
            .filter { $0 == 40 }
        XCTAssertEqual(vibrationChanged.count, 1, "exactly one of the two spellings may be written")

        let thermalChanged = [thermal["level"] as? Int, thermal["temperature"] as? Int]
            .filter { $0 == 20 }
        XCTAssertEqual(thermalChanged.count, 1, "and the other keeps whatever it had")
    }

    /// **A created alarm gets his settings too, and did not.**
    ///
    /// A neutral review on 20 August found `clone` and `oneShot` copying vibration and thermal
    /// wholesale from whichever alarm was the template, never applying his choices. Because the
    /// update loop skips anything created in the same run, it was never corrected on a later sync
    /// either: a routine whose alarm OneAlarm made would have kept a different alarm's settings
    /// forever.
    func testACreatedAlarmCarriesHisSettings() throws {
        var comfort = Comfort.unchanged
        comfort.vibrationEnabled = false
        comfort.smartEnabled = true

        let shot = EightSleepAdapter.oneShot(like: his, at: WallClockTime(hour: 8, minute: 5),
                                             comfort: comfort)
        XCTAssertEqual((shot["vibration"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertEqual((shot["smart"] as? [String: Any])?["lightSleepEnabled"] as? Bool, true,
                       "smart was missing from the copied fields entirely until 20 August")

        let copy = EightSleepAdapter.clone(his, days: [.monday], time: WallClockTime(hour: 8, minute: 5),
                                           comfort: comfort)
        XCTAssertEqual((copy["vibration"] as? [String: Any])?["enabled"] as? Bool, false)
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
