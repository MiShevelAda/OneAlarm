import Foundation

/// Every routine the user has, projected onto one device's clock.
///
/// Alex, 2026-08-16: *"I shouldn't actually pick routines. The routine should be updated
/// accordingly. So if I'm updating a routine Monday to Friday, they should override the Eight Sleep
/// routine Monday to Friday. And if I update the routine Friday, Saturday, it should update the
/// Friday, Saturday routine automatically. This should be happening in the background. So what I
/// should be able to pick is just the bed, and I should not pick a routine. This doesn't make sense
/// to me."*
///
/// He is right, and it also explains damage that had already happened. The old model sent **one**
/// resolved target, so a service holding two alarms had to be told which one to move. Picking one
/// meant that when the weekend routine came round, the app rewrote the weekday alarm's **days** to
/// Saturday and Sunday. That is how a real Monday to Friday Whoop schedule became `EVERY DAY`.
///
/// This type removes the destructive operation rather than guarding it. A routine drives exactly one
/// remote alarm and no routine ever reaches another's.
///
/// **Amended the same day.** The first version of this comment said days stop being something
/// OneAlarm writes, and that they become only a key to match on. That was right for about four
/// hours and then Alex set the goal properly: *"OneAlarm is my one single source of truth for alarm
/// setting... only the modifications of temperature, vibration etc should be done in the respective
/// app. So whenever I change something on the routine or one time off, it should be done in the
/// OneAlarm app and should be written into the other apps."*
///
/// Matching by days cannot reach that. Change a routine from Monday to Friday into Monday to
/// Wednesday and the match evaporates: the alarm that has served it for weeks is no longer
/// recognised, and his bed keeps the old days forever. So ownership is recorded instead, in
/// `RemoteAlarmLink`, and an owned alarm has its time, its days and its on switch authored from the
/// routine. The original ban was never about days being sacred. It was about writing them to an
/// alarm nobody had established was ours.
struct RoutinePlan: Equatable, Sendable {
    /// The one morning an override applies to, in both the forms a device leg needs.
    ///
    /// Kept together in one type rather than as two optionals on `Entry`, because they are only ever
    /// correct as a pair: the weekday is what an alarm's day set is written from, the date is what
    /// tells a later sync that this override is over and its alarm can go. Two optionals that must
    /// agree is an invariant nobody can enforce.
    struct OverrideDay: Equatable, Sendable {
        /// The calendar day the user chose.
        let date: CalendarDay
        /// The weekday it lands on **for this device**, after the lead has been applied. A bed
        /// firing at 23:55 on Friday is Saturday's alarm.
        let weekday: Locale.Weekday

        /// `oneoff:<routine>:20270118`. The key an override's own alarm is filed under.
        ///
        /// Deliberately shaped like a routine id, because that is what it is used as: while the
        /// override is still ahead the key counts as a living routine, so the alarm is protected
        /// from the sweep that clears alarms whose routine is gone. The morning the override passes,
        /// the key stops being generated, the sweep finds the alarm orphaned, and deletes it because
        /// OneAlarm is recorded as having created it. Expiry needed no new machinery.
        func linkKey(routine: String) -> String { "oneoff:\(routine):\(date.sortKey)" }
    }

    /// One routine, already offset for this device.
    struct Entry: Equatable, Sendable, Identifiable {
        let routineID: String
        /// Derived from the days, never stored. Only ever used in a sentence for the user.
        let routineName: String
        let weekdays: Set<Locale.Weekday>
        /// The routine's own time, with this device's lead applied.
        let localTime: WallClockTime
        /// A time to hold instead, for as long as a one day bend is armed. `nil` normally.
        let bentTo: WallClockTime?
        /// The routine's own switch.
        ///
        /// Carried rather than filtered out, because a switched off routine still has an alarm on
        /// his bed and that alarm has to be switched off too. Dropping it from the plan would leave
        /// it firing on a morning he turned off in OneAlarm, which is the opposite of a single
        /// source of truth.
        let isOn: Bool
        /// The next morning this routine covers is skipped.
        ///
        /// Only ever true for the one routine the skip falls on, and only until that morning has
        /// passed. It suppresses the alarm for one night and is put back by the next sync.
        let isSkippedNextMorning: Bool

        /// The date the bend falls on, and the weekday it lands on for **this** device.
        ///
        /// `bentTo` alone cannot drive a correct one day override anywhere. It says what time to use
        /// and not which morning, so the only thing a service leg could do with it was rewrite the
        /// routine's own alarm, which moves every morning that routine covers. Alex, 18 August:
        /// *"instead of changing it for one time, it changes the entire Monday to Friday routine on
        /// Eight Sleep."*
        ///
        /// A `var` with a default rather than a `let`, so the twenty-seven places that build an
        /// `Entry` without a bend keep working. Both fields are set together or neither is.
        var overrideDay: OverrideDay? = nil

        var id: String { routineID }
        var timeToWrite: WallClockTime { bentTo ?? localTime }
        var isBent: Bool { bentTo != nil }

        /// This routine with any one day override taken off it.
        ///
        /// For a leg that expresses an override as its own alarm rather than by moving this one. The
        /// routine's alarm then gets the routine's real time, which is what it should have had all
        /// along on every morning except the one.
        func withoutBend() -> Entry {
            Entry(
                routineID: routineID,
                routineName: routineName,
                weekdays: weekdays,
                localTime: localTime,
                bentTo: nil,
                isOn: isOn,
                isSkippedNextMorning: isSkippedNextMorning,
                overrideDay: nil
            )
        }

        /// Whether the remote alarm this routine owns should be able to fire.
        var shouldBeEnabled: Bool { isOn && !isSkippedNextMorning && !weekdays.isEmpty }
    }

    let device: DeviceID
    let entries: [Entry]
    /// True when the next morning is skipped.
    ///
    /// Deliberately **not** propagated. Eight Sleep has a `skipNext` field on every alarm object and
    /// this app has never written it, so its behaviour is known from its name and nothing else, and
    /// this project has already paid five hours for reasoning about a field name. It is stated on
    /// screen instead, and it is filed as an experiment.
    let skipsNextMorning: Bool

    var isEmpty: Bool { entries.isEmpty }

    /// The entry covering a given weekday, if any.
    func entry(covering weekday: Locale.Weekday) -> Entry? {
        entries.first { $0.weekdays.contains(weekday) }
    }
}

/// The result of pairing routines against the alarms an account already holds.
///
/// Everything that did not pair is named. Silence is what let three alarms read as two, and what let
/// a wrong alarm be moved with no symptom until somebody did not wake up.
struct AlarmMatchReport: Equatable, Sendable {
    struct Pair: Equatable, Sendable {
        let routineID: String
        let routineName: String
        let alarmID: String
        let time: WallClockTime
        /// The days this alarm should carry, which are the routine's days.
        ///
        /// Written, not merely compared, once the alarm is owned. Before ownership was recorded
        /// there was no safe way to write days at all: see `RemoteAlarmLink`.
        let weekdays: Set<Locale.Weekday>
        /// Whether it should be able to fire, from the routine's switch and any skip.
        let shouldBeEnabled: Bool
        /// This alarm was found by its days rather than by a recorded link, and is being adopted.
        /// The caller records the link so the next change does not depend on the days still lining
        /// up.
        let isAdoption: Bool
    }

    var pairs: [Pair] = []
    /// Routines whose day set matches no alarm on the account. Nothing is written for these.
    var routinesWithNoAlarm: [String] = []
    /// Alarms whose day set matches no routine. Left exactly as they are.
    var alarmsWithNoRoutine: [String] = []

    var isComplete: Bool { routinesWithNoAlarm.isEmpty }

    /// One sentence for a receipt, naming everything that did not line up.
    var note: String {
        var parts: [String] = []
        if pairs.isEmpty {
            parts.append("Nothing matched.")
        } else {
            let moved = pairs.map { "\($0.routineName) to \($0.time.hhmm)" }.joined(separator: ", ")
            parts.append("Set \(moved).")
        }
        if !routinesWithNoAlarm.isEmpty {
            parts.append("No alarm on your bed covers \(routinesWithNoAlarm.joined(separator: " or ")).")
        }
        if !alarmsWithNoRoutine.isEmpty {
            parts.append("Left alone: \(alarmsWithNoRoutine.joined(separator: ", ")).")
        }
        let off = pairs.filter { !$0.shouldBeEnabled }.map(\.routineName)
        if !off.isEmpty {
            parts.append("\(off.joined(separator: " and ")) is switched off, so it will not fire.")
        }
        return parts.joined(separator: " ")
    }
}

extension RoutinePlan {
    /// One alarm on the account, reduced to the four things matching needs.
    ///
    /// A named type rather than a tuple, so the three call sites cannot disagree about the order of
    /// two `String`s and two other fields. Swapping `id` and `label` in a tuple compiles.
    struct CandidateAlarm: Equatable, Sendable {
        let id: String
        let weekdays: Set<Locale.Weekday>
        let isEnabled: Bool
        /// "07:00 weekdays". For naming an alarm on screen, never for matching.
        let label: String
    }

    /// Pair each routine with the alarm it owns.
    ///
    /// Three ways a routine finds its alarm, in strict order:
    ///
    /// 1. **A recorded link.** Once OneAlarm has established that an alarm belongs to a routine, the
    ///    link is what identifies it, forever, whatever its days say. This is the one that makes the
    ///    single source of truth possible: changing a routine's days changes the owned alarm's days,
    ///    instead of losing track of it.
    /// 2. **Exact day set equality**, for an alarm nobody owns yet. Never a subset and never an
    ///    overlap: adopting a Monday to Wednesday alarm for a Monday to Friday routine would take
    ///    over an alarm covering days the routine does not describe. The adoption is reported so the
    ///    caller can record the link.
    /// 3. **Nothing**, and the routine is named. The caller creates an alarm for it.
    ///
    /// An alarm that is neither linked nor adopted is never touched. His own alarms stay his, and
    /// that is the line between OneAlarm owning the schedule and OneAlarm owning his account.
    static func match(
        entries: [Entry],
        against alarms: [CandidateAlarm],
        links: [String: String] = [:]
    ) -> AlarmMatchReport {
        var report = AlarmMatchReport()
        var claimed = Set<String>()

        func pair(_ entry: Entry, _ alarm: CandidateAlarm, adopted: Bool) {
            claimed.insert(alarm.id)
            report.pairs.append(
                AlarmMatchReport.Pair(
                    routineID: entry.routineID,
                    routineName: entry.routineName,
                    alarmID: alarm.id,
                    time: entry.timeToWrite,
                    weekdays: entry.weekdays,
                    shouldBeEnabled: entry.shouldBeEnabled,
                    isAdoption: adopted
                )
            )
        }

        // Recorded owners first, and in their own pass. Doing it in one pass would let a routine
        // with no link adopt an alarm that a later routine already owns.
        var linked: [String: CandidateAlarm] = [:]
        for entry in entries {
            guard let id = links[entry.routineID],
                  let alarm = alarms.first(where: { $0.id == id }) else { continue }
            linked[entry.routineID] = alarm
            claimed.insert(alarm.id)
        }

        // Every alarm OneAlarm owns is claimed, including one whose routine has since been deleted.
        //
        // Without this, an alarm left behind by a deleted routine is reported as "left alone" and
        // then, four lines later in the same sentence, as switched off. Both cannot be true. It is
        // also not adoptable by another routine that happens to share its days: it is on its way to
        // being switched off, and a routine taking it over on the way would be two decisions
        // fighting over one alarm.
        for owned in links.values { claimed.insert(owned) }

        for entry in entries {
            if let alarm = linked[entry.routineID] {
                pair(entry, alarm, adopted: false)
                continue
            }
            // A routine with no days owns nothing and adopts nothing. It is not a gap either: he
            // took every day off it, which is a setting.
            guard !entry.weekdays.isEmpty else { continue }

            if let hit = alarms.first(where: { $0.weekdays == entry.weekdays && !claimed.contains($0.id) }) {
                pair(entry, hit, adopted: true)
            } else {
                report.routinesWithNoAlarm.append(entry.routineName)
            }
        }

        // An alarm with no days can never fire and is not a routine anybody is missing. Naming it
        // here would put "no days set" in front of the user on every sync as if it were a problem.
        report.alarmsWithNoRoutine = alarms
            .filter { !claimed.contains($0.id) && !$0.weekdays.isEmpty }
            .map(\.label)

        return report
    }

    /// Pair each remote alarm with the routine that **covers** its days, rather than one whose day
    /// set is identical.
    ///
    /// **For Whoop, and specifically for the seven single day layout.** Alex established from his own
    /// app on 20 August that a Whoop account holds a **partition of the week**: every day belongs to
    /// exactly one schedule, no overlaps, and splitting is allowed. So an account can carry seven one
    /// day schedules, and that is the only structure on which a one time change can reach the strap,
    /// because moving one schedule then moves exactly one morning.
    ///
    /// Exact day set equality cannot pair that layout with his two routines: no single day schedule
    /// equals Monday to Friday. Coverage can. A `MONDAY` schedule is driven by whichever routine runs
    /// on Monday.
    ///
    /// **Backwards compatible by construction.** With his current two schedules, Monday to Friday is
    /// covered by the Weekdays routine and nothing else, so this returns exactly what equality
    /// returned. Equality is the special case where a schedule's days happen to be all of a routine's.
    ///
    /// **Ambiguity is refused rather than guessed.** A schedule spanning Friday and Saturday, with
    /// Friday on one routine and Saturday on another, has no single owner. Writing one time to it
    /// would move a morning belonging to a routine that did not ask, which is the founding bug of
    /// this leg. It is reported unmatched, which is the honest answer and the one that leaves him
    /// able to fix it by splitting.
    static func matchByCoverage(
        entries: [Entry],
        against alarms: [CandidateAlarm],
        links: [String: String] = [:]
    ) -> AlarmMatchReport {
        var report = AlarmMatchReport()
        var claimed = Set<String>()

        // The recorded link wins, exactly as in `match`. Ownership is a fact we wrote down, and
        // re-deriving it from days is what let a changed routine strand its alarm.
        var linked: [String: CandidateAlarm] = [:]
        for entry in entries {
            guard let id = links[entry.routineID],
                  let alarm = alarms.first(where: { $0.id == id }) else { continue }
            linked[entry.routineID] = alarm
            claimed.insert(alarm.id)
        }
        for owned in links.values { claimed.insert(owned) }

        for entry in entries {
            if let alarm = linked[entry.routineID] {
                report.pairs.append(pairing(entry, alarm, adopted: false))
                continue
            }
            guard !entry.weekdays.isEmpty else { continue }

            // Every day this alarm covers must belong to this routine, and to no other.
            let hit = alarms.first { alarm in
                !alarm.weekdays.isEmpty
                    && !claimed.contains(alarm.id)
                    && alarm.weekdays.isSubset(of: entry.weekdays)
                    && entries.allSatisfy { other in
                        other.routineID == entry.routineID
                            || !other.isOn
                            || alarm.weekdays.isDisjoint(with: other.weekdays)
                    }
            }
            if let hit {
                claimed.insert(hit.id)
                report.pairs.append(pairing(entry, hit, adopted: true))
            } else {
                report.routinesWithNoAlarm.append(entry.routineName)
            }
        }

        report.alarmsWithNoRoutine = alarms
            .filter { !claimed.contains($0.id) && !$0.weekdays.isEmpty }
            .map(\.label)

        return report
    }

    /// One pairing, built the same way for both matchers so the two cannot drift apart.
    private static func pairing(_ entry: Entry, _ alarm: CandidateAlarm, adopted: Bool) -> AlarmMatchReport.Pair {
        AlarmMatchReport.Pair(
            routineID: entry.routineID,
            routineName: entry.routineName,
            alarmID: alarm.id,
            time: entry.timeToWrite,
            weekdays: entry.weekdays,
            shouldBeEnabled: entry.shouldBeEnabled,
            isAdoption: adopted
        )
    }
}