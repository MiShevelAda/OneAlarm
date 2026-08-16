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

    /// v2 because `routines` is a new non optional field, and Swift's synthesized decoder does not
    /// fall back to a property's default value when the key is missing: it throws. A v1 payload
    /// would therefore fail to decode and fall through to `.default` anyway. Bumping the key makes
    /// that a deliberate reset rather than a silent one, at the cost of re-entering the times once.
    private static let storageKey = "OneAlarm.schedule.v2"

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

    // MARK: The next alarm

    /// Which morning is next, what time, and whether that time came from a routine or from a bend.
    struct NextAlarm: Equatable {
        var day: CalendarDay
        var date: Date
        var weekday: Locale.Weekday
        var time: WallClockTime
        var routineName: String?
        var routineID: String?
        var isOverridden: Bool
        var isSkipped: Bool
        /// What the routine would have said, when an override is in force.
        var routineTime: WallClockTime?
    }

    private(set) var next: NextAlarm?

    /// The first day from today onwards that has an alarm, looking at most two weeks ahead.
    ///
    /// Two weeks rather than seven days because a single routine with one day on it, plus a skip on
    /// that day, is eight days out and is a real thing somebody can configure.
    private func resolveNext() -> NextAlarm? {
        let now = Date()
        let today = calendar.startOfDay(for: now)

        for offset in 0...14 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let day = CalendarDay(date, in: calendar)
            let weekday = Locale.Weekday.from(calendarIndex: calendar.component(.weekday, from: date))
            let routine = schedule.routine(covering: weekday)
            let override = schedule.override?.day == day ? schedule.override : nil

            if override?.isSkip == true { continue }

            guard let time = override?.time ?? routine?.time else { continue }

            // Today only counts if the time has not already passed.
            if offset == 0 {
                var parts = calendar.dateComponents([.year, .month, .day], from: date)
                parts.hour = time.hour
                parts.minute = time.minute
                if let instant = calendar.date(from: parts), instant <= now { continue }
            }

            return NextAlarm(
                day: day,
                date: date,
                weekday: weekday,
                time: time,
                routineName: routine?.displayName,
                routineID: routine?.id,
                isOverridden: override != nil,
                isSkipped: false,
                routineTime: override != nil ? routine?.time : nil
            )
        }
        return nil
    }

    /// Drop an override whose day has passed, so it can never fire on a morning nobody chose.
    ///
    /// Runs on launch and on every recompute rather than on a timer, because a timer that did not
    /// run is indistinguishable from one that did.
    private func purgeExpiredOverride() {
        guard let override = schedule.override else { return }
        if override.day < CalendarDay(Date(), in: calendar) {
            schedule.override = nil
            phoneNeedsRearm = true
            persist()
        }
    }

    /// Set when an expired bend has just been cleared.
    ///
    /// This is a real hazard rather than tidiness. While a bend is in force the phone is armed for
    /// **one weekday**, because that is the only way AlarmKit can express "this Saturday and not
    /// every Saturday". When the bend expires, the routine's other days are unarmed until something
    /// re-arms them, and waiting for the next manual press is how a Monday goes missing.
    private(set) var phoneNeedsRearm = false

    /// Re-arm the phone by itself. Never the two remote legs.
    ///
    /// Safe to do unattended precisely because it is local: no account, no network, no request, and
    /// the value is one the user already authored. The same act against Eight Sleep or Whoop would
    /// be an unattended write to a live account and needs a tap.
    func rearmPhoneIfNeeded() async {
        guard phoneNeedsRearm else { return }
        phoneNeedsRearm = false
        guard let target = targets.first(where: { $0.device == .iphone }),
              schedule.rule(for: .iphone)?.isEnabled == true else { return }
        await apply(target: target, using: alarmKit)
    }

    // MARK: Editing

    /// Bend the next morning only, leaving the routine alone.
    ///
    /// This is the default for every change made from the main screen. At 23:41 the intent is
    /// almost always "tomorrow", changing a routine is a twice a year act, and a decision the user
    /// answers the same way nine times in ten is a tax rather than a safeguard. The mistake this
    /// makes is visible and one tap from being fixed; the opposite default rewrites a routine
    /// silently and is discovered a week later.
    func bendNextMorning(to time: WallClockTime) {
        guard let next else { return }
        schedule.override = DayOverride(
            day: next.day,
            time: time,
            routineTime: next.routineTime ?? next.time,
            routineName: next.routineName
        )
        persistAndRecompute()
    }

    /// No alarm on the next morning. The routine is untouched and returns the day after.
    func skipNextMorning() {
        guard let next else { return }
        schedule.override = DayOverride(
            day: next.day,
            time: nil,
            routineTime: next.routineTime ?? next.time,
            routineName: next.routineName
        )
        persistAndRecompute()
    }

    /// Promote the bend into the routine that covers that day.
    func makeOverridePermanent() {
        guard let override = schedule.override, let time = override.time else { return }
        let weekday = Locale.Weekday.from(
            calendarIndex: calendar.component(.weekday, from: override.day.date(in: calendar) ?? Date())
        )
        if let index = schedule.routines.firstIndex(where: { $0.isOn && $0.weekdays.contains(weekday) }) {
            schedule.routines[index].time = time
        }
        schedule.override = nil
        persistAndRecompute()
    }

    func clearOverride() {
        schedule.override = nil
        persistAndRecompute()
    }

    func setRoutineTime(_ time: WallClockTime, routineID: String) {
        guard let index = schedule.routines.firstIndex(where: { $0.id == routineID }) else { return }
        schedule.routines[index].time = time
        persistAndRecompute()
    }

    /// Move a day from whichever routine holds it into this one, or out of every routine.
    ///
    /// A day in two routines is two answers to the same question, so the move is a move rather than
    /// an add. A day in none means no alarm, which is a legitimate answer and is printed by name.
    func toggleDay(_ day: Locale.Weekday, in routineID: String) {
        guard let index = schedule.routines.firstIndex(where: { $0.id == routineID }) else { return }
        if schedule.routines[index].weekdays.contains(day) {
            schedule.routines[index].weekdays.remove(day)
        } else {
            for other in schedule.routines.indices {
                schedule.routines[other].weekdays.remove(day)
            }
            schedule.routines[index].weekdays.insert(day)
        }
        persistAndRecompute()
    }

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

    /// Set one device's own wake time. Everything else stays where it is.
    ///
    /// The offsets have existed since the first build and nothing has ever called this, so they
    /// have been stuck at minus ten and minus five and unreachable.
    func setDeviceTime(_ time: WallClockTime, for device: DeviceID) {
        let delta = time.minutesSinceMidnight - schedule.masterTime.minutesSinceMidnight
        // Shortest way round the clock, so 23:55 against an 00:05 anchor reads as ten minutes
        // earlier rather than fourteen hours later.
        let wrapped = (((delta + 720) % 1440) + 1440) % 1440 - 720
        setOffset(wrapped, for: device)
    }

    /// Make this device the one whose clock the routine time is written in.
    ///
    /// Every device keeps the exact moment it already had. The routine time moves into the new
    /// anchor's clock and every offset is re-based against it, so the arithmetic changes and not a
    /// single alarm does.
    func makeAnchor(_ device: DeviceID) {
        guard device != schedule.anchorDevice,
              let shift = schedule.rule(for: device)?.offsetMinutes else { return }

        for index in schedule.rules.indices {
            schedule.rules[index].offsetMinutes -= shift
        }
        for index in schedule.routines.indices {
            schedule.routines[index].time = WallClockTime(
                minutesSinceMidnight: schedule.routines[index].time.minutesSinceMidnight + shift
            )
        }
        if let time = schedule.override?.time {
            schedule.override?.time = WallClockTime(minutesSinceMidnight: time.minutesSinceMidnight + shift)
        }
        if let time = schedule.override?.routineTime {
            schedule.override?.routineTime = WallClockTime(minutesSinceMidnight: time.minutesSinceMidnight + shift)
        }
        schedule.anchorDevice = device
        persistAndRecompute()
    }

    /// Every device at the same moment. A stated choice rather than a set of coincidences.
    func ringTogether() {
        for index in schedule.rules.indices {
            schedule.rules[index].offsetMinutes = 0
        }
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
        purgeExpiredOverride()
        next = resolveNext()

        // The derived pair. Everything downstream works in these terms, so resolution ends by
        // writing the answer into them rather than by teaching four other files about routines.
        if let next {
            schedule.masterTime = next.time
            if next.isOverridden {
                // A bend arms one morning. The routine's other days are deliberately dropped from
                // this pass: on the phone that is the suppression an override requires, and on the
                // two remote legs it is what stops the bend leaking onto every day the routine
                // covers. `restoreAfterOverride()` puts them back.
                schedule.weekdays = [next.weekday]
            } else if let routine = schedule.routine(covering: next.weekday) {
                schedule.weekdays = routine.weekdays
            }
        }

        targets = RulesEngine.resolve(schedule: schedule, calendar: calendar, now: Date())
    }

    /// True while a bend is armed, so the screen can say what is temporary and when it ends.
    var overrideNotice: String? {
        guard let override = schedule.override, let next, next.isOverridden || override.isSkip else {
            return nil
        }
        let routine = override.routineName ?? "your routine"
        guard let was = override.routineTime else { return "Tomorrow only. \(routine) is unchanged." }
        if override.isSkip {
            return "No alarm on \(dayLabel(override.day)). \(routine) is still \(was.hhmm) and returns after."
        }
        return "\(dayLabel(override.day)) only. \(routine) is still \(was.hhmm) and returns after."
    }

    /// Days no routine covers, named. Silence should be stated, never inferred from an absence.
    var uncoveredDays: String? {
        let covered = schedule.routines.filter(\.isOn).reduce(into: Set<Locale.Weekday>()) {
            $0.formUnion($1.weekdays)
        }
        let missing = Locale.Weekday.displayOrder.filter { !covered.contains($0) }
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.shortLabel)
        guard names.count > 1, let last = names.last else { return names.joined() }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Whether this leg can actually do anything right now.
    ///
    /// The phone needs no account, so it is always usable. The other two are only usable once they
    /// are signed in, and a leg that cannot be written is not a leg that is merely idle: it belongs
    /// at the bottom of the list, greyed, with its switch off, rather than sitting among the
    /// working ones showing a time it will never keep.
    func isConnected(_ device: DeviceID) -> Bool {
        guard device.requiresCredentials else { return true }
        return authStates[device] == .connected
    }

    /// The main alarm first, then everything else in the order it fires.
    ///
    /// Not pure firing order. The main alarm is the one the whole cascade is arranged around, and
    /// it is usually the last to go off, so chronological order buries it at the bottom. Alex asked
    /// twice for it to be obvious which one is dominant, and position is the cheapest way to say so.
    /// The cost is that the times below it are no longer a straight countdown, which is why each
    /// row states its distance from the main alarm in words.
    var orderedTargets: [ResolvedTarget] {
        let anchor = schedule.anchorDevice
        return targets.sorted { lhs, rhs in
            // Connected before not, ahead of everything else including the anchor. A greyed row at
            // the top of the list would be the most prominent thing on the screen and the least
            // able to act on it.
            let l = isConnected(lhs.device), r = isConnected(rhs.device)
            if l != r { return l }
            if lhs.device == anchor { return true }
            if rhs.device == anchor { return false }
            return lhs.nextOccurrence < rhs.nextOccurrence
        }
    }

    /// How far this device sits from the main alarm, in words.
    func distanceFromMain(_ device: DeviceID) -> String? {
        guard device != schedule.anchorDevice,
              let minutes = schedule.rule(for: device)?.offsetMinutes else { return nil }
        if minutes == 0 { return "same time as \(schedule.anchorDevice.displayName)" }
        let unit = abs(minutes) == 1 ? "minute" : "minutes"
        return "\(abs(minutes)) \(unit) \(minutes < 0 ? "before" : "after") \(schedule.anchorDevice.displayName)"
    }

    func dayLabel(_ day: CalendarDay) -> String {
        guard let date = day.date(in: calendar) else { return "that day" }
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    /// How the next alarm should be described, with the day always named.
    ///
    /// A time with no day is what made a correct weekday alarm read as a broken app when it was
    /// tested at 01:00 on a Sunday.
    var nextAlarmHeadline: String {
        guard let next else { return "No alarm set" }
        let date = next.date
        if calendar.isDateInToday(date) { return "Later today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow, " + date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
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
        // Keyed by device rather than zipped. `targets` is sorted by when each one fires, and that
        // order is not stable: an offset that crosses midnight moves a device nearly a week away
        // and reorders the array, so comparing position against position compares two different
        // devices and gets the answer wrong in both directions.
        let before = Dictionary(uniqueKeysWithValues: targets.map { ($0.device, $0.utcOffsetSeconds) })
        recompute()
        let after = Dictionary(uniqueKeysWithValues: targets.map { ($0.device, $0.utcOffsetSeconds) })

        guard before != after else { return }
        await apply()
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
