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

        // A bend or a skip keeps the old single-alarm behaviour, deliberately.
        //
        // AlarmKit offers `.never` and `.weekly` and nothing in between, so "this Saturday and not
        // every Saturday" cannot be expressed. The existing answer is to arm the one weekday the
        // bend falls on, which the rules engine has already reduced `target` to. Splitting a bent
        // routine into "its other days at the routine time, plus this day at the bent time" is
        // expressible as two weekly alarms and is the better answer, but it is a second change to
        // the leg that must ring, and one change at a time is the rule this project keeps relearning.
        //
        // A skip is the same shape: nothing is armed for that morning, and `target` already points
        // past it.
        // An empty plan takes the same path, and that matters more than it looks. `write(_ target:)`
        // with no plan is the protocol's own entry point, and before 17 August it armed the target.
        // Making it throw instead would turn "no plan supplied" into no alarm at all on the leg that
        // exists to always ring, which is a worse bug than the one being fixed.
        // Deliberately over-broad, and named so nobody has to rediscover why.
        //
        // `isBent` is true for a routine that has a bend **anywhere ahead**, not only one falling on
        // the next morning. So bending next Saturday from a Monday puts this whole leg back into
        // single alarm mode for the rest of the week, and the weekend routine's own alarm stands
        // down until the sync after the bend expires.
        //
        // That is not a regression: it is exactly what this leg did before 17 August, for every
        // morning rather than only these. Narrowing it needs the plan to carry whether the override
        // lands on the **next** morning specifically, which is a third structural change to the leg
        // that must ring, on a night that has already produced two compile errors, a create loop and
        // an untracked-alarm leak. One change at a time, and this one is written down instead.
        let bendArmed = plan.entries.contains(where: \.isBent) || plan.skipsNextMorning
        if bendArmed || plan.entries.isEmpty {
            if !target.weekdays.isEmpty {
                outcome.schedule = [
                    Scheduled(key: overrideKey, time: target.localTime, weekdays: target.weekdays)
                ]
            }
            outcome.cancel = held.filter { $0 != overrideKey }.sorted()
            return outcome
        }

        // The ordinary case, and the fix: one alarm per routine, so every morning the week covers
        // has something armed for it whether or not he syncs again before then.
        let wanted = plan.entries.filter { $0.shouldBeEnabled }
        outcome.schedule = wanted.map {
            Scheduled(key: $0.routineID, time: $0.timeToWrite, weekdays: $0.weekdays)
        }

        // Anything held that no live routine claims, including the bend key once the bend has
        // expired. Sorted so the order is deterministic and a test can assert it.
        let keep = Set(wanted.map(\.routineID))
        outcome.cancel = held.filter { !keep.contains($0) }.sorted()
        return outcome
    }
}
