import Foundation

/// The one route OneAlarm has to the **Clock app's** alarms, and its limits.
///
/// **Why this exists.** Alex was woken an hour early on 20 August by his Clock app's
/// `Sleep | Wake Up` at 08:30 while OneAlarm's own alarm sat correctly at 09:30. His instruction:
/// *"Make the app be able to change it and see it."*
///
/// **What is genuinely impossible, and no amount of work changes it.** AlarmKit hands an app its own
/// alarms and nothing else. There is no framework, entitlement or private-but-reachable call that
/// lets one app read, edit or delete an alarm belonging to the Clock app, and the Sleep schedule is
/// further away again, owned by Health. So **"see it" cannot be done**: nothing can hand OneAlarm the
/// list of alarms in his Clock app, which means nothing here can ever report their state truthfully.
///
/// **What is possible.** Apple's Clock app publishes actions to Shortcuts, and any app may launch a
/// shortcut by URL. So OneAlarm can *ask* Shortcuts to change a Clock alarm on his behalf. He builds
/// the shortcut once; this hands it a time.
///
/// **The honesty this forces, and it is the whole reason this is a separate type rather than a
/// fourth `DeviceAdapter`.** Every other leg reads its write back and reports what the service
/// actually holds. This one cannot: the URL returns nothing, Shortcuts reports to itself, and
/// OneAlarm never learns whether the shortcut ran, was cancelled, or does what he thinks it does.
/// Making it an adapter would put it in a row that says "Confirmed", which would be a lie of exactly
/// the kind this project keeps finding and removing. It gets its own section, its own wording, and
/// no green tick, ever.
enum ClockShortcut {
    /// The Shortcuts URL that runs a named shortcut and hands it a time as text input.
    ///
    /// `shortcuts://run-shortcut` is Apple's own documented scheme. The name has to match his
    /// shortcut exactly, which is why it is stored as free text he types rather than guessed.
    ///
    /// Returns `nil` for an empty name rather than building a URL that opens Shortcuts and does
    /// nothing, because a button that visibly launches an app and silently achieves nothing is worse
    /// than a button that is disabled.
    static func runURL(named name: String, handing time: WallClockTime) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        // `input=text` then `text=` is the pair Shortcuts expects. Passing `text` alone is ignored,
        // and the shortcut runs with no input, which looks like a working button and is not one.
        components.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: time.hhmm),
        ]
        return components.url
    }

    /// What OneAlarm can and cannot promise about this, in the words the screen uses.
    ///
    /// Written here beside the mechanism rather than in a view, so the claim and the code that makes
    /// it cannot drift apart. The last thing this leg needs is a screen promising more than the URL
    /// delivers.
    static let honestLimits = """
        OneAlarm hands Shortcuts the time and nothing else. It cannot see your Clock alarms, cannot \
        tell whether the shortcut ran, and will never show this as confirmed. Check the Clock app if \
        you want to be sure.
        """
}
