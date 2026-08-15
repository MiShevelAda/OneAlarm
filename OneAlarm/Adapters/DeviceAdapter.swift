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
            // Actionable on purpose. OneAlarm moves an alarm you already have rather than creating
            // one, so "none found" is a thing you can fix in thirty seconds if the message says how.
            return "No alarm found to move. Create one alarm in the device's own app first, then connect again."
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

    func verify(_ receipt: WriteReceipt, against target: ResolvedTarget) async throws -> Verification
}

extension DeviceAdapter {
    /// Anything inside a minute of the intended instant counts. Remotes round to the minute and one
    /// leg stores seconds it never asked us for.
    nonisolated func matches(_ actual: Date, _ expected: Date) -> Bool {
        abs(actual.timeIntervalSince(expected)) < 60
    }
}
