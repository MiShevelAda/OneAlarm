import Foundation

/// One device's alarm, fully resolved from the master time and that device's rule.
///
/// This is the canonical intent every adapter projects from. It carries the wall clock form for
/// the legs that want wall clock, the weekday set for the legs that repeat, and `nextOccurrence`
/// as an absolute instant so a write can actually be verified.
///
/// `nextOccurrence` is not decoration. Eight Sleep resolves our bare `"06:50:00"` against a time
/// zone stored on its own server that the client never sees, so a write can succeed with a 200 and
/// still be set for the wrong absolute moment. Comparing the server's returned UTC timestamp
/// against this field is the only way to catch that.
struct ResolvedTarget: Equatable, Sendable {
    let device: DeviceID
    let localTime: WallClockTime
    let weekdays: Set<Locale.Weekday>
    /// -1 when the offset pushed the alarm onto the previous day, +1 when onto the next.
    let dayShift: Int
    let nextOccurrence: Date
    /// Fixed UTC offset in seconds at `nextOccurrence`. Whoop wants this as `"-0700"`.
    let utcOffsetSeconds: Int

    /// `"+0100"`. Whoop's `time_zone_offset` format.
    var utcOffsetString: String {
        let total = utcOffsetSeconds
        let sign = total < 0 ? "-" : "+"
        let absolute = abs(total)
        return String(format: "%@%02d%02d", sign, absolute / 3600, (absolute % 3600) / 60)
    }

    var crossesMidnight: Bool { dayShift != 0 }
}

/// What an adapter would send, without sending it. Produced with no I/O so the debug preview gate
/// can show the exact outbound payload with no risk of it firing, and so preview output can be
/// asserted in tests.
struct WritePreview: Equatable, Sendable {
    let device: DeviceID
    let summary: String
    let method: String
    let url: String
    /// Already redacted. No adapter puts a credential in here.
    let body: String?
    /// `true` when the body is rebuilt from the target alone rather than from the account's own
    /// schedule.
    ///
    /// This distinction is not cosmetic. Both remote legs read, edit and resend, so the real body
    /// carries fields this screen has never seen and, on Whoop, copies the time format out of the
    /// response. A gate that quietly shows an approximation while claiming to show the request is
    /// worse than no gate: it is the screen you would check to rule out exactly the bug that has
    /// been failing all evening, and it would have cleared it.
    let reconstructed: Bool

    init(
        device: DeviceID,
        summary: String,
        method: String,
        url: String,
        body: String?,
        reconstructed: Bool = false
    ) {
        self.device = device
        self.summary = summary
        self.method = method
        self.url = url
        self.body = body
        self.reconstructed = reconstructed
    }

    static func local(device: DeviceID, summary: String) -> WritePreview {
        // Nothing is reconstructed here: AlarmKit takes a schedule, not a payload, so there is no
        // request shape to be approximate about.
        WritePreview(device: device, summary: summary, method: "LOCAL", url: "AlarmKit", body: nil)
    }
}

struct WriteReceipt: Equatable, Sendable {
    let device: DeviceID
    let succeededAt: Date
    /// Identifier the remote gave back, when there is one.
    let remoteID: String?
    let note: String?
    /// Something the user asked for did not land, even though the request succeeded.
    ///
    /// Exists because a leg holding several alarms can now half-succeed: two routines matched and a
    /// third had no alarm with its days. Reporting that as done would put a green tick on a week
    /// with a hole in it, and the hole is a morning nobody is woken on.
    var isPartial: Bool = false

    /// Things that must reach the screen **even when the write succeeded completely**.
    ///
    /// `note` does not. A clean write reports as `.done("Set for 06:05. Eight Sleep reads back Tue
    /// 06:05.")` and the note is discarded, which is right for the routine chatter it mostly
    /// contains: "Set Weekdays to 06:05" next to "Set for 06:05" is the same sentence twice.
    ///
    /// It is wrong for anything that is not about the routine. On 18 August the one day override
    /// landed here: a one time change that worked perfectly produced `isPartial == false`, so the
    /// line confirming it, and the line saying the extra alarm clears itself, were both thrown away.
    /// The screen would have said "Set for 06:05" and nothing else, and Alex, who had been asked to
    /// read exactly that line back, would have reported that nothing happened.
    ///
    /// **Found by tracing the value to the pixel rather than to the return statement.** This app's
    /// oldest rule is that a file written on a server is not a post published, and a receipt field
    /// populated is not a sentence on a screen. Four rounds of work had been spent on a message that
    /// could not be displayed.
    var highlights: [String] = []

    /// The time the write **actually sent**, when that is deliberately not the target's time.
    ///
    /// **From Alex's bed, 19 August.** He set a one time change and his Whoop row read
    /// *"Accepted, but it reads back as Mon 07:50 instead of Mon 09:36."* Nothing was wrong. A Whoop
    /// schedule carries one time for all its days, so bending it would move every weekday morning
    /// rather than one, and the adapter refuses on purpose and writes the routine time. Then `verify`
    /// compared the read-back against the **bent** target and called the correct outcome a mismatch,
    /// in yellow, discarding the sentence that explained it.
    ///
    /// Third time this exact shape has cost a round: a write that deliberately differs from the
    /// target, verified against the target anyway. The Eight Sleep skip was the first two. So the
    /// answer stops being a per-adapter patch: **a write that intends a different time says so here,
    /// and verification honours it.**
    var wroteInstead: WallClockTime?

    init(
        device: DeviceID,
        succeededAt: Date,
        remoteID: String?,
        note: String?,
        isPartial: Bool = false,
        highlights: [String] = [],
        wroteInstead: WallClockTime? = nil
    ) {
        self.device = device
        self.succeededAt = succeededAt
        self.remoteID = remoteID
        self.note = note
        self.isPartial = isPartial
        self.highlights = highlights
        self.wroteInstead = wroteInstead
    }
}

/// The result of reading the alarm back and checking it landed where we meant.
enum Verification: Equatable, Sendable {
    /// The remote confirmed an absolute instant matching what we asked for.
    case confirmed(at: Date)
    /// The remote confirmed an instant, and it is not the one we asked for. Almost always a time
    /// zone disagreement, and the reason this case exists at all.
    case mismatch(expected: Date, actual: Date)
    /// The write succeeded but the leg offers nothing to read back against.
    case unavailable(reason: String)
    /// The leg deliberately did something other than the target, and it worked.
    ///
    /// **Not the same thing as `unavailable`, which is where this used to land.** That case renders
    /// as *"Written. Could not confirm: ..."* in yellow, which is right for a leg that cannot be read
    /// back and wrong for one that did exactly what it meant to. On 19 August Alex's Whoop row
    /// carried a warning colour and the words "could not confirm" for a strap that had been switched
    /// off for one morning entirely on purpose, and read back to prove it.
    ///
    /// A warning that fires on a correct outcome is how somebody learns to scroll past warnings.
    case byDesign(String)
    /// The remote is in a state he has to fix, and the sentence says how.
    ///
    /// **Distinct from `byDesign`, which is green and counts as settled.** On 20 August his strap
    /// was at the right time with its alarm switched off, reported as `byDesign`, and the Good night
    /// screen read *"All confirmed. Nothing left to do. Put the phone down."* directly above a row
    /// telling him to go and turn that alarm on.
    ///
    /// Anything ending in an instruction is unfinished by definition, and a summary that calls it
    /// finished is the app talking over itself.
    case mismatchReason(String)

    var isConfirmed: Bool {
        if case .confirmed = self { return true }
        return false
    }
}
