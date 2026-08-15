import AlarmKit
import ActivityKit
import Foundation
import SwiftUI

/// AlarmKit carries arbitrary app data alongside an alarm. We need none, and the protocol allows an
/// empty conformance.
struct OneAlarmMetadata: AlarmMetadata {
    init() {}
}

/// The iPhone leg, and the only one that needs no credentials, no network and no reverse
/// engineering. It is also the loud backstop: AlarmKit alarms break through Silent and Focus, and
/// they surface on a paired Apple Watch with no watch target to build.
///
/// Deliberately alert only. Adding snooze means a countdown presentation, and a countdown
/// presentation makes a Widget Extension mandatory: without one the system may dismiss alarms and
/// fail to alert, silently. That is a whole extra target for a feature nobody asked for, so snooze
/// is a later decision rather than a v1 default.
actor AlarmKitAdapter: DeviceAdapter {

    nonisolated let device: DeviceID = .iphone

    private(set) var authState: AuthState = .notConfigured

    /// Persisted so a relaunch can cancel the alarm it scheduled last time instead of stacking a
    /// second one. Not a secret, so `UserDefaults` is the right home.
    private let storageKey = "OneAlarm.alarmKit.currentAlarmID"

    private var currentAlarmID: UUID? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: storageKey) else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: storageKey)
            }
        }
    }

    func refreshAuthState() async {
        switch AlarmManager.shared.authorizationState {
        case .authorized:
            authState = .connected
        case .denied:
            authState = .needsReauth("Alarm permission was denied. Turn it back on in Settings.")
        case .notDetermined:
            authState = .notConfigured
        @unknown default:
            authState = .notConfigured
        }
    }

    /// True only before the one time prompt has ever been answered.
    var needsAuthorizationPrompt: Bool {
        AlarmManager.shared.authorizationState == .notDetermined
    }

    /// Asking explicitly only controls *when* the prompt appears. AlarmKit will ask on its own the
    /// first time an alarm is scheduled if we never call this, which is precisely what we do not
    /// want: that prompt would land inside the fan out, where nothing can time it out.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let state = try await AlarmManager.shared.requestAuthorization()
            authState = (state == .authorized)
                ? .connected
                : .needsReauth("Alarm permission was declined.")
            return state == .authorized
        } catch {
            authState = .needsReauth("Could not request alarm permission.")
            return false
        }
    }

    nonisolated func preview(_ target: ResolvedTarget) -> WritePreview {
        let days = Locale.Weekday.displayOrder
            .filter { target.weekdays.contains($0) }
            .map(\.shortLabel)
            .joined(separator: " ")
        return .local(
            device: .iphone,
            summary: "Repeating alarm at \(target.localTime.hhmm) on \(days), breaking through Silent and Focus."
        )
    }

    func write(_ target: ResolvedTarget) async throws -> WriteReceipt {
        // Deliberately does NOT prompt. `requestAuthorization()` awaits a system alert with no
        // timeout, and a fan out that waits on it hangs forever if the user swipes the alert away,
        // leaving the Apply button spinning and disabled with no other way to set an alarm. The
        // prompt belongs at launch and on the Connections screen, where a human is already looking
        // at it.
        guard AlarmManager.shared.authorizationState == .authorized else {
            throw AdapterError.authenticationFailed(
                "Alarm permission is needed. Open Connections and tap Request permission."
            )
        }

        // `.relative` and not `.fixed`. A fixed schedule is an absolute instant that does not track
        // the device time zone and cannot repeat, so a 07:00 wake up expressed that way drifts the
        // moment you change zone. This is the easiest bug to ship in the whole app.
        let time = Alarm.Schedule.Relative.Time(hour: target.localTime.hour, minute: target.localTime.minute)
        let recurrence: Alarm.Schedule.Relative.Recurrence = target.weekdays.isEmpty
            ? .never
            : .weekly(Array(target.weekdays))
        let schedule: Alarm.Schedule = .relative(.init(time: time, repeats: recurrence))

        // iOS 26.1 replaced the developer supplied stop button with a system slide to stop control,
        // so no stop button is constructed here.
        let alert = AlarmPresentation.Alert(title: "Wake up")

        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: OneAlarmMetadata(),
            tintColor: Color.accentColor
        )

        // Every argument is passed explicitly, including the ones with defaults, so overload
        // resolution cannot drift to the App Entity variant of this initialiser.
        let configuration = AlarmManager.AlarmConfiguration(
            countdownDuration: nil,
            schedule: schedule,
            attributes: attributes,
            stopIntent: nil,
            secondaryIntent: nil,
            sound: .default
        )

        // Schedule the new alarm BEFORE cancelling the old one.
        //
        // The other order looks tidier and is dangerous: if `schedule` throws, and it can, the
        // documented `maximumLimitReached` being one way, the old alarm is already gone and the new
        // one never arrives, so the backstop that exists to always ring has been removed by our own
        // code. AlarmKit holds more than one alarm happily, so a moment of overlap costs nothing,
        // and a duplicate ring is a far better failure than silence.
        let id = UUID()
        do {
            _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        } catch let error as AlarmManager.AlarmError {
            throw AdapterError.unexpectedResponse("AlarmKit refused the alarm: \(error).")
        } catch {
            throw AdapterError.unexpectedResponse(error.localizedDescription)
        }

        // Only now is the previous one safe to remove. Cancelling an id that no longer exists is
        // expected once an alarm has fired, so a throw here is not worth surfacing.
        if let previous = currentAlarmID, previous != id {
            try? AlarmManager.shared.cancel(id: previous)
        }

        currentAlarmID = id
        authState = .connected

        return WriteReceipt(
            device: .iphone,
            succeededAt: Date(),
            remoteID: id.uuidString,
            note: "Scheduled with AlarmKit."
        )
    }

    /// AlarmKit is the one leg where the schedule can be read straight back off the system, so the
    /// check is real rather than a formality. A fired one shot alarm is deleted from the store, but
    /// ours repeats weekly, so absence here means it genuinely is not scheduled.
    func verify(_ receipt: WriteReceipt, against target: ResolvedTarget) async throws -> Verification {
        guard let id = receipt.remoteID.flatMap(UUID.init(uuidString:)) else {
            return .unavailable(reason: "No alarm identifier was returned.")
        }
        do {
            let scheduled = try AlarmManager.shared.alarms
            guard scheduled.contains(where: { $0.id == id }) else {
                return .unavailable(reason: "AlarmKit no longer lists this alarm.")
            }
            return .confirmed(at: target.nextOccurrence)
        } catch {
            return .unavailable(reason: "Could not read alarms back from AlarmKit.")
        }
    }

    func cancelAll() async {
        if let existing = currentAlarmID {
            try? AlarmManager.shared.cancel(id: existing)
            currentAlarmID = nil
        }
    }
}
