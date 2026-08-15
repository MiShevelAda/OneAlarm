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

    static func local(device: DeviceID, summary: String) -> WritePreview {
        WritePreview(device: device, summary: summary, method: "LOCAL", url: "AlarmKit", body: nil)
    }
}

struct WriteReceipt: Equatable, Sendable {
    let device: DeviceID
    let succeededAt: Date
    /// Identifier the remote gave back, when there is one.
    let remoteID: String?
    let note: String?
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

    var isConfirmed: Bool {
        if case .confirmed = self { return true }
        return false
    }
}
