import Foundation

/// Which build of OneAlarm this is, in words, on screen.
///
/// Added 2026-08-16 after the third round in a row where the first question was "is the code you are
/// running the code I pushed", and there was no way to answer it. Alex reported a feature not
/// working, I reasoned about why, and twice the answer was that his phone was running a build from
/// before the fix. Reasoning about a build you cannot identify is the same mistake as reasoning
/// about a response you have not printed.
///
/// Bumped by hand in the same commit as any change worth testing. A stamp that lags is worse than
/// none, because it answers the question wrongly and confidently.
enum Build {
    /// Date, then what landed. Short enough for a footer, specific enough to match against a commit.
    static let marker = "19 Aug, 22:45 · the strap no longer buzzes early on a moved morning"

    /// What this build can do that the one before it could not, in his words rather than mine.
    ///
    /// One line, and it is the thing to go and test. Anything longer gets skipped.
    static let whatIsNew = "You were right to flag Whoop. Leaving your strap alone meant it would buzz at 07:50 on a morning you moved to 09:41. It is now switched off for that one morning instead, and it turns itself back on the next time you press Set all alarms."
}
