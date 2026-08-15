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
/// dictionary, changes only `time`, `enabled` and `repeat`, and sends everything else back exactly
/// as the server gave it. Unknown fields survive untouched, so the contradiction cannot bite us and
/// neither can any field added upstream later.
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

    private static func mutate(_ alarm: [String: Any], to target: ResolvedTarget) -> [String: Any] {
        var payload = alarm
        for field in computedFields {
            payload.removeValue(forKey: field)
        }

        payload["time"] = target.localTime.hhmmss
        payload["enabled"] = true

        // Weekdays are seven lowercase named booleans, not a bitmask and not an array.
        var weekDays: [String: Bool] = [:]
        for day in Locale.Weekday.displayOrder {
            weekDays[day.eightSleepKey] = target.weekdays.contains(day)
        }
        var repeatBlock = (payload["repeat"] as? [String: Any]) ?? [:]
        repeatBlock["enabled"] = true
        repeatBlock["weekDays"] = weekDays
        payload["repeat"] = repeatBlock

        return payload
    }

    nonisolated func preview(_ target: ResolvedTarget) -> WritePreview {
        var weekDays: [String: Bool] = [:]
        for day in Locale.Weekday.displayOrder {
            weekDays[day.eightSleepKey] = target.weekdays.contains(day)
        }
        var repeatBlock: [String: Any] = [:]
        repeatBlock["enabled"] = true
        repeatBlock["weekDays"] = weekDays

        var sketch: [String: Any] = [:]
        sketch["time"] = target.localTime.hhmmss
        sketch["enabled"] = true
        sketch["repeat"] = repeatBlock

        return WritePreview(
            device: .eightSleep,
            summary: "Update the existing alarm to \(target.localTime.hhmm) local, keeping its vibration and thermal settings untouched.",
            method: "PUT",
            url: "\(Self.appHost)/v1/users/{userId}/alarms/{alarmId}",
            body: HTTPClient.redactedPreview(sketch, showing: Self.previewKeys)
        )
    }

    /// The allowlist recurses, so the weekday keys inside `weekDays` have to be named too or the
    /// preview shows seven redactions instead of the schedule.
    private static let previewKeys: Set<String> = ["time", "enabled", "repeat", "weekDays"]
        .union(Locale.Weekday.displayOrder.map(\.eightSleepKey))

    func write(_ target: ResolvedTarget) async throws -> WriteReceipt {
        let alarms = try await fetchAlarms()
        guard let existing = alarms.first, let alarmID = existing["id"] as? String else {
            // Creating one is possible, but the create payload is exactly where the field name
            // contradiction lives. Better to tell the user to make one alarm in the Eight Sleep app
            // once than to guess at a payload and silently set the wrong thing.
            throw AdapterError.noAlarmToUpdate
        }

        let (token, user) = try await currentToken()
        guard let url = URL(string: "\(Self.appHost)/v1/users/\(user)/alarms/\(alarmID)") else {
            throw AdapterError.transport("Bad alarm update URL.")
        }

        let payload = Self.mutate(existing, to: target)
        let body = try HTTPClient.json(payload)
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
            throw AdapterError.unexpectedResponse("HTTP \(response.status) updating the alarm.")
        }

        authState = .connected
        // Which alarm was moved is worth saying out loud when there is more than one, because the
        // choice is the server's list order and nothing else.
        let previous = (existing["time"] as? String) ?? "an existing alarm"
        let note = alarms.count > 1
            ? "Moved the first of \(alarms.count) alarms, previously \(previous)."
            : "Updated the existing alarm, previously \(previous)."

        return WriteReceipt(
            device: .eightSleep,
            succeededAt: Date(),
            remoteID: alarmID,
            note: note
        )
    }

    /// The read back that makes this leg trustworthy.
    ///
    /// We send a bare `"06:50:00"` with no offset and Eight Sleep resolves it against a time zone
    /// stored on their side that the client never sees. If that zone is stale, the alarm fires at
    /// the wrong absolute moment and the write still returns 200. The returned `nextTimestamp` is
    /// UTC, so comparing it against the instant we intended is the only way to catch it.
    func verify(_ receipt: WriteReceipt, against target: ResolvedTarget) async throws -> Verification {
        // Two attempts, because the server may not have recomputed `nextTimestamp` by the time the
        // PUT returns. Reading it too early gets the pre write value and raises a mismatch, which
        // is the loudest warning the app has, for a write that was actually fine.
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }

            let alarms = try await fetchAlarms()
            guard
                let updated = alarms.first(where: { ($0["id"] as? String) == receipt.remoteID }),
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
