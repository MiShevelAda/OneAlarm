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

    /// The gap between the first device to fire and the master time, for the summary line.
    static func leadMinutes(for targets: [ResolvedTarget], masterDevice: DeviceID = .iphone) -> Int? {
        guard
            let master = targets.first(where: { $0.device == masterDevice }),
            let earliest = targets.min(by: { $0.nextOccurrence < $1.nextOccurrence })
        else { return nil }
        return Int(master.nextOccurrence.timeIntervalSince(earliest.nextOccurrence) / 60)
    }
}
