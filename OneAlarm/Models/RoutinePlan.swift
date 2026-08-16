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
/// This type removes the destructive operation rather than guarding it. Days stop being something
/// OneAlarm writes: they become the key it matches on. A routine finds the alarm that already has
/// its days and changes that alarm's time, and nothing else.
struct RoutinePlan: Equatable, Sendable {
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

        var id: String { routineID }
        var timeToWrite: WallClockTime { bentTo ?? localTime }
        var isBent: Bool { bentTo != nil }
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
        /// The alarm's switch is off on the service. Its time is still updated, so that turning it
        /// back on gives the right time rather than an old one, but it will not fire.
        let isDisabledRemotely: Bool
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
        let off = pairs.filter(\.isDisabledRemotely).map(\.routineName)
        if !off.isEmpty {
            parts.append("\(off.joined(separator: " and ")) is switched off in Eight Sleep, so it will not fire.")
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

    /// Pair each routine with the alarms whose days are **exactly** its days.
    ///
    /// Exact set equality, never a subset and never an overlap. A Monday to Friday routine landing on
    /// a Monday to Wednesday alarm would move an alarm covering days the routine does not describe,
    /// and the only way to make that correct is to rewrite the alarm's days, which is the operation
    /// this whole design exists to delete. When the sets differ, say so and write nothing.
    ///
    /// Several alarms with the same day set are all moved, and counted in the report. On this API the
    /// alarm list is scoped to one account, so they are all his; leaving one behind is how two Monday
    /// alarms end up at two different times.
    static func match(entries: [Entry], against alarms: [CandidateAlarm]) -> AlarmMatchReport {
        var report = AlarmMatchReport()
        var claimed = Set<String>()

        for entry in entries where !entry.weekdays.isEmpty {
            let hits = alarms.filter { $0.weekdays == entry.weekdays }
            guard !hits.isEmpty else {
                report.routinesWithNoAlarm.append(entry.routineName)
                continue
            }
            for hit in hits {
                claimed.insert(hit.id)
                report.pairs.append(
                    AlarmMatchReport.Pair(
                        routineID: entry.routineID,
                        routineName: entry.routineName,
                        alarmID: hit.id,
                        time: entry.timeToWrite,
                        isDisabledRemotely: !hit.isEnabled
                    )
                )
            }
        }

        // An alarm with no days can never fire and is not a routine anybody is missing. Naming it
        // here would put "no days set" in front of the user on every sync as if it were a problem.
        report.alarmsWithNoRoutine = alarms
            .filter { !claimed.contains($0.id) && !$0.weekdays.isEmpty }
            .map(\.label)

        return report
    }
}
