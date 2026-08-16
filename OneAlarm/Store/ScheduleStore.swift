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
    /// The whole week, per device. Only the Eight Sleep leg reads it today, because it is the only
    /// one whose service holds more than one alarm.
    private(set) var plans: [DeviceID: RoutinePlan] = [:]
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
            // The bed and the strap are still holding the bend, and until 17 August nothing said so.
            //
            // An expiring override changes what the two remote legs should be holding, exactly as an
            // edit does, and `needsApply` is how this app says "what is on your devices is not what
            // is on this screen". It was set on every edit and not here, so the one case where the
            // plan changes without him touching anything was also the one case with no banner.
            //
            // A skip is the sharp end. Skipping tomorrow switches the covering routine's Eight Sleep
            // alarm **off**, for the whole routine and not just that morning, because that is the
            // only thing an alarm object can express. When the skip expires the phone re-arms itself
            // below, so he is still woken, and his bed stays switched off until he presses Set all
            // alarms. Silently, with a green "Last set" on screen.
            //
            // Deliberately still not an unattended remote write. See `phoneNeedsRearm` below: the
            // phone is local and the other two are live accounts. This makes the gap visible rather
            // than closing it behind his back.
            needsApply = true
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

    /// A new routine, on the days nothing covers yet.
    ///
    /// It starts with the uncovered days rather than empty, because an empty routine is a card that
    /// does nothing and has to be filled in before it means anything, and the days nobody has
    /// claimed are the only ones it could legally take. When the week is already fully covered it
    /// starts with no days and says so, which is honest: taking a day would silently remove it from
    /// a routine he did not open.
    @discardableResult
    func addRoutine() -> String {
        let covered = schedule.routines.reduce(into: Set<Locale.Weekday>()) { $0.formUnion($1.weekdays) }
        let free = Locale.Weekday.displayOrder.filter { !covered.contains($0) }
        // A UUID, not a timestamp. `Int(Date().timeIntervalSince1970)` was the first version and two
        // taps of Add inside one second produced two routines with the same id, which is a second
        // away on a button that sits right there.
        //
        // A duplicate id is not cosmetic. `RemoteAlarmLink` is keyed on it, so both routines would
        // own one alarm and each sync would have them overwrite each other's time and days.
        // `toggleDay` takes `firstIndex(where:)`, so the second routine's day chips would silently
        // edit the first. `deleteRoutine` uses `removeAll`, so deleting one would delete both. And
        // `Routine` is `Identifiable`, so SwiftUI would drop a row from `ForEach`.
        let id = "routine-\(UUID().uuidString)"

        schedule.routines.append(
            Routine(
                id: id,
                // Stored and immediately ignored: `displayName` derives from the days. Kept only
                // because the field exists in the persisted shape.
                name: "",
                weekdayIndices: WeekdaySetCoding.encode(Set(free)),
                time: schedule.routines.last?.time ?? WallClockTime(hour: 8, minute: 0)
            )
        )
        persistAndRecompute()
        return id
    }

    /// Remove a routine. Its days become uncovered, which the screen names.
    ///
    /// Deliberately does not hand its days to a neighbour. Deleting the weekend routine must not
    /// silently make Saturday a 06:50 workday, and a day with no alarm is a state this app already
    /// prints by name.
    func deleteRoutine(_ routineID: String) {
        schedule.routines.removeAll { $0.id == routineID }
        // A bend belonging to the routine that just went has nothing left to bend away from.
        if let override = schedule.override, let date = override.day.date(in: calendar) {
            let weekday = Locale.Weekday.from(calendarIndex: calendar.component(.weekday, from: date))
            if schedule.routine(covering: weekday) == nil { schedule.override = nil }
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

        let now = Date()
        targets = RulesEngine.resolve(schedule: schedule, calendar: calendar, now: now)

        // The whole week per device, alongside the single next target.
        //
        // Both are kept because they answer different questions. The target is "when does this
        // device go off next", which is what the screen shows and what a write can be verified
        // against. The plan is "what does this device's week look like", which is what a leg holding
        // one alarm per routine needs, and without it the only way to express two routines on one
        // remote alarm is to rewrite that alarm's days every time the week turns over.
        plans = Dictionary(uniqueKeysWithValues: schedule.rules.filter(\.isEnabled).map { rule in
            (rule.device, RulesEngine.plan(for: rule, in: schedule, calendar: calendar, now: now))
        })
    }

    /// True while a bend is armed, so the screen can say what is temporary and when it ends.
    ///
    /// **The routine time is read live, not from the snapshot in the override.** On 17 August Alex's
    /// screen said *"Tomorrow only. Weekdays is still 06:01 and returns after"* directly above a week
    /// list showing Weekdays at **07:01**. Both came from this app, an hour apart, and one of them was
    /// wrong on the sentence whose entire job is telling him what he goes back to.
    ///
    /// `DayOverride.routineTime` is captured when the bend is made, and it has to be: it is what
    /// `restoreAfterOverride` puts back, so it must survive the routine being edited afterwards. What
    /// it must not do is get **displayed** once it is stale. The snapshot answers "what do I restore",
    /// the routine answers "what does he go back to", and those stop being the same value the moment
    /// he edits the routine while a bend is live.
    ///
    /// So the live routine wins here, and the snapshot is the fallback for when the routine is gone.
    var overrideNotice: String? {
        guard let override = schedule.override, let next, next.isOverridden || override.isSkip else {
            return nil
        }
        let routine = override.routineName ?? "your routine"
        // Found by the day it bends, not by name. `Routine.displayName` is **derived from its days**,
        // deliberately, so a name lookup would stop matching the moment he changes them, fall silently
        // back to the snapshot, and reintroduce the stale number this comment exists to remove. The
        // same lookup `makeOverridePermanent` uses, so promoting a bend and describing one can never
        // disagree about which routine is involved.
        let weekday = Locale.Weekday.from(
            calendarIndex: calendar.component(.weekday, from: override.day.date(in: calendar) ?? Date())
        )
        let live = schedule.routines.first { $0.isOn && $0.weekdays.contains(weekday) }?.time
        guard let was = live ?? override.routineTime else { return "Tomorrow only. \(routine) is unchanged." }
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

    /// The routine time a bend is standing in for, so the screen can strike it through.
    ///
    /// **Modelled on Eight Sleep's own screen**, which Alex pointed at on 17 August:
    /// `UPCOMING ALARM ONLY  09:10  0̶9̶:̶3̶0̶`. The new time large, the routine time struck through
    /// beside it, and nothing else. He said he liked it, and it is better than the paragraph it
    /// replaces for a reason worth naming: a struck-through number cannot be misread, while a
    /// sentence saying "Weekdays is still 06:01 and returns after" has to be parsed, and was wrong
    /// for an hour on 17 August without anybody noticing.
    ///
    /// Reads the **live** routine, not `DayOverride.routineTime`, for the same reason `overrideNotice`
    /// does: the snapshot exists so `restoreAfterOverride` can put the right value back, and it goes
    /// stale the moment he edits the routine while a bend is armed. Displaying a stale number is
    /// exactly the bug this pair of properties was written to remove.
    var overriddenRoutineTime: WallClockTime? {
        guard let override = schedule.override, let next, next.isOverridden, !override.isSkip else {
            return nil
        }
        return Self.struckThrough(
            override: override, routines: schedule.routines, showing: next.time, calendar: calendar
        )
    }

    /// Which time to strike through, as a pure function of the three inputs that decide it.
    ///
    /// **Pulled out of the property so it can be tested.** `ScheduleStore` reads the wall clock
    /// through a private `calendar` and has no seam for it, so anything depending on `next` cannot be
    /// asserted deterministically. This part does not depend on `next` at all beyond the time already
    /// on screen, which the caller passes in, so it is testable exactly as written.
    ///
    /// That matters because **this is the logic that was wrong on 17 August**: the screen read the
    /// snapshot in the override rather than the live routine, and told him a routine was "still
    /// 06:01" directly above a list showing 07:01.
    /// `nonisolated` because it touches no state: it is a function of its four arguments. `ScheduleStore`
    /// is `@MainActor`, which would otherwise make even a pure static member unreachable from a
    /// synchronous test, which is exactly what it did.
    nonisolated static func struckThrough(
        override: DayOverride,
        routines: [Routine],
        showing: WallClockTime,
        calendar: Calendar
    ) -> WallClockTime? {
        guard !override.isSkip else { return nil }

        // Found by the day it bends, not by name. `Routine.displayName` is derived from its days, so
        // a name lookup would stop matching the moment he changes them and fall silently back to the
        // snapshot, which is the stale number this exists to avoid.
        let live: WallClockTime?
        if let date = override.day.date(in: calendar) {
            let weekday = Locale.Weekday.from(calendarIndex: calendar.component(.weekday, from: date))
            live = routines.first { $0.isOn && $0.weekdays.contains(weekday) }?.time
        } else {
            live = nil
        }

        // The snapshot is the fallback, never the first answer. It exists so `restoreAfterOverride`
        // can put the right value back and it goes stale the moment he edits the routine.
        guard let was = live ?? override.routineTime else { return nil }
        // Only worth striking through if it actually differs. Equal numbers side by side, one with a
        // line through it, reads as a bug rather than as information.
        return was == showing ? nil : was
    }

    /// "Tomorrow only", "Saturday only". The label above the big number while a **bend** is armed.
    ///
    /// **Deliberately nil for a skip**, and the difference matters. A bend replaces the next morning,
    /// so the big number IS that morning and "Tomorrow only" describes it exactly. A skip removes it,
    /// so `next` has already moved on to the morning after, and putting "Tomorrow only" above a time
    /// that is not tomorrow would be a worse lie than the paragraph this replaced. The skip says its
    /// piece in `overrideFooter`, where it can name the day it removed.
    var overrideHeadline: String? {
        guard let override = schedule.override, let next, next.isOverridden, !override.isSkip else {
            return nil
        }
        return dayLabel(override.day) + " only"
    }

    /// What happens after the one-off, in one short line rather than a paragraph.
    var overrideFooter: String? {
        guard let override = schedule.override, let next, next.isOverridden || override.isSkip else {
            return nil
        }
        let routine = override.routineName ?? "Your routine"
        if override.isSkip {
            return "No alarm on \(dayLabel(override.day)). \(routine) is back after that, unchanged."
        }
        // **"Nothing about it changed" was false on the bed, and he caught it.** 17 August 17:02: he
        // bent one Monday to 09:40 and his Eight Sleep app went to `EVERY WEEKDAY 09:30`. The whole
        // series, for a bend about one morning.
        //
        // True of the routine in OneAlarm, and OneAlarm is not the only thing he looks at. Eight
        // Sleep has a native one-off, `UPCOMING ALARM ONLY`, and this app writes `time` on the
        // recurring alarm instead, so a bend really does move his week there until the next sync
        // puts it back. `E23` is the fix. Until it lands the screen says so, because a sentence
        // promising nothing changed, above a bed where something did, is the exact kind of claim
        // this project keeps having to retract.
        let bedIsLinked = authStates[.eightSleep]?.isConnected == true
        guard bedIsLinked else { return "\(routine) is back the next day. Nothing about it changed." }
        return "\(routine) is back the next day. Your bed shows the whole week at this time until then, which is an Eight Sleep limit OneAlarm is working around."
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
        // Both of these legs act once per routine now, so a preview built from the single next
        // target would show one of them and imply it was the whole write. The gate has already told
        // one lie of that shape, and it was the screen Alex went to in order to rule the bug out.
        guard let plan = plans[device] else { return adapter.preview(target) }
        if let eight = adapter as? EightSleepAdapter { return eight.preview(target, plan: plan) }
        if let phone = adapter as? AlarmKitAdapter { return phone.preview(target, plan: plan) }
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
            // **Rebuilt rather than emptied, and this fallback is a landmine rather than tidiness.**
            //
            // An empty plan is not a neutral value on the Eight Sleep leg. The adapter synthesises a
            // single entry from `target` when the plan has no entries, and while a bend is armed
            // `recompute` has collapsed `schedule.weekdays` to the one weekday the bend falls on. So
            // an empty plan during a bend would write a **one day** repeat set onto a real alarm of
            // his, which is precisely the failure that turned a Monday to Friday schedule into every
            // day, and precisely what a bend did to his Whoop week this afternoon.
            //
            // Today it cannot fire: `plans` and `targets` are both built from
            // `schedule.rules.filter(\.isEnabled)`, so every target has a plan. That is a coincidence
            // of two filters agreeing, not a guarantee, and the cost of it ever stopping being true
            // is a rewritten alarm nobody sees until a morning is missed. Rebuilding costs one pass
            // over two routines.
            let plan = plans[target.device]
                ?? schedule.rules.first { $0.device == target.device }.map {
                    RulesEngine.plan(for: $0, in: schedule, calendar: calendar, now: Date())
                }
                ?? RoutinePlan(device: target.device, entries: [], skipsNextMorning: false)
            let receipt = try await adapter.write(target, plan: plan)
            status[target.device] = .verifying

            let verification = try await adapter.verify(receipt, against: target)
            switch verification {
            case .confirmed(let instant):
                // What the **server** says, in its own words, next to what we asked for.
                //
                // Added 16 Aug after Alex reported the bed alarm not changing in the Eight Sleep
                // app. The screen at that moment said "Set Weekdays to 08:55" and nothing else,
                // because a partial write replaced the whole status line with its own note and threw
                // the verification away. So the one fact that separates "our write did not land"
                // from "their app is not showing what landed" was computed, discarded, and then
                // argued about. It is printed now, always.
                let formatter = DateFormatter()
                formatter.dateFormat = "EEE HH:mm"
                let echo = "Eight Sleep reads back \(formatter.string(from: instant))."
                let confirmation = target.device == .eightSleep
                    ? echo
                    : "Confirmed for \(target.localTime.hhmm)."

                // A partial write is not a done write. On a leg holding one alarm per routine, two
                // routines can land and a third can have no alarm with its days, and the morning
                // that third routine covers is then not carried by this device at all. A green tick
                // over that is the one lie this app must never tell.
                // **Highlights survive a clean write. The note does not.**
                //
                // A one time change that worked perfectly produced `isPartial == false`, so the line
                // confirming it went into the `else` branch below and was discarded. The screen said
                // "Set for 06:05" and nothing about the one time change at all. Four rounds of work
                // on a message that could not be displayed, and Alex had been asked to read that
                // exact line back.
                let extra = receipt.highlights.joined(separator: " ")
                if receipt.isPartial, let note = receipt.note {
                    status[target.device] = .warning("\(note) \(confirmation)")
                } else if !extra.isEmpty {
                    status[target.device] = .done("Set for \(target.localTime.hhmm). \(extra) \(confirmation)")
                } else {
                    status[target.device] = .done("Set for \(target.localTime.hhmm). \(confirmation)")
                }
            case .mismatch(let expected, let actual):
                // The case this whole verification step exists for. A 200 was returned and the
                // alarm still landed somewhere else, almost always a time zone disagreement.
                let formatter = DateFormatter()
                formatter.dateFormat = "EEE HH:mm"
                // Highlights here too. This branch is the loudest thing the app can say, so it is
                // the last place that should also swallow the sentence explaining what happened.
                let detail = receipt.highlights.isEmpty
                    ? ""
                    : " " + receipt.highlights.joined(separator: " ")
                status[target.device] = .warning(
                    "Accepted, but it reads back as \(formatter.string(from: actual)) instead of \(formatter.string(from: expected))."
                    + detail
                )
            case .unavailable(let reason):
                // Same rule here. This is the branch a Whoop write always takes, and the branch an
                // Eight Sleep write takes when the morning's own alarm was not among the ones that
                // landed, which is exactly when a one time change is most worth reporting.
                var head = receipt.isPartial ? (receipt.note ?? "Written.") : "Written."
                if !receipt.isPartial, !receipt.highlights.isEmpty {
                    head += " " + receipt.highlights.joined(separator: " ")
                }
                status[target.device] = .warning("\(head) Could not confirm: \(reason)")
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
