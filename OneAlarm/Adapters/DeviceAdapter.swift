import Foundation

enum AuthState: Equatable, Sendable {
    case notConfigured
    case connected
    /// Credentials exist but the remote rejected them. A first class UI state, never a silent
    /// failure, and never a reason to delete the stored credential.
    case needsReauth(String)

    var isConnected: Bool { self == .connected }
}

enum AdapterError: LocalizedError, Equatable {
    case notConfigured
    case authenticationFailed(String)
    /// Eight Sleep gates the alarm endpoint behind an active subscription and returns this even
    /// though authentication succeeded. Its own case so it never reads as a bug in our code.
    case subscriptionRequired
    case rateLimited
    case noAlarmToUpdate
    /// Several alarms exist and none has been chosen. Not a failure, a question.
    ///
    /// Still thrown by the Whoop leg, which holds one schedule per account and genuinely can be
    /// ambiguous. The Eight Sleep leg no longer raises it: each routine owns an alarm, recorded in
    /// `RemoteAlarmLink`, so there is nothing left to choose.
    case alarmChoiceNeeded(count: Int)
    /// Alarms exist, none has the days of any routine, and creating one did not work either.
    ///
    /// Narrower than it used to be. Before the create shipped this was the ordinary outcome of a
    /// week the account could not express; now it means the fallback failed too, so it is a fault
    /// rather than a question. What it never licenses is reshaping somebody's alarm to fit: OneAlarm
    /// writes days only to an alarm a routine **owns**, and by definition none of these is owned.
    case noMatchingDays(routines: [String], alarms: [String])
    case unexpectedResponse(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Not connected yet."
        case .authenticationFailed(let detail):
            return "Sign in failed. \(detail)"
        case .subscriptionRequired:
            return "Eight Sleep says this account needs an active subscription to use alarms."
        case .rateLimited:
            return "Too many requests. Waiting before trying again."
        case .noAlarmToUpdate:
            // Actionable on purpose: "none found" is a thing he can fix in thirty seconds if the
            // message says how. Still accurate after the create shipped, and worth the sentence
            // explaining why. OneAlarm creates alarms now,
            // but only by copying one this account already has: with zero alarms there is nothing
            // to copy, and composing a payload from scratch is where the reference library
            // contradicts itself about the field names that carry the bed's temperature.
            return "No alarm on this account yet. Make one in the device's own app, any time you like, and OneAlarm can copy its settings from then on."
        case .alarmChoiceNeeded(let count):
            return "This account has \(count) alarms. Choose which one OneAlarm should move."
        case .noMatchingDays(let routines, let alarms):
            let wanted = routines.joined(separator: " and ")
            guard !alarms.isEmpty else {
                return "No alarm on your bed runs on \(wanted), and OneAlarm could not make one. Try Set all alarms again, and if it keeps failing the row says what Eight Sleep replied."
            }
            return "No alarm on your bed runs on \(wanted), and OneAlarm could not make one. It has \(alarms.joined(separator: ", ")), and it will not reshape one of those to fit, because that would move a morning you did not ask it to move."
        case .unexpectedResponse(let detail):
            return "Unexpected response. \(detail)"
        case .transport(let detail):
            return "Could not reach the service. \(detail)"
        }
    }
}

/// One leg of the fan out.
///
/// The shape is deliberate in three ways.
///
/// `preview` does no I/O, so the debug gate can show the exact outbound payload with no chance of
/// sending it, and previews can be asserted in tests without a network.
///
/// `verify` is separate from `write`, because on both remote legs a 200 is not evidence. Eight
/// Sleep resolves a bare wall clock string against a time zone we never see, so "the write
/// returned 200" and "the alarm is set for the moment we meant" are genuinely different facts.
///
/// There is no delete, no temperature, no bed angle. Both bearer tokens reach endpoints that run
/// the pump or move the bed frame, so each adapter carries an allowlist of the paths it may call
/// and the protocol gives it no way to express anything else.
protocol DeviceAdapter: Actor {
    nonisolated var device: DeviceID { get }

    var authState: AuthState { get }

    func refreshAuthState() async

    /// Pure. Safe to call at any time, including with no credentials.
    nonisolated func preview(_ target: ResolvedTarget) -> WritePreview

    func write(_ target: ResolvedTarget) async throws -> WriteReceipt

    /// Write the whole week, when the leg can hold more than one alarm.
    ///
    /// Optional by design. AlarmKit and Whoop each hold **one** schedule with one day set, so the
    /// single target is the whole truth for them and this method's default forwards to it. Eight
    /// Sleep holds a list, one alarm per day set, and for that leg a single target cannot say what
    /// the week looks like without rewriting somebody's days to fit it.
    func write(_ target: ResolvedTarget, plan: RoutinePlan) async throws -> WriteReceipt

    func verify(_ receipt: WriteReceipt, against target: ResolvedTarget) async throws -> Verification
}

extension DeviceAdapter {
    func write(_ target: ResolvedTarget, plan: RoutinePlan) async throws -> WriteReceipt {
        try await write(target)
    }
}

extension DeviceAdapter {
    /// Anything inside a minute of the intended instant counts. Remotes round to the minute and one
    /// leg stores seconds it never asked us for.
    nonisolated func matches(_ actual: Date, _ expected: Date) -> Bool {
        abs(actual.timeIntervalSince(expected)) < 60
    }
}
