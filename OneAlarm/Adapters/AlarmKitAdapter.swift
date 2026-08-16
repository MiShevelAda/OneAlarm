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

    /// Persisted so a relaunch can cancel the alarms it scheduled last time instead of stacking more.
    /// Not a secret, so `UserDefaults` is the right home.
    ///
    /// A **map** now, routine key to alarm id, because the phone holds one alarm per routine as of
    /// 17 August. It held exactly one before that, and the single id lived at `storageKey` below,
    /// which is read once on the first write and cancelled so the old alarm cannot outlive the
    /// change. Without that migration his phone would keep an orphan weekly alarm nothing tracks
    /// and nothing can cancel, which is worse than the bug being fixed.
    private let storageKey = "OneAlarm.alarmKit.currentAlarmID"
    private let mapKey = "OneAlarm.alarmKit.alarmIDsByKey"

    private var alarmIDs: [String: UUID] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: mapKey) as? [String: String] ?? [:]
            return raw.compactMapValues(UUID.init(uuidString:))
        }
        set {
            UserDefaults.standard.set(newValue.mapValues(\.uuidString), forKey: mapKey)
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
        // A plan with no entries falls through to a single alarm, which is what this leg did for
        // its whole life before 17 August.
        try await write(target, plan: RoutinePlan(device: .iphone, entries: [], skipsNextMorning: false))
    }

    /// One alarm per routine, so no morning the week covers is left unarmed.
    ///
    /// Until 17 August this scheduled exactly one alarm, from the single resolved target, whose days
    /// were those of the routine covering the **next** morning. With a weekday routine and a weekend
    /// one, a Friday night sync armed Saturday and Sunday and left Monday with nothing. That is a
    /// silent missed morning on the leg that exists because it needs no account and no network.
    ///
    /// What to schedule and what to cancel is decided by `AlarmKitReconciler`, which is pure and
    /// tested. `AlarmManager.shared` is an Apple singleton with no seam, so this function stays a
    /// shell: it does what it is told and reports what happened.
    func write(_ target: ResolvedTarget, plan: RoutinePlan) async throws -> WriteReceipt {
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

        // The single id this leg used to keep. Cancelled once, on the first write after the change,
        // or it becomes a weekly alarm nothing tracks and nothing can ever cancel.
        if let legacy = UserDefaults.standard.string(forKey: storageKey).flatMap(UUID.init(uuidString:)) {
            try? AlarmManager.shared.cancel(id: legacy)
            UserDefaults.standard.removeObject(forKey: storageKey)
        }

        var held = alarmIDs
        let outcome = AlarmKitReconciler.reconcile(plan: plan, target: target, held: Set(held.keys))

        guard !outcome.schedule.isEmpty else {
            // Only reachable when every routine is off or has no days, which is a real setting he
            // can choose. Cancel what is held so the phone does not go on ringing for a week he has
            // switched off, and say so rather than reporting a write that armed nothing.
            for (_, id) in held { try? AlarmManager.shared.cancel(id: id) }
            alarmIDs = [:]
            throw AdapterError.unexpectedResponse("No routine is on, so nothing is armed. Previous alarms were cancelled.")
        }

        // Schedule the new alarms BEFORE cancelling the old ones.
        //
        // The other order looks tidier and is dangerous: if `schedule` throws, and it can, the
        // documented `maximumLimitReached` being one way, the old alarm is already gone and the new
        // one never arrives, so the backstop that exists to always ring has been removed by our own
        // code. AlarmKit holds more than one alarm happily, so a moment of overlap costs nothing,
        // and a duplicate ring is a far better failure than silence.
        var replaced: [UUID] = []
        for wanted in outcome.schedule {
            let id = UUID()
            do {
                _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration(for: wanted))
            } catch let error as AlarmManager.AlarmError {
                throw AdapterError.unexpectedResponse("AlarmKit refused the alarm: \(error).")
            } catch {
                throw AdapterError.unexpectedResponse(error.localizedDescription)
            }
            if let previous = held[wanted.key] { replaced.append(previous) }
            held[wanted.key] = id
        }

        // Only now are the old ones safe to remove. Cancelling an id that no longer exists is
        // expected once an alarm has fired, so a throw here is not worth surfacing.
        for id in replaced { try? AlarmManager.shared.cancel(id: id) }
        for key in outcome.cancel {
            if let id = held.removeValue(forKey: key) { try? AlarmManager.shared.cancel(id: id) }
        }

        alarmIDs = held
        authState = .connected

        // The id `verify` reads back is the one covering the morning the target is for, so the
        // check still means "tonight is armed" rather than "something is armed".
        let calendar = Calendar(identifier: .gregorian)
        let nextWeekday = Locale.Weekday.from(
            calendarIndex: calendar.component(.weekday, from: target.nextOccurrence)
        )
        let covering = outcome.schedule.first { $0.weekdays.contains(nextWeekday) } ?? outcome.schedule[0]

        let note = outcome.schedule.count == 1
            ? "Scheduled with AlarmKit."
            : "Scheduled \(outcome.schedule.count) alarms with AlarmKit, one per routine, so every morning your week covers is armed."

        return WriteReceipt(
            device: .iphone,
            succeededAt: Date(),
            remoteID: held[covering.key]?.uuidString,
            note: note
        )
    }

    /// The AlarmKit configuration for one wanted alarm. Pulled out so `write` reads as what it does.
    private func configuration(for wanted: AlarmKitReconciler.Scheduled) -> AlarmManager.AlarmConfiguration {
        // `.relative` and not `.fixed`. A fixed schedule is an absolute instant that does not track
        // the device time zone and cannot repeat, so a 07:00 wake up expressed that way drifts the
        // moment you change zone. This is the easiest bug to ship in the whole app.
        let time = Alarm.Schedule.Relative.Time(hour: wanted.time.hour, minute: wanted.time.minute)
        let recurrence: Alarm.Schedule.Relative.Recurrence = wanted.weekdays.isEmpty
            ? .never
            : .weekly(Array(wanted.weekdays))
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
        return AlarmManager.AlarmConfiguration(
            countdownDuration: nil,
            schedule: schedule,
            attributes: attributes,
            stopIntent: nil,
            secondaryIntent: nil,
            sound: .default
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
        for id in alarmIDs.values { try? AlarmManager.shared.cancel(id: id) }
        alarmIDs = [:]
        if let legacy = UserDefaults.standard.string(forKey: storageKey).flatMap(UUID.init(uuidString:)) {
            try? AlarmManager.shared.cancel(id: legacy)
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }
}
