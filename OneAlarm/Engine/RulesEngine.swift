import Foundation

/// Turns one master wake time plus per device offsets into one fully resolved target per device.
///
/// Pure and deterministic. No I/O, no clock of its own, no singletons. Everything it needs comes in
/// as a parameter, which is what makes the midnight and daylight saving edges testable rather than
/// something you find out about at 06:50 on a Sunday.
enum RulesEngine {

    /// Resolve every enabled rule against the master time.
    ///
    /// - Parameters:
    ///   - schedule: master time, master weekdays, and the per device rules.
    ///   - calendar: supply an explicit calendar with an explicit `timeZone` in tests.
    ///   - now: the reference instant `nextOccurrence` is computed forward from.
    /// - Returns: one target per enabled rule, ordered earliest first, so the UI shows the chain
    ///   in the order it actually fires.
    static func resolve(
        schedule: WakeSchedule,
        calendar: Calendar,
        now: Date
    ) -> [ResolvedTarget] {
        schedule.rules
            .filter(\.isEnabled)
            .compactMap { rule in
                resolve(rule: rule, in: schedule, calendar: calendar, now: now)
            }
            .sorted { $0.nextOccurrence < $1.nextOccurrence }
    }

    static func resolve(
        rule: DeviceRule,
        in schedule: WakeSchedule,
        calendar: Calendar,
        now: Date
    ) -> ResolvedTarget? {
        let baseDays = rule.weekdayOverride ?? schedule.weekdays
        guard !baseDays.isEmpty else { return nil }

        // Applying the offset can walk off either end of the day. Track by how many days so the
        // weekday set can follow: a master alarm on Monday 00:05 with a -10 offset is really a
        // Sunday 23:55 alarm, and sending it as Monday 23:55 warms the bed a night late.
        let shifted = schedule.masterTime.minutesSinceMidnight + rule.offsetMinutes
        let dayShift = Int(floor(Double(shifted) / 1440.0))
        let localTime = WallClockTime(minutesSinceMidnight: shifted)
        let weekdays = Set(baseDays.map { $0.shifted(by: dayShift) })

        guard let next = nextOccurrence(of: localTime, on: weekdays, calendar: calendar, after: now)
        else { return nil }

        return ResolvedTarget(
            device: rule.device,
            localTime: localTime,
            weekdays: weekdays,
            dayShift: dayShift,
            nextOccurrence: next,
            utcOffsetSeconds: calendar.timeZone.secondsFromGMT(for: next)
        )
    }

    /// The next instant at or after `date` whose local wall clock is `time` and whose weekday is in
    /// `weekdays`.
    ///
    /// Each candidate day is resolved separately and the earliest wins, rather than asking the
    /// calendar for one match across a weekday set, because matching hour, minute and weekday
    /// together behaves differently across daylight saving transitions depending on the policy.
    /// `.nextTime` is deliberate: on the spring forward morning a 02:30 alarm does not exist, and
    /// the correct answer is the next real instant rather than no alarm at all.
    static func nextOccurrence(
        of time: WallClockTime,
        on weekdays: Set<Locale.Weekday>,
        calendar: Calendar,
        after date: Date
    ) -> Date? {
        guard !weekdays.isEmpty else { return nil }

        return weekdays.compactMap { weekday -> Date? in
            var components = DateComponents()
            components.hour = time.hour
            components.minute = time.minute
            components.second = 0
            components.weekday = weekday.calendarIndex

            return calendar.nextDate(
                after: date,
                matching: components,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            )
        }
        .min()
    }

    /// Every routine, projected onto one device's clock.
    ///
    /// The other `resolve` answers "what is the next alarm for this device". This one answers "what
    /// does this device's whole week look like", which is the question a service holding one alarm
    /// per routine actually needs answered. Without it the only way to express two routines on one
    /// remote alarm is to rewrite that alarm's days every time the week turns over, which is the bug
    /// that rewrote a real Monday to Friday schedule into every day.
    ///
    /// The offset can walk a routine's alarm onto the previous or next day, exactly as it can for a
    /// single target, so the day set is shifted the same way. A weekday routine at 00:05 with a Pod
    /// lead of ten minutes is a Sunday to Thursday alarm at 23:55, and matching it against a
    /// Monday to Friday alarm on the service would be wrong.
    static func plan(
        for rule: DeviceRule,
        in schedule: WakeSchedule,
        calendar: Calendar,
        now: Date
    ) -> RoutinePlan {
        let today = CalendarDay(now, in: calendar)
        let override = schedule.override.flatMap { $0.day >= today ? $0 : nil }

        // Which routine an override displaces, bend or skip. Resolved by the day it falls on rather
        // than by a stored id, because the routine's days can change between arming one and applying
        // it.
        var overriddenRoutineID: String?
        if let override, let date = override.day.date(in: calendar) {
            let weekday = Locale.Weekday.from(calendarIndex: calendar.component(.weekday, from: date))
            overriddenRoutineID = schedule.routine(covering: weekday)?.id
        }
        // A bend is an override that names a time. A skip names none, and the two are handled
        // separately below because only one of them arms anything.
        let bentRoutineID: String? = override?.time == nil ? nil : overriddenRoutineID

        // Which weekday a skip falls on, so only the routine covering it is suppressed.
        let skippedWeekday: Locale.Weekday? = {
            guard override?.isSkip == true, let date = override?.day.date(in: calendar) else { return nil }
            return Locale.Weekday.from(calendarIndex: calendar.component(.weekday, from: date))
        }()

        // Switched off routines stay in the plan. Their alarm is still on his bed, and leaving it
        // out would leave it firing on a morning he turned off in OneAlarm.
        let entries = schedule.routines
            .map { routine -> RoutinePlan.Entry in
                let shifted = routine.time.minutesSinceMidnight + rule.offsetMinutes
                let dayShift = Int(floor(Double(shifted) / 1440.0))

                let days = Set(routine.weekdays.map { $0.shifted(by: dayShift) })

                // The one morning an override touches, for **this** device, whether it is a bend or
                // a skip.
                //
                // Set for both, which is why it is not called `bendDay`. A skip needs the day just as
                // much: without it a leg can only express "this routine is suppressed" and has to
                // stand the whole routine down, when what was asked for was one morning off. The
                // Eight Sleep leg reads it only when there is also a time, so a skip changes nothing
                // there.
                var bent: WallClockTime?
                var overrideDay: RoutinePlan.OverrideDay?
                if routine.id == bentRoutineID || (skippedWeekday != nil && routine.id == overriddenRoutineID),
                   let override, let date = override.day.date(in: calendar) {
                    let chosen = Locale.Weekday.from(calendarIndex: calendar.component(.weekday, from: date))

                    // **A bend and a skip land on different days, and using one shift for both is a
                    // wrong alarm rather than a wrong label.**
                    //
                    // The user picks a calendar morning. Which weekday **this device** arms for it
                    // depends on which time is being armed, because the lead can walk either one
                    // across midnight:
                    //
                    // - a **skip** suppresses the routine's own alarm for that morning, which fires
                    //   at the routine's time, so it moves by the routine's shift.
                    // - a **bend** arms a different time entirely, so it moves by that time's shift.
                    //   A routine at 07:00 bent to 00:05, on a bed with a ten minute lead, is an
                    //   alarm at 23:55 the evening **before**. Its day is one back; the routine's is
                    //   not.
                    //
                    // Until 18 August both used the routine's shift, which was filed as a known
                    // defect worth only a wrong day set. It stopped being cosmetic the moment this
                    // day started deciding which single morning gets a real alarm created on his bed
                    // and which morning is taken off the phone's weekly alarm. A defect's severity is
                    // a property of what reads it, not of the defect.
                    if let bentTime = override.time {
                        let bentShifted = bentTime.minutesSinceMidnight + rule.offsetMinutes
                        bent = WallClockTime(minutesSinceMidnight: bentShifted)
                        let bendShift = Int(floor(Double(bentShifted) / 1440.0))
                        overrideDay = RoutinePlan.OverrideDay(
                            date: override.day, weekday: chosen.shifted(by: bendShift)
                        )
                    } else {
                        overrideDay = RoutinePlan.OverrideDay(
                            date: override.day, weekday: chosen.shifted(by: dayShift)
                        )
                    }
                }
                return RoutinePlan.Entry(
                    routineID: routine.id,
                    routineName: routine.displayName,
                    weekdays: days,
                    localTime: WallClockTime(minutesSinceMidnight: shifted),
                    bentTo: bent,
                    isOn: routine.isOn,
                    // The lead can walk this device's alarm onto the day before, so the skip is
                    // tested against the shifted day set rather than the routine's own. A bed
                    // firing at 23:55 on Friday is Saturday's alarm, and skipping Saturday has to
                    // suppress it.
                    isSkippedNextMorning: skippedWeekday.map {
                        days.contains($0.shifted(by: dayShift))
                    } ?? false,
                    overrideDay: overrideDay
                )
            }

        return RoutinePlan(
            device: rule.device,
            entries: entries,
            skipsNextMorning: override?.isSkip == true
        )
    }

    /// The gap between the first device to fire and the master time, for the summary line.
    static func leadMinutes(for targets: [ResolvedTarget], masterDevice: DeviceID = .iphone) -> Int? {
        guard
            let master = targets.first(where: { $0.device == masterDevice }),
            let earliest = targets.min(by: { $0.nextOccurrence < $1.nextOccurrence })
        else { return nil }
        return Int(master.nextOccurrence.timeIntervalSince(earliest.nextOccurrence) / 60)
    }
}
