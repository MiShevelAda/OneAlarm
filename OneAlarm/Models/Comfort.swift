import Foundation

/// Temperature, vibration and smart wake, as OneAlarm is now allowed to set them.
///
/// **This reverses a rule Alex set himself**, and the reversal is his: *"only the modifications of
/// temperature, vibration etc should be done in the respective app"*, 16 August, replaced on 20
/// August by *"for eight sleep please add following options when editing the routine"*, with a
/// screenshot of the Eight Sleep alarm screen showing Temperature, Vibration and Smart alarm.
///
/// The old rule is kept in view rather than deleted, because the reason behind it has not gone away
/// and still shapes how this works. It existed because the reference documentation for this API
/// **contradicts itself about these exact field names**, thirty lines apart: `vibration.powerLevel`
/// against `vibration.level`, `thermal.level` against `thermal.temperature`, `"RISE"` against
/// `"rise"`. A guess there does not fail loudly, it warms his bed to the wrong temperature.
///
/// **So nothing here is ever composed.** Every value is written into a key the server itself just
/// sent, and a key the server did not send is never introduced. That sidesteps the contradiction
/// completely: whichever spelling his account actually uses is the one that gets written, because it
/// is the one that came back. The same principle that makes `clone` safe for creating alarms.
///
/// Every field is optional and `nil` means **leave it exactly as it was**, so a routine that has
/// never been edited writes precisely what it wrote yesterday.
struct Comfort: Codable, Equatable, Sendable {
    var vibrationEnabled: Bool?
    /// Eight Sleep's app calls this Off / Low / Medium / High. On the wire it is a number.
    var vibrationPower: Int?
    /// `RISE` and `INTENSE` are the two his account has returned. Written back in the casing the
    /// server used, never normalised, because the docs disagree with themselves about that too.
    var vibrationPattern: String?
    var thermalEnabled: Bool?
    var thermalLevel: Int?
    /// Their app's "Smart alarm", which is `smart.lightSleepEnabled` on the wire.
    var smartEnabled: Bool?

    /// Nothing set, so nothing changes. The default for every routine.
    static let unchanged = Comfort()

    var isUnchanged: Bool { self == .unchanged }

    /// Apply to an alarm object from the server, touching only keys it already contains.
    ///
    /// **The guard is `existing[key] != nil`, and it is the whole safety argument.** Setting a key
    /// the server did not send would be composing a field name, which is the thing that made this
    /// area dangerous enough to ban in the first place. If his account spells it `level` and this
    /// wrote `powerLevel`, the write would succeed, the app would show a changed value, and his bed
    /// would ignore it.
    ///
    /// A missing sub-block is left missing rather than created, for the same reason.
    static func apply(_ comfort: Comfort, to alarm: [String: Any]) -> [String: Any] {
        var payload = alarm

        payload = update(payload, block: "vibration", bools: [
            "enabled": comfort.vibrationEnabled,
        ], ints: [
            "powerLevel": comfort.vibrationPower,
            "level": comfort.vibrationPower,
        ], strings: [
            "pattern": comfort.vibrationPattern,
        ])
        payload = update(payload, block: "thermal", bools: [
            "enabled": comfort.thermalEnabled,
        ], ints: [
            "level": comfort.thermalLevel,
            "temperature": comfort.thermalLevel,
        ])
        payload = update(payload, block: "smart", bools: [
            "lightSleepEnabled": comfort.smartEnabled,
        ])

        return payload
    }

    /// One sub-block, changed in place.
    ///
    /// **Three typed dictionaries rather than one `[String: Any?]`, and that is not fussiness.**
    /// The first version of this took `[String: Any?]` and skipped nils with `guard let value`. It
    /// does not work, and it shipped:
    ///
    /// ```swift
    /// let power: Int? = nil
    /// let changes: [String: Any?] = ["powerLevel": power]
    /// for (key, value) in changes {
    ///     guard let value else { continue }   // DOES NOT SKIP
    /// }
    /// ```
    ///
    /// Putting an `Int?` into an `Any?` dictionary **double wraps** it, into
    /// `Optional<Any>.some(Optional<Int>.none as Any)`, so `guard let` peels only the outer layer
    /// and succeeds. Every field he had left on `Leave` was then written back as a boxed nil.
    ///
    /// Alex found it within the hour: *"now it sets the eight sleep alarm always to heavy."* A
    /// setting he never touched was being overwritten on every sync, which is precisely the failure
    /// the whole three-way `Leave` design exists to prevent, reintroduced one layer below it.
    ///
    /// With concrete types there is one level of optionality and `guard let` means what it says.
    ///
    /// Both spellings of a value are still offered and only the one his account carries is written,
    /// so the account settles which of the contradictory docs is right.
    private static func update(
        _ payload: [String: Any],
        block name: String,
        bools: [String: Bool?],
        // Defaulted, so a block with no numeric or string field omits them rather than writing an
        // empty literal. `CLAUDE.md` has a documented grep for `: [:]` that finds real bugs, and
        // three false hits would have made it noise.
        ints: [String: Int?] = [:],
        strings: [String: String?] = [:]
    ) -> [String: Any] {
        guard var block = payload[name] as? [String: Any] else { return payload }
        for (key, value) in bools where block[key] != nil {
            if let value { block[key] = value }
        }
        // **At most one spelling, even if the account carries both.**
        //
        // `powerLevel` and `level` both map to `vibrationPower`, and `level` and `temperature` both
        // map to `thermalLevel`, so that whichever name his account uses is the one written and
        // neither contradictory doc has to be right. That argument only holds while exactly one of a
        // pair is present. If both were, the same integer would go into two fields on two different
        // scales: his account returns `powerLevel: 100`, a percentage, and the other shape returns
        // `temperature: -10`, a signed offset. Writing 40 to both would be the "wrong temperature"
        // failure this design exists to prevent.
        //
        // So the first present key in the given order wins and the rest are skipped. Sorted for a
        // stable order, because dictionary iteration is not.
        var written = false
        for key in ints.keys.sorted() where !written {
            guard block[key] != nil, let value = ints[key] ?? nil else { continue }
            block[key] = value
            written = true
        }
        for (key, value) in strings where block[key] != nil {
            if let value { block[key] = value }
        }
        var out = payload
        out[name] = block
        return out
    }

    /// What this will change, in his words. Read by the write preview gate.
    ///
    /// Empty when nothing is set, so a routine he has never edited says nothing rather than a
    /// reassuring sentence about defaults he did not choose. A neutral review on 20 August found
    /// this and `isUnchanged` declared and never called, which is the shape of a promise a screen
    /// was going to make and did not. Both are now used by `EightSleepAdapter.preview`.
    var summary: [String] {
        var lines: [String] = []
        if let vibrationEnabled {
            lines.append(vibrationEnabled ? "vibration on" : "vibration off")
        }
        if let vibrationPower { lines.append("vibration strength \(vibrationPower)") }
        if let vibrationPattern { lines.append("vibration pattern \(vibrationPattern)") }
        if let thermalEnabled {
            lines.append(thermalEnabled ? "temperature wake on" : "temperature wake off")
        }
        if let thermalLevel { lines.append("temperature level \(thermalLevel)") }
        if let smartEnabled {
            lines.append(smartEnabled ? "smart alarm on" : "smart alarm off")
        }
        return lines
    }
}
