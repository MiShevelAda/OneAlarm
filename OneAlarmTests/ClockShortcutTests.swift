import XCTest
@testable import OneAlarm

/// The one route OneAlarm has to the Clock app, and the limits it must not overstate.
final class ClockShortcutTests: XCTestCase {
    private let seven = WallClockTime(hour: 7, minute: 30)

    /// The URL is Apple's documented scheme, with the input pair Shortcuts actually reads.
    ///
    /// `input=text` **and** `text=` together. Passing `text` alone is ignored and the shortcut runs
    /// with no input, which looks exactly like a working button and is not one. That failure would be
    /// invisible from inside OneAlarm, because nothing here can see what Shortcuts did.
    func testTheURLCarriesTheNameAndTheTimeAsInput() throws {
        let url = try XCTUnwrap(ClockShortcut.runURL(named: "Wake alarm", handing: seven))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(parts.scheme, "shortcuts")
        XCTAssertEqual(parts.host, "run-shortcut")

        let items = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["name"], "Wake alarm")
        XCTAssertEqual(items["input"], "text", "without this the shortcut runs with no input at all")
        XCTAssertEqual(items["text"], "07:30")
    }

    /// A name with spaces and punctuation survives, because his shortcut is named whatever he named it.
    func testAnAwkwardNameIsEncodedRatherThanRejected() throws {
        let url = try XCTUnwrap(ClockShortcut.runURL(named: "Wake up & go", handing: seven))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let name = (parts.queryItems ?? []).first { $0.name == "name" }?.value
        XCTAssertEqual(name, "Wake up & go", "the component parser gives back the decoded value")
        XCTAssertTrue(url.absoluteString.contains("%26") || url.absoluteString.contains("&amp"),
                      "and the ampersand is escaped in the string itself: \\(url.absoluteString)")
    }

    /// **No name means no button.**
    ///
    /// A URL built from an empty name opens the Shortcuts app and achieves nothing, which is worse
    /// than a disabled button: it looks like it worked. Whitespace counts as empty for the same
    /// reason, since a stray space is not a shortcut anybody has.
    func testAnEmptyNameProducesNoURL() {
        XCTAssertNil(ClockShortcut.runURL(named: "", handing: seven))
        XCTAssertNil(ClockShortcut.runURL(named: "   \\n ", handing: seven))
    }

    /// **The promise on screen must not exceed what the mechanism delivers.**
    ///
    /// This leg cannot read anything back: the URL returns nothing and Shortcuts reports to itself.
    /// Every other leg in this app reads its write back, so the temptation to word this one like the
    /// others is real, and it is the exact class of lie this project keeps finding and removing.
    func testTheStatedLimitsDenyConfirmationAndVisibility() {
        let limits = ClockShortcut.honestLimits
        XCTAssertTrue(limits.contains("cannot see"), limits)
        XCTAssertTrue(limits.contains("cannot tell whether"), limits)
        XCTAssertTrue(limits.contains("never show this as confirmed"), limits)
        XCTAssertFalse(limits.lowercased().contains("confirmed for"),
                       "that is the cascade's wording for a verified write and must never appear here")
    }
}
