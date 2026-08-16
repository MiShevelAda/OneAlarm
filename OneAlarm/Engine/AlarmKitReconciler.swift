import Foundation

/// Which alarms the phone should be holding, and which of the ones it holds should go.
///
/// **Why this is a separate, pure type.** `AlarmManager.shared` is an Apple singleton with no seam,
/// so the AlarmKit leg cannot be exercised against a fake the way the Eight Sleep leg now is. The
/// answer is not to give up on testing it, it is to make the part that decides anything pure and
/// leave the adapter as a shell that schedules what it is told. The framework calls stay unverified,
/// because they always were; the reasoning about which morning is armed does not.
///
/// **The bug this exists to fix.** Until 17 August the phone held exactly one alarm, built from the
/// single resolved target, whose days were those of the routine covering the **next** morning. With
/// a weekday routine and a weekend one, a Friday night sync armed Saturday and Sunday and left
/// Monday with no phone alarm at all. A silent missed morning, on the leg that exists precisely
/// because it needs no account, no network and no server. AlarmKit holds several alarms happily;
/// this app only ever handed it one.
enum AlarmKitReconciler {

    /// One alarm the phone should hold.
    struct Scheduled: Equatable {
        /// What it is for. `overrideKey` when it is a one morning bend rather than a routine.
        let key: String
        let time: WallClockTime
        let weekdays: Set<Locale.Weekday>
    }

    struct Outcome: Equatable {
        /// Alarms to schedule, one per routine, or one for a bend.
        var schedule: [Scheduled] = []
        /// Keys the phone currently holds an alarm for and should not.
        var cancel: [String] = []
    }

    /// The key a bend is filed under, so it cannot collide with a routine id.
    ///
    /// Routine ids are `routine-<uuid>`, so a fixed word cannot clash with one.
    static let overrideKey = "one-morning-bend"

    /// - Parameters:
    ///   - plan: the whole week for this device, already offset by its lead.
    ///   - target: the next alarm as the rules engine resolved it, used only for a bend.
    ///   - held: keys the phone currently has an alarm scheduled for.
    static func reconcile(
        plan: RoutinePlan,
        target: ResolvedTarget,
        held: Set<String>
    ) -> Outcome {
        var outcome = Outcome()

        // **An empty plan keeps the old single-alarm behaviour, and only an empty plan.**
        //
        // `write(_ target:)` with no plan is the protocol's own entry point, and before 17 August it
        // armed the target. Making it throw would turn "no plan supplied" into no alarm at all on the
        // leg that exists to always ring, which is a worse bug than the one being fixed.
        if plan.entries.isEmpty {
            if !target.weekdays.isEmpty {
                outcome.schedule = [
                    Scheduled(key: overrideKey, time: target.localTime, weekdays: target.weekdays)
                ]
            }
            outcome.cancel = held.filter { $0 != overrideKey }.sorted()
            return outcome
        }

        // **A bend used to collapse this whole leg to one alarm. It does not any more.**
        //
        // The old behaviour armed a single alarm for the one morning the override falls on and stood
        // every routine down until the next sync. `isBent` is true for an override **anywhere ahead**,
        // so bending next Saturday from a Monday left Monday to Friday with no phone alarm at all.
        // That was written down at the time as "not a regression, it is what this leg did before 17
        // August", which was true and is not a defence: it is a silent missed morning on the leg that
        // exists precisely because it needs no account, no network and no server.
        //
        // The comment there said what was missing: the plan had to carry **which** morning the
        // override lands on. It does now, as `Entry.overrideDay`, added for the Eight Sleep one-off.
        // So the answer that comment called better is now the answer:
        //
        //   the routine, on its other days, at its own time
        //   plus that one day, at the override's time
        //
        // Two weekly alarms, which AlarmKit expresses fine. A skip is the same shape with the second
        // half left off.
        var wanted: [Scheduled] = []
        var overrideSlot: Scheduled?

        for entry in plan.entries where entry.isOn && !entry.weekdays.isEmpty {
            // The morning this routine has an override on, if any. Only ever one.
            let displaced = entry.overrideDay.map { $0.weekday }

            // **Belt and braces.** A skip is expressed by removing its day below, which needs the day
            // to be known. If a skip ever arrives without one, this falls back to standing the whole
            // routine down for the night, which is the old behaviour: too much suppressed rather than
            // a morning he cleared going off anyway. Wrong in the safe direction, and it is the only
            // direction worth being wrong in here.
            if entry.isSkippedNextMorning && displaced == nil { continue }
            let ordinaryDays = displaced.map { entry.weekdays.subtracting([$0]) } ?? entry.weekdays

            // A routine reduced to nothing by its own override arms nothing. A one day routine with
            // a bend on that day is entirely expressed by the override alarm below.
            if !ordinaryDays.isEmpty {
                wanted.append(Scheduled(key: entry.routineID, time: entry.localTime, weekdays: ordinaryDays))
            }

            // The bent morning, at the bent time. A skip has no time and arms nothing, which is what
            // a skip is: the day is already missing from `ordinaryDays` above.
            if let day = displaced, let bentTo = entry.bentTo {
                overrideSlot = Scheduled(key: overrideKey, time: bentTo, weekdays: [day])
            }
        }

        outcome.schedule = wanted
        if let overrideSlot { outcome.schedule.append(overrideSlot) }

        // Anything held that nothing above claims, including the override key once the override has
        // expired. Sorted so the order is deterministic and a test can assert it.
        let keep = Set(outcome.schedule.map(\.key))
        outcome.cancel = held.filter { !keep.contains($0) }.sorted()
        return outcome
    }
}
