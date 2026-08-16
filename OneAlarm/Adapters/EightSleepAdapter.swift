import Foundation

/// The Eight Sleep leg.
///
/// Ported from the pyEight copy vendored inside the Home Assistant integration, which is what
/// people actually run, rather than the standalone repo of the same name. The standalone copy still
/// targets the retired Routines API and ships a discovery routine that creates up to ten real
/// alarms on a live account.
///
/// The central decision here is **read modify write**. The reference library's create payload and
/// its documented read shape disagree about field names, `vibration.powerLevel` against
/// `vibration.level` and `thermal.level` against `thermal.temperature`, thirty lines apart in the
/// same file. Rather than gamble on which is right, this adapter reads the existing alarm as a raw
/// dictionary, changes **only `time`**, and sends everything else back exactly as the server gave
/// it. Unknown fields survive untouched, so the contradiction cannot bite us and neither can any
/// field added upstream later.
///
/// It used to also write `enabled` and the whole `repeat` block. Both are gone as of 2026-08-16.
/// Days are now the key a routine is **matched on** rather than a field that gets written: OneAlarm
/// finds the alarm that already has a routine's days and moves that alarm's time. See `write`.
actor EightSleepAdapter: DeviceAdapter {

    nonisolated let device: DeviceID = .eightSleep

    private static let authHost = "https://auth-api.8slp.net"
    private static let appHost = "https://app-api.8slp.net"

    // Public values, extracted from the Android app and hardcoded in the reference library.
    private static let clientID = "0894c7f33bb94800a03f1f4df13a4f38"
    private static let clientSecret = "f0954a3ed5763ba3d06834c73731a32f15f168f47d4f164751275def86db0c76"

    private let keychain: KeychainStore
    /// Exactly three requests, verb included. Nothing else on this API is reachable from here.
    ///
    /// Note what is deliberately absent. `POST .../v1/users/{id}/alarms` creates an alarm, which is
    /// the call the reference library's discovery routine uses to put ten real alarms on a live
    /// account, and `DELETE .../v1/users/{id}/alarms/{alarmId}` is unverified and irreversible.
    /// Neither is listed, so neither can be sent, including by a later edit that forgets why.
    private let http = HTTPClient(allowedPatterns: [
        #"^POST https://auth-api\.8slp\.net/v1/tokens$"#,
        #"^GET https://app-api\.8slp\.net/v2/users/[^/]+/alarms$"#,
        #"^PUT https://app-api\.8slp\.net/v1/users/[^/]+/alarms/[^/]+$"#,
        // Create, added 2026-08-16 at Alex's explicit instruction: *"the OneAlarm app should also
        // write the new alarm sequence into the Eight Sleep app, and I shouldn't do it manually.
        // Your goal is to fix this, find a way, so it can create this type of routine and select
        // Monday to Friday on its own."*
        //
        // This was on the banned list, and the reason it was banned still stands: the reference
        // library's discovery routine uses exactly this call to put ten real alarms on a live
        // account. What makes it safe here is not care, it is `createAlarm`, which never composes a
        // payload. It clones an alarm the account already has, so no field is guessed, and it is
        // hard capped. Read the guards on that function before touching this line.
        #"^POST https://app-api\.8slp\.net/v1/users/[^/]+/alarms$"#,
        // Two reads, added to answer "which bed am I on". Neither can change anything.
        //
        // Note the third host. `client-api` is not `app-api`, and adding a host to an allowlist is
        // exactly the kind of edit that should be visible rather than incidental.
        #"^GET https://client-api\.8slp\.net/v1/users/me$"#,
        #"^GET https://app-api\.8slp\.net/v1/household/users/[^/]+/summary$"#,
    ])

    private(set) var authState: AuthState = .notConfigured

    private var accessToken: String?
    private var tokenExpiry: Date?
    private var userID: String?
    /// Set on a 429. No request goes out before it, so a throttle is respected rather than
    /// hammered. pyEight has no 429 handling at all, so this is ours rather than ported.
    private var retryNotBefore: Date?
    private var currentBackoff: TimeInterval = 0

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    // MARK: Auth

    func refreshAuthState() async {
        // A locked device must not read as a missing credential. `.unknownDeviceLocked` leaves the
        // state exactly as it was rather than telling the user to type a password they still have.
        switch keychain.presence(.eightSleepPassword) {
        case .absent:
            authState = .notConfigured
        case .unknownDeviceLocked:
            break
        case .present:
            if case .needsReauth = authState {
                // Leave a known bad credential flagged until the user changes it.
            } else {
                authState = .connected
            }
        }
    }

    /// Authenticate first, persist second.
    ///
    /// The order matters more here than on the Whoop leg. Eight Sleep issues no refresh token, so
    /// this password is the only way back in, and saving before validating means one typo at the
    /// Connect button overwrites a working credential with a broken one and nothing can recover it.
    func signIn(email: String, password: String) async throws {
        accessToken = nil
        tokenExpiry = nil
        userID = nil
        retryNotBefore = nil
        authState = .notConfigured

        do {
            let result = try await requestToken(email: email, password: password)
            try keychain.save(email, for: .eightSleepEmail)
            try keychain.save(password, for: .eightSleepPassword)
            accessToken = result.token
            userID = result.userID
            tokenExpiry = result.expiry
            authState = .connected
        } catch {
            authState = .needsReauth((error as? AdapterError)?.errorDescription ?? "Sign in failed.")
            throw error
        }
    }

    /// Answers "is this leg actually going to work at 6am", at connect time rather than at 6am.
    ///
    /// Signing in only proves the password is right. It does not prove the subscription is active,
    /// and it does not prove there is an alarm to move. Both of those fail later, in the dark, when
    /// nothing is watching. So they are checked here, while somebody is looking at the screen.
    /// - Parameter plan: the week as OneAlarm has it, so the answer can name which routines this
    ///   account can actually carry. Passing an empty plan asks the weaker question, "is there an
    ///   alarm at all", which is all that can be checked before any routine exists.
    func readiness(against plan: RoutinePlan? = nil) async throws -> String {
        let choices = try await availableAlarms()
        guard !choices.isEmpty else { throw AdapterError.noAlarmToUpdate }

        let bed = await currentBed()
        let place = bed?.label.map { "on \($0)" } ?? "on this account"

        guard let plan, !plan.entries.isEmpty else {
            let live = choices.filter(\.canFire).count
            return "Connected. \(live) alarm\(live == 1 ? "" : "s") \(place)."
        }

        let report = RoutinePlan.match(entries: plan.entries, against: choices.map(\.candidate))
        guard !report.pairs.isEmpty else {
            throw AdapterError.noMatchingDays(
                routines: report.routinesWithNoAlarm,
                alarms: choices.filter { !$0.weekdays.isEmpty }.map { "\($0.timeLabel) \($0.daysLabel)" }
            )
        }
        let matched = report.pairs.map(\.routineName).joined(separator: " and ")
        var line = "Connected \(place). \(matched) will follow OneAlarm."
        if !report.routinesWithNoAlarm.isEmpty {
            line += " No alarm here covers \(report.routinesWithNoAlarm.joined(separator: " or "))."
        }
        return line
    }

    /// Every alarm on the account, described well enough to pick from.
    ///
    /// The API is keyed on the user rather than the device, so this returns alarms across every Pod
    /// on the account. Whether it names the bed is answered by `groupName`, which searches rather
    /// than assumes, and by the diagnostic the picker prints on a successful parse.
    func availableAlarms() async throws -> [RemoteAlarmChoice] {
        try await fetchAlarms().compactMap { alarm in
            guard let id = Self.alarmID(alarm) else { return nil }
            let parts = (alarm["time"] as? String)?.split(separator: ":").compactMap { Int($0) } ?? []
            let time = parts.count >= 2 ? WallClockTime(hour: parts[0], minute: parts[1]) : nil

            return RemoteAlarmChoice(
                id: id,
                time: time,
                // The same reader the matcher uses. Two parsers for one field is how a screen and a
                // write end up disagreeing about which alarm is which.
                weekdays: Self.weekdays(of: alarm),
                isEnabled: (alarm["enabled"] as? Bool) ?? true,
                detail: Self.describeSettings(alarm),
                rawKeys: Self.describe(alarm),
                group: Self.groupName(alarm)
            )
        }
    }

    /// Which bed this account is currently on, and what it is called.
    ///
    /// The answer to a question that was being asked the wrong way round. Alarms on this API are
    /// **user scoped**: one list per account, firing on whichever Pod the account is currently
    /// assigned to. So an alarm does not belong to a bed and never did, and the `routine-` tag it
    /// carries points at a bedtime pairing rather than at a Pod.
    ///
    /// Which makes "which bed does this alarm control" unanswerable and beside the point, and
    /// "which bed am I on" both answerable and the thing he actually needs to know. Two reads:
    /// `users/me` gives the current device id and side, the household summary gives that device a
    /// name.
    ///
    /// Returns `nil` rather than throwing. This is a label, and a label that cannot be fetched must
    /// not take an alarm down with it.
    struct BedIdentity: Equatable, Sendable {
        var name: String?
        var side: String?
        var deviceCount: Int
        var timeZone: String?

        /// "Master Bedroom Pod, left side". Never invented: a missing half is simply not printed.
        var label: String? {
            let sideText = side.flatMap { raw -> String? in
                switch raw.lowercased() {
                case "left", "right": return "\(raw.lowercased()) side"
                case "solo": return "whole bed"
                case "away": return "away"
                default: return nil
                }
            }
            switch (name, sideText) {
            case let (name?, side?): return "\(name), \(side)"
            case let (name?, nil): return name
            case let (nil, side?): return side.prefix(1).uppercased() + side.dropFirst()
            default: return nil
            }
        }
    }

    func currentBed() async -> BedIdentity? {
        // A tuple, not a string. Both calls below need the user id as well as the bearer.
        guard let session = try? await currentToken() else { return nil }
        guard let meURL = URL(string: "https://client-api.8slp.net/v1/users/me"),
              let response = try? await http.send("GET", meURL, headers: Self.baseHeaders(token: session.token)),
              response.isSuccess,
              let envelope = try? HTTPClient.dictionary(response.data),
              let user = envelope["user"] as? [String: Any]
        else { return nil }

        let current = user["currentDevice"] as? [String: Any]
        let deviceID = current?["id"] as? String
        var identity = BedIdentity(
            name: nil,
            side: current?["side"] as? String,
            deviceCount: (user["devices"] as? [Any])?.count ?? 1,
            timeZone: current?["timeZone"] as? String
        )

        // The name lives in the household summary and nowhere else. `/devices/{id}` carries a model
        // string, a serial and a firmware version, and no name at all.
        let id = (user["userId"] as? String) ?? session.userID
        if let url = URL(string: "\(Self.appHost)/v1/household/users/\(id)/summary"),
           let summary = try? await http.send("GET", url, headers: Self.baseHeaders(token: session.token)),
           summary.isSuccess,
           let object = try? HTTPClient.dictionary(summary.data) {
            identity.name = Self.deviceName(deviceID, in: object)
        }
        return identity
    }

    /// Walk households, sets, devices, looking for the one we are on.
    ///
    /// Falls back to the set's name, which is what the Home Assistant integration does, because a
    /// household with one set usually names the set rather than the Pod.
    static func deviceName(_ deviceID: String?, in summary: [String: Any]) -> String? {
        guard let households = summary["households"] as? [[String: Any]] else { return nil }
        for household in households {
            for set in (household["sets"] as? [[String: Any]]) ?? [] {
                let setName = set["setName"] as? String
                for device in (set["devices"] as? [[String: Any]]) ?? [] {
                    guard deviceID == nil || (device["deviceId"] as? String) == deviceID else { continue }
                    if let name = device["deviceName"] as? String, !name.isEmpty { return name }
                    if let setName, !setName.isEmpty { return setName }
                }
            }
        }
        return nil
    }

    func signOut() {
        try? keychain.delete(.eightSleepEmail)
        try? keychain.delete(.eightSleepPassword)
        accessToken = nil
        tokenExpiry = nil
        userID = nil
        retryNotBefore = nil
        authState = .notConfigured
    }

    /// One password grant. No retry, no fallback, no second attempt on failure.
    private func requestToken(
        email: String,
        password: String
    ) async throws -> (token: String, userID: String, expiry: Date) {
        if let notBefore = retryNotBefore, Date() < notBefore {
            throw AdapterError.rateLimited
        }

        guard let url = URL(string: "\(Self.authHost)/v1/tokens") else {
            throw AdapterError.transport("Bad auth URL.")
        }

        // JSON, not form encoding. A standard OAuth2 client would send
        // application/x-www-form-urlencoded here and fail.
        let body = try HTTPClient.json([
            "client_id": Self.clientID,
            "client_secret": Self.clientSecret,
            "grant_type": "password",
            "username": email,
            "password": password,
        ])

        let response = try await http.send("POST", url, headers: Self.baseHeaders(), body: body)

        if response.status == 429 {
            backOff()
            throw AdapterError.rateLimited
        }
        guard response.isSuccess else {
            throw AdapterError.authenticationFailed("HTTP \(response.status)")
        }

        retryNotBefore = nil
        let json = try HTTPClient.dictionary(response.data)
        guard
            let token = json["access_token"] as? String,
            let user = json["userId"] as? String
        else {
            throw AdapterError.unexpectedResponse("Auth response was missing access_token or userId.")
        }

        // Read the lifetime off the response rather than assuming one. Guessing an hour when the
        // field is absent would re-POST the password hourly against an API with observed 429s.
        guard let lifetime = json["expires_in"] as? Double else {
            throw AdapterError.unexpectedResponse("Auth response carried no expires_in.")
        }
        return (token, user, Date().addingTimeInterval(lifetime))
    }

    /// Eight Sleep issues no refresh token, so "refresh" is a full re authentication with the
    /// stored password. That is why the password has to be retained at all, and it is forced by
    /// their API rather than chosen.
    private func currentToken() async throws -> (token: String, userID: String) {
        if
            let token = accessToken,
            let userID,
            let expiry = tokenExpiry,
            // Re-auth two minutes early rather than discovering expiry mid write.
            Date().addingTimeInterval(120) < expiry
        {
            return (token, userID)
        }

        // A credential the server has already rejected is never sent again on its own. Without this
        // every tap of Set all alarms is another password grant with a password known to be wrong,
        // which is how a personal account gets rate limited and then locked.
        if case .needsReauth = authState {
            throw AdapterError.notConfigured
        }

        guard
            let email = try? keychain.readString(.eightSleepEmail),
            let password = try? keychain.readString(.eightSleepPassword)
        else {
            throw AdapterError.notConfigured
        }

        do {
            let result = try await requestToken(email: email, password: password)
            accessToken = result.token
            userID = result.userID
            tokenExpiry = result.expiry
            return (result.token, result.userID)
        } catch AdapterError.authenticationFailed(let detail) {
            authState = .needsReauth("Eight Sleep rejected the saved password.")
            throw AdapterError.authenticationFailed(detail)
        }
    }

    private func backOff() {
        let next = min((currentBackoff == 0 ? 60 : currentBackoff * 2), 900)
        currentBackoff = next
        retryNotBefore = Date().addingTimeInterval(next)
    }

    private static func baseHeaders(token: String? = nil) -> [String: String] {
        var headers = [
            "content-type": "application/json",
            "accept": "application/json",
            "user-agent": "Home Assistant 1.0.18",
        ]
        if let token {
            headers["authorization"] = "Bearer \(token)"
        }
        return headers
    }

    // MARK: Alarms

    private func fetchAlarms() async throws -> [[String: Any]] {
        let (token, user) = try await currentToken()
        guard let url = URL(string: "\(Self.appHost)/v2/users/\(user)/alarms") else {
            throw AdapterError.transport("Bad alarms URL.")
        }

        let response = try await http.send("GET", url, headers: Self.baseHeaders(token: token))

        if response.status == 403 {
            // Authentication succeeded and this call is what failed, so `authState` stays
            // `.connected` on purpose. Marking it `needsReauth` would send him to re-enter a
            // password that is already correct, and land him back here on the next attempt.
            throw AdapterError.subscriptionRequired
        }
        if response.status == 429 {
            backOff()
            throw AdapterError.rateLimited
        }
        if response.status == 401 {
            accessToken = nil
            throw AdapterError.authenticationFailed("Token was rejected.")
        }
        guard response.isSuccess else {
            throw AdapterError.unexpectedResponse("HTTP \(response.status) reading alarms.")
        }

        let json = try HTTPClient.dictionary(response.data)
        return (json["alarms"] as? [[String: Any]]) ?? []
    }

    /// Server computed fields. Sending them back is rejected or ignored depending on the field, so
    /// they come off before every write.
    private static let computedFields = [
        "nextTimestamp", "startTimestamp", "endTimestamp", "dismissedUntil", "snoozedUntil",
    ]

    /// Change the time. Nothing else.
    ///
    /// This used to also write `enabled = true` and rebuild the whole `repeat.weekDays` block from
    /// the target. Both are gone, and both were doing real damage.
    ///
    /// **Days.** With one alarm chosen by hand, the app had no way to express two routines, so when
    /// the weekend routine came round it rewrote the weekday alarm's days to Saturday and Sunday.
    /// Alex, 2026-08-16: *"picking one routine can break the entire thing."* Days are now the key
    /// the routine is matched on rather than a field that gets written, so the alarm being moved
    /// already has the right days by definition and there is nothing to set.
    ///
    /// **`enabled`.** Forcing it on switched an alarm back on that he had switched off in the Eight
    /// Sleep app, which is authoring a decision rather than syncing a time. The time is still
    /// written to a switched-off alarm, so turning it back on gives today's time rather than an old
    /// one, and the receipt says out loud that it will not fire.
    ///
    /// Internal rather than private so the test suite can assert that unknown fields survive.
    static func mutate(_ alarm: [String: Any], to time: WallClockTime) -> [String: Any] {
        var payload = alarm
        for field in computedFields {
            payload.removeValue(forKey: field)
        }
        payload["time"] = time.hhmmss
        return payload
    }

    /// The most alarms OneAlarm will ever let an account hold.
    ///
    /// A runaway create loop is the specific way the reference library damages a live account: its
    /// discovery routine posts ten alarms and leaves them there. OneAlarm cannot delete, on purpose,
    /// so anything it creates by mistake is cleaned up by hand in the Eight Sleep app. That is the
    /// cost that sets this number, not tidiness.
    private static let alarmCeiling = 8

    /// Build a new alarm by cloning one the account already has.
    ///
    /// **Nothing here is composed.** The reference library's create payload and its documented read
    /// shape disagree about field names, `vibration.powerLevel` against `vibration.level` and
    /// `thermal.level` against `thermal.temperature`, thirty lines apart in the same file. Writing a
    /// create body from that would be guessing, and a wrong guess ships as a bed that heats to the
    /// wrong temperature at 6am.
    ///
    /// So the body is an alarm the server itself produced, with the identifiers stripped and exactly
    /// two fields changed: the time, and the days. Every other field, including the ones with no
    /// known meaning, comes back exactly as Eight Sleep wrote it. The same principle that makes the
    /// update safe makes the create safe, and for the same reason.
    ///
    /// `tags` is deliberately **kept**. It carries a `routine-<uuid>` pointing at a bedtime pairing
    /// in their app, and their app appears to render alarms through those. An alarm created without
    /// one may well be an alarm their app never shows, which is the exact failure being fixed here.
    /// Carrying the template's tag puts the new alarm in the same place as the alarm it was copied
    /// from. That is reasoning about a field, which this project has been burned by, so it is
    /// written down as `E14` with a prediction rather than asserted.
    static func clone(
        _ template: [String: Any],
        days: Set<Locale.Weekday>,
        time: WallClockTime
    ) -> [String: Any] {
        var payload = template
        for field in computedFields { payload.removeValue(forKey: field) }
        // The server issues these. Sending one back is either ignored or an overwrite of a different
        // alarm, and the second is the kind of mistake that has no symptom until a morning is missed.
        for identifier in ["id", "alarmId", "alarm_id"] { payload.removeValue(forKey: identifier) }

        payload["time"] = time.hhmmss
        payload["enabled"] = true

        // The one place in this adapter that still authors days. It is authoring them for an alarm
        // that does not exist yet, which is a different act from reshaping one that does.
        var weekDays: [String: Bool] = [:]
        for day in Locale.Weekday.displayOrder {
            weekDays[day.eightSleepKey] = days.contains(day)
        }
        var repeatBlock = (payload["repeat"] as? [String: Any]) ?? [:]
        repeatBlock["enabled"] = true
        repeatBlock["weekDays"] = weekDays
        payload["repeat"] = repeatBlock

        return payload
    }

    /// Which existing alarm to copy settings from.
    ///
    /// Prefers one that can actually fire. An inert alarm, no days and switched off, is the one
    /// Eight Sleep's own app hides, and copying its settings would clone whatever state made it
    /// inert. Falls back to any alarm, because a template from his account always beats a payload
    /// composed here.
    static func template(from alarms: [[String: Any]]) -> [String: Any]? {
        alarms.first { !weekdays(of: $0).isEmpty && ($0["enabled"] as? Bool) != false }
            ?? alarms.first { !weekdays(of: $0).isEmpty }
            ?? alarms.first
    }

    nonisolated func preview(_ target: ResolvedTarget) -> WritePreview {
        preview(target, plan: RoutinePlan(device: .eightSleep, entries: [], skipsNextMorning: false))
    }

    nonisolated func preview(_ target: ResolvedTarget, plan: RoutinePlan) -> WritePreview {
        let sketch: [String: Any] = ["time": target.localTime.hhmmss]

        let lines: String
        if plan.entries.isEmpty {
            lines = "one PUT, setting time to \(target.localTime.hhmm)"
        } else {
            lines = plan.entries
                .map { "\($0.routineName) (\($0.weekdays.count) days) to \($0.timeToWrite.hhmm)" }
                .joined(separator: ", ")
        }

        return WritePreview(
            device: .eightSleep,
            summary: "One PUT per routine, each carrying a single changed field, `time`. \(lines). Days, vibration, thermal and the on switch are echoed back exactly as the server gave them. A routine with no alarm on the bed gets one created, as a copy of an alarm you already have with its days and time changed, capped at \(Self.alarmCeiling) alarms on the account.",
            method: "PUT",
            url: "\(Self.appHost)/v1/users/{userId}/alarms/{alarmId}",
            body: HTTPClient.redactedPreview(sketch, showing: Self.previewKeys),
            reconstructed: true
        )
    }

    /// The alarm's identifier, whatever the account spells it.
    ///
    /// Was `alarm["id"] as? String` in one place and inline in another. Anything that failed that
    /// cast was dropped **silently**, and an empty list means the picker never opens, which is
    /// indistinguishable from having no alarms. A numeric id, or one under `alarmId`, would produce
    /// exactly the report "choosing a pod does not work".
    static func alarmID(_ alarm: [String: Any]) -> String? {
        for key in ["id", "alarmId", "alarm_id"] {
            if let text = alarm[key] as? String, !text.isEmpty { return text }
            if let number = alarm[key] as? NSNumber { return number.stringValue }
        }
        return nil
    }

    /// Which bed, pod or side this alarm belongs to.
    ///
    /// Searched rather than assumed. The reference write-up's alarm object carries no name, and an
    /// earlier comment in this project turned that absence into the claim that Eight Sleep does not
    /// label its alarms at all. The same reasoning about Whoop was wrong, because the object being
    /// read was not the object being described. So: look for every plausible spelling, take the
    /// first that yields a non-empty string, and when none does, say so on screen instead of
    /// quietly falling back to time and days.
    ///
    /// `side` is included because a Pod has two, and two people on one bed is precisely the case
    /// where two alarms are otherwise indistinguishable.
    static func groupName(_ alarm: [String: Any]) -> String? {
        let direct = ["name", "label", "deviceName", "podName", "bedName", "displayName", "title"]
        for key in direct {
            if let text = alarm[key] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text
            }
        }

        // A side on its own is a name a human recognises; a side plus a device is better.
        let side = (alarm["side"] as? String) ?? (alarm["bedSide"] as? String)
        for key in ["device", "pod", "bed"] {
            if let nested = alarm[key] as? [String: Any],
               let text = (nested["name"] as? String) ?? (nested["label"] as? String),
               !text.isEmpty {
                return side.map { "\(text), \($0) side" } ?? text
            }
        }
        if let side, !side.isEmpty { return "\(side.capitalized) side" }

        // An opaque identifier is not a name, but it does separate two pods, which is most of the
        // point. Shortened because a full uuid in a picker row is noise.
        for key in ["deviceId", "device_id", "podId"] {
            if let id = alarm[key] as? String, !id.isEmpty {
                return "Pod " + String(id.suffix(4))
            }
        }
        return nil
    }

    /// The per-alarm settings we deliberately never author, shown so the row says what it will keep.
    static func describeSettings(_ alarm: [String: Any]) -> String? {
        var parts: [String] = []
        if let vibration = alarm["vibration"] as? [String: Any],
           (vibration["enabled"] as? Bool) == true {
            let level = (vibration["level"] ?? vibration["powerLevel"]).map { "\($0)" }
            parts.append(level.map { "vibration \($0)" } ?? "vibration on")
        }
        if let thermal = alarm["thermal"] as? [String: Any],
           (thermal["enabled"] as? Bool) == true {
            parts.append("thermal on")
        }

        // The Eight Sleep app showed one of these alarms switched off while OneAlarm showed it on.
        // Rather than reason about which field their toggle reflects, print the ones that could
        // plausibly drive it. `enabled` is what this adapter reads; `skipNext` and `skippedUntil`
        // are the two nobody has interpreted, and one of them held a timestamp equal to that very
        // alarm's next occurrence.
        parts.append("enabled=\(Self.raw(alarm["enabled"]))")
        if let skip = alarm["skipNext"], !(skip is NSNull) { parts.append("skipNext=\(Self.raw(skip))") }
        if let until = alarm["skippedUntil"] as? String, !until.isEmpty,
           !until.hasPrefix("1970") {
            parts.append("skippedUntil=\(until)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// A value with its kind visible, so `true`, `1` and `"1"` are distinguishable on screen.
    static func raw(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "absent" }
        if let text = value as? String { return "\"\(text)\"" }
        return "\(value)"
    }

    /// Field names, plus the values of the few that decide which bed this is.
    ///
    /// Shown whether or not the parse succeeded. A diagnostic that only appears on failure cannot
    /// answer "does this account name its pods", because the parse succeeds either way.
    static func describe(_ alarm: [String: Any]) -> [String] {
        var lines = alarm.keys.sorted()
        // `time` and `nextTimestamp` lead, because they are the two that settle the question Alex
        // asked on 16 Aug: the write lands on this API, and his Eight Sleep app shows the old time.
        // Those are different claims and only one of them is ours. Printing what the server returns,
        // verbatim, is the difference between knowing that and arguing about it.
        //
        // `tags` and `smart` follow. Neither has a known shape, and `tags` holds a `routine-<uuid>`
        // pointing at something in their app nobody here has looked at, which makes it the best
        // remaining lead if the server object turns out to be right and their app still disagrees.
        for key in ["time", "nextTimestamp", "enabled", "name", "label", "side", "deviceId",
                    "device", "pod", "tags", "smart", "audio", "skipNext", "skippedUntil"] {
            if let value = alarm[key], !(value is NSNull) {
                lines.append("\(key) = \(value)")
            }
        }
        return lines
    }

    /// One key, because one key is now the entire diff. It used to have to name every weekday too,
    /// because the write rebuilt the whole `repeat` block; that write is gone.
    private static let previewKeys: Set<String> = ["time"]

    func write(_ target: ResolvedTarget) async throws -> WriteReceipt {
        // A plan with no entries. Every routine-aware caller goes through the overload; this exists
        // so the protocol stays satisfiable and so a single-target write still has one meaning.
        try await write(target, plan: RoutinePlan(device: .eightSleep, entries: [], skipsNextMorning: false))
    }

    /// Match every routine to the alarm that already has its days, and change that alarm's time.
    ///
    /// No alarm is chosen by hand any more, because there is nothing to choose: a routine's days
    /// name exactly one alarm, or they name none and the app says so. What the user picks is the
    /// bed, which is the thing the account can genuinely be ambiguous about and the thing he
    /// actually recognises.
    ///
    /// Everything that does not line up is reported rather than resolved. A routine with no matching
    /// alarm is not written anywhere, and an alarm no routine describes is not touched.
    func write(_ target: ResolvedTarget, plan: RoutinePlan) async throws -> WriteReceipt {
        let alarms = try await fetchAlarms()
        guard !alarms.isEmpty else {
            // OneAlarm creates alarms now, but only by cloning one this account already has. With
            // zero alarms there is no template, and the only way to make one would be to compose a
            // payload from a reference library that contradicts itself about field names thirty
            // lines apart. That contradiction ends up in the bed's temperature, so the honest
            // answer stays "make one, any time, once".
            throw AdapterError.noAlarmToUpdate
        }

        // Fall back to the single target when no plan came in, so this path has one behaviour rather
        // than two. A one-entry plan is just a plan with one routine in it.
        let entries = plan.entries.isEmpty
            ? [RoutinePlan.Entry(routineID: "target", routineName: "your alarm",
                                 weekdays: target.weekdays, localTime: target.localTime, bentTo: nil)]
            : plan.entries

        let described = alarms.compactMap { alarm -> RoutinePlan.CandidateAlarm? in
            guard let id = Self.alarmID(alarm) else { return nil }
            return RoutinePlan.CandidateAlarm(
                id: id,
                weekdays: Self.weekdays(of: alarm),
                isEnabled: (alarm["enabled"] as? Bool) ?? true,
                label: Self.shortLabel(alarm)
            )
        }

        var report = RoutinePlan.match(entries: entries, against: described)
        let (token, user) = try await currentToken()

        // A routine with no alarm gets one, rather than a warning telling him to go and make it.
        //
        // Alex, 2026-08-16: *"the OneAlarm app should also write the new alarm sequence into the
        // Eight Sleep app, and I shouldn't do it manually."* He is right that being told to go and
        // build the thing by hand in another app is the app failing at its one job.
        //
        // Every alarm created here is a clone of one he already has, so no field is composed. See
        // `clone` and `alarmCeiling` for what stops this becoming the reference library's ten alarm
        // discovery routine.
        var created: [String] = []
        var createdIDs = Set<String>()
        if !report.routinesWithNoAlarm.isEmpty,
           let template = Self.template(from: alarms),
           alarms.count < Self.alarmCeiling {
            // Iterating the entries rather than the names, so each routine gets at most one alarm
            // even if two of them happen to derive the same display name.
            for entry in entries where report.routinesWithNoAlarm.contains(entry.routineName) {
                guard !entry.weekdays.isEmpty,
                      alarms.count + created.count < Self.alarmCeiling
                else { continue }

                if let newID = try await postAlarm(
                    Self.clone(template, days: entry.weekdays, time: entry.timeToWrite),
                    token: token,
                    user: user
                ) {
                    created.append(entry.routineName)
                    createdIDs.insert(newID)
                    report.pairs.append(
                        AlarmMatchReport.Pair(
                            routineID: entry.routineID,
                            routineName: entry.routineName,
                            alarmID: newID,
                            time: entry.timeToWrite,
                            isDisabledRemotely: false
                        )
                    )
                }
            }
            // The create already carried the right time, so these need no follow up PUT.
            report.routinesWithNoAlarm.removeAll { created.contains($0) }
        }

        guard !report.pairs.isEmpty else {
            throw AdapterError.noMatchingDays(
                routines: report.routinesWithNoAlarm,
                alarms: described.filter { !$0.weekdays.isEmpty }.map(\.label)
            )
        }

        // Which alarm `verify` should read back: the one covering the morning the target is for.
        // That is the only pair whose `nextTimestamp` can be compared against an instant we meant.
        // Nothing else is verifiable, and verifying the wrong one would confirm a write we were not
        // asked about while saying nothing about the one that matters tonight.
        let nextWeekday = Locale.Weekday.from(
            calendarIndex: Calendar(identifier: .gregorian).component(.weekday, from: target.nextOccurrence)
        )
        let verifiableID = report.pairs.first { pair in
            entries.first { $0.routineID == pair.routineID }?.weekdays.contains(nextWeekday) == true
        }?.alarmID

        // Sequential rather than concurrent. Two or three requests against a personal account stays
        // well inside a single-digit rate, and one at a time means a failure names which routine
        // failed instead of arriving as a race.
        var failures: [String] = []
        var written = Set<String>()
        for pair in report.pairs {
            // A freshly created alarm already carries the right time, and it is not in `alarms`,
            // which was fetched before the create. Running it through the update loop would look it
            // up, fail to find it, and report the routine as failed straight after creating it.
            if createdIDs.contains(pair.alarmID) {
                written.insert(pair.alarmID)
                continue
            }

            guard let existing = alarms.first(where: { Self.alarmID($0) == pair.alarmID }),
                  let url = URL(string: "\(Self.appHost)/v1/users/\(user)/alarms/\(pair.alarmID)")
            else {
                failures.append(pair.routineName)
                continue
            }

            let body = try HTTPClient.json(Self.mutate(existing, to: pair.time))
            let response = try await http.send("PUT", url, headers: Self.baseHeaders(token: token), body: body)

            if response.status == 403 { throw AdapterError.subscriptionRequired }
            if response.status == 429 {
                backOff()
                throw AdapterError.rateLimited
            }
            if response.status == 401 {
                accessToken = nil
                throw AdapterError.authenticationFailed("Token was rejected.")
            }
            guard response.isSuccess else {
                failures.append("\(pair.routineName) (HTTP \(response.status))")
                continue
            }
            written.insert(pair.alarmID)
        }

        guard failures.count < report.pairs.count else {
            throw AdapterError.unexpectedResponse("Every routine failed to write: \(failures.joined(separator: ", ")).")
        }

        authState = .connected

        var note = report.note
        if !created.isEmpty {
            // Named, and named first. Creating an alarm on a live account is the most consequential
            // thing this app does, it cannot be undone from here, and a user who did not expect it
            // needs to know which one to go and look at.
            note = "Created a new alarm on your bed for \(created.joined(separator: " and ")), copied from your existing one. " + note
        }
        if !failures.isEmpty {
            note += " Failed: \(failures.joined(separator: ", "))."
        }
        if let bent = entries.first(where: \.isBent) {
            // Named because it is a real liability. Eight Sleep has no one-day override, so a bend is
            // held in the routine's own alarm and put back on the next sync after the morning. If
            // the app never runs again, the bed keeps the bent time.
            note += " \(bent.routineName) is holding \(bent.timeToWrite.hhmm) for one morning, and goes back to \(bent.localTime.hhmm) on the next sync."
        }
        if plan.skipsNextMorning {
            // Eight Sleep has a `skipNext` field this app has never written. Reasoning about a field
            // from its name is what cost five hours on Whoop, so it is stated rather than sent.
            note += " Your bed is not skipped: OneAlarm does not switch off an Eight Sleep alarm. Skip it in their app if you do not want the bed to react."
        }

        return WriteReceipt(
            device: .eightSleep,
            succeededAt: Date(),
            // `nil` when the morning's own alarm is not among the ones that landed. `verify` then
            // reports unavailable, which is the honest answer, rather than confirming a different
            // alarm and calling tonight verified.
            remoteID: verifiableID.flatMap { written.contains($0) ? $0 : nil },
            note: note,
            isPartial: !report.isComplete || !failures.isEmpty
        )
    }

    /// Create one alarm. Returns its new id, or `nil` if the server refused.
    ///
    /// Deliberately returns rather than throws on a refusal. A create that fails must not take down
    /// the updates to the routines that did match: the weekday alarm still needs its new time even
    /// if the weekend one could not be made. The refusal is reported by name in the receipt instead.
    ///
    /// The 4xx cases that must stop everything, a dead subscription, a rejected token, a throttle,
    /// still throw, because none of them is specific to this one alarm.
    private func postAlarm(
        _ payload: [String: Any],
        token: String,
        user: String
    ) async throws -> String? {
        guard let url = URL(string: "\(Self.appHost)/v1/users/\(user)/alarms") else { return nil }

        let response = try await http.send(
            "POST", url, headers: Self.baseHeaders(token: token), body: try HTTPClient.json(payload)
        )

        if response.status == 403 { throw AdapterError.subscriptionRequired }
        if response.status == 429 {
            backOff()
            throw AdapterError.rateLimited
        }
        if response.status == 401 {
            accessToken = nil
            throw AdapterError.authenticationFailed("Token was rejected.")
        }
        guard response.isSuccess else { return nil }

        // The id can arrive bare or wrapped. Both spellings are read rather than assumed, because
        // returning nil here would leave a real alarm on his account that the app then reports as
        // not created, which is the worst of both.
        guard let json = try? HTTPClient.dictionary(response.data) else { return nil }
        return Self.alarmID(json) ?? (json["alarm"] as? [String: Any]).flatMap(Self.alarmID)
    }

    /// The seven named booleans, as a set.
    static func weekdays(of alarm: [String: Any]) -> Set<Locale.Weekday> {
        guard let week = (alarm["repeat"] as? [String: Any])?["weekDays"] as? [String: Any] else {
            return []
        }
        // `repeat.enabled` off means a one-shot alarm, whatever the day flags say. Treating it as a
        // recurring day set would match it to a routine and move it every week.
        if let repeating = (alarm["repeat"] as? [String: Any])?["enabled"] as? Bool, !repeating {
            return []
        }
        return Set(Locale.Weekday.displayOrder.filter { (week[$0.eightSleepKey] as? Bool) == true })
    }

    /// "07:00 Mon Tue Wed Thu Fri", for naming an alarm the app is deliberately not touching.
    static func shortLabel(_ alarm: [String: Any]) -> String {
        let time = (alarm["time"] as? String).map { String($0.prefix(5)) } ?? "unknown time"
        let days = weekdays(of: alarm)
        if days.isEmpty { return "\(time), no days" }
        if days == Locale.Weekday.everyDay { return "\(time) every day" }
        if days == Locale.Weekday.weekdaysOnly { return "\(time) weekdays" }
        return time + " " + Locale.Weekday.displayOrder.filter { days.contains($0) }
            .map(\.shortLabel).joined(separator: " ")
    }

    /// The read back that makes this leg trustworthy.
    ///
    /// We send a bare `"06:50:00"` with no offset and Eight Sleep resolves it against a time zone
    /// stored on their side that the client never sees. If that zone is stale, the alarm fires at
    /// the wrong absolute moment and the write still returns 200. The returned `nextTimestamp` is
    /// UTC, so comparing it against the instant we intended is the only way to catch it.
    func verify(_ receipt: WriteReceipt, against target: ResolvedTarget) async throws -> Verification {
        // No id means the routine covering tonight was not one of the ones that landed, so there is
        // nothing here that can be checked against the instant we intended. Saying so is the point:
        // reading back a different routine's alarm would return a confirmed instant for a morning
        // nobody asked about.
        guard receipt.remoteID != nil else {
            return .unavailable(reason: "no alarm on your bed covers the next morning.")
        }

        // Two attempts, because the server may not have recomputed `nextTimestamp` by the time the
        // PUT returns. Reading it too early gets the pre write value and raises a mismatch, which
        // is the loudest warning the app has, for a write that was actually fine.
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }

            let alarms = try await fetchAlarms()
            guard
                let updated = alarms.first(where: { Self.alarmID($0) == receipt.remoteID }),
                let timestamp = updated["nextTimestamp"] as? String,
                let actual = ISO8601DateFormatter.parseFlexible(timestamp)
            else {
                continue
            }

            if matches(actual, target.nextOccurrence) {
                return .confirmed(at: actual)
            }
            if attempt == 1 {
                return .mismatch(expected: target.nextOccurrence, actual: actual)
            }
        }

        return .unavailable(reason: "Eight Sleep did not return a next alarm time to check.")
    }
}
