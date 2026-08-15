import Foundation
import Observation

enum DeviceSyncStatus: Equatable {
    case idle
    case writing
    case verifying
    case done(String)
    case warning(String)
    case failed(String)

    var isBusy: Bool { self == .writing || self == .verifying }
}

/// Holds the master time, owns the adapters, and runs the fan out.
///
/// The whole product is one rule: edit the master time once, recompute, write every enabled leg.
/// That rule lives in `apply()`.
@MainActor
@Observable
final class ScheduleStore {

    private(set) var schedule: WakeSchedule
    private(set) var targets: [ResolvedTarget] = []
    private(set) var status: [DeviceID: DeviceSyncStatus] = [:]
    private(set) var authStates: [DeviceID: AuthState] = [:]
    private(set) var lastSyncedAt: Date?
    private(set) var isSyncing = false
    /// True when the schedule has changed since the last successful apply.
    private(set) var needsApply = false
    /// Set when an apply finds nothing to write, so the UI can say so instead of showing a
    /// timestamp that implies alarms were set.
    private(set) var nothingToApply = false

    let alarmKit = AlarmKitAdapter()
    let eightSleep = EightSleepAdapter()
    let whoop = WhoopAdapter()

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar
    }

    private static let storageKey = "OneAlarm.schedule.v1"

    init(schedule: WakeSchedule? = nil) {
        self.schedule = schedule ?? Self.load() ?? .default
        recompute()
    }

    private func adapter(for device: DeviceID) -> (any DeviceAdapter)? {
        switch device {
        case .iphone: return alarmKit
        case .eightSleep: return eightSleep
        case .whoop: return whoop
        }
    }

    // MARK: Editing

    func setMasterTime(_ time: WallClockTime) {
        schedule.masterTime = time
        persistAndRecompute()
    }

    func toggleWeekday(_ day: Locale.Weekday) {
        var days = schedule.weekdays
        if days.contains(day) {
            // Never leave the set empty. An alarm on no days is not an alarm.
            guard days.count > 1 else { return }
            days.remove(day)
        } else {
            days.insert(day)
        }
        schedule.weekdays = days
        persistAndRecompute()
    }

    func setOffset(_ minutes: Int, for device: DeviceID) {
        guard let index = schedule.rules.firstIndex(where: { $0.device == device }) else { return }
        schedule.rules[index].offsetMinutes = max(-120, min(120, minutes))
        persistAndRecompute()
    }

    func setEnabled(_ enabled: Bool, for device: DeviceID) {
        guard let index = schedule.rules.firstIndex(where: { $0.device == device }) else { return }
        schedule.rules[index].isEnabled = enabled
        persistAndRecompute()
    }

    private func persistAndRecompute() {
        persist()
        recompute()
        // Any edit invalidates every previous result. Leaving them on screen puts a green
        // "Set for 06:50" directly under a row now reading 07:50, and nothing distinguishes that
        // from a successful sync.
        status.removeAll()
        needsApply = true
        nothingToApply = false
    }

    func recompute() {
        targets = RulesEngine.resolve(schedule: schedule, calendar: calendar, now: Date())
    }

    func target(for device: DeviceID) -> ResolvedTarget? {
        targets.first { $0.device == device }
    }

    func preview(for device: DeviceID) -> WritePreview? {
        guard let target = target(for: device), let adapter = adapter(for: device) else { return nil }
        return adapter.preview(target)
    }

    // MARK: Auth state

    func refreshAuthStates() async {
        await alarmKit.refreshAuthState()
        await eightSleep.refreshAuthState()
        await whoop.refreshAuthState()
        authStates = [
            .iphone: await alarmKit.authState,
            .eightSleep: await eightSleep.authState,
            .whoop: await whoop.authState,
        ]
    }

    // MARK: The fan out

    /// Write every enabled leg, then verify each one.
    ///
    /// Legs are independent, so one failing must not stop the others. In particular the iPhone
    /// alarm needs no credentials and no network, so it has to still ring when both remote legs are
    /// unreachable. A credential problem is never allowed to become a missed alarm.
    func apply() async {
        guard !isSyncing else { return }
        isSyncing = true
        recompute()
        await refreshAuthStates()

        // Stale entries for devices no longer in play would otherwise reappear as if fresh when a
        // device is re-enabled.
        let live = Set(targets.map(\.device))
        status = status.filter { live.contains($0.key) }

        // A leg with no credentials at all is not a failure, it is a leg that was never set up.
        // Running it anyway paints two red crosses on first launch, which reads as the app being
        // broken when it is working exactly as intended.
        let writable = targets.filter { target in
            guard target.device.requiresCredentials else { return true }
            return (authStates[target.device] ?? .notConfigured) != .notConfigured
        }

        guard !writable.isEmpty else {
            // No timestamp. Stamping one here would tell the user alarms were set when none were,
            // which is the worst possible lie for this app to tell.
            nothingToApply = true
            isSyncing = false
            return
        }

        nothingToApply = false

        await withTaskGroup(of: Void.self) { group in
            for target in writable {
                guard let adapter = adapter(for: target.device) else { continue }
                group.addTask { @MainActor in
                    await self.apply(target: target, using: adapter)
                }
            }
        }

        lastSyncedAt = Date()
        needsApply = false
        isSyncing = false
        await refreshAuthStates()
    }

    /// Re-apply when the clock or the zone moves under us.
    ///
    /// Only the Whoop leg actually needs this, and it needs it badly: its `time_zone_offset` is a
    /// fixed string with no daylight saving awareness, so an alarm written in October fires an hour
    /// wrong from the last Sunday of the month until somebody notices. AlarmKit's relative schedule
    /// and Eight Sleep's server side zone both handle the transition themselves.
    func applyIfClockMoved() async {
        let previous = targets
        recompute()
        let offsetChanged = zip(previous, targets).contains { $0.utcOffsetSeconds != $1.utcOffsetSeconds }
        if offsetChanged || previous.count != targets.count {
            await apply()
        }
    }

    private func apply(target: ResolvedTarget, using adapter: any DeviceAdapter) async {
        status[target.device] = .writing
        do {
            let receipt = try await adapter.write(target)
            status[target.device] = .verifying

            let verification = try await adapter.verify(receipt, against: target)
            switch verification {
            case .confirmed:
                status[target.device] = .done("Set for \(target.localTime.hhmm)")
            case .mismatch(let expected, let actual):
                // The case this whole verification step exists for. A 200 was returned and the
                // alarm still landed somewhere else, almost always a time zone disagreement.
                let formatter = DateFormatter()
                formatter.dateFormat = "EEE HH:mm"
                status[target.device] = .warning(
                    "Accepted, but it reads back as \(formatter.string(from: actual)) instead of \(formatter.string(from: expected))."
                )
            case .unavailable(let reason):
                status[target.device] = .warning("Written. Could not confirm: \(reason)")
            }
        } catch let error as AdapterError {
            status[target.device] = .failed(error.errorDescription ?? "Failed.")
        } catch {
            status[target.device] = .failed(error.localizedDescription)
        }
    }

    // MARK: Persistence

    /// Schedule data only. No credential is ever written here, which is what makes this file safe
    /// to keep in plain `UserDefaults`.
    private func persist() {
        guard let data = try? JSONEncoder().encode(schedule) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private static func load() -> WakeSchedule? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(WakeSchedule.self, from: data)
    }
}
