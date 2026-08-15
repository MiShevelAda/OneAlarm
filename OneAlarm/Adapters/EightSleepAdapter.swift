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
    private static let clientHost = "https://client-api.8slp.net"
    private static let appHost = "https://app-api.8slp.net"

    // Public values, extracted from the Android app and hardcoded in the reference library.
    private static let clientID = "0894c7f33bb94800a03f1f4df13a4f38"
    private static let clientSecret = "f0954a3ed5763ba3d06834c73731a32f15f168f47d4f164751275def86db0c76"

    private let keychain: KeychainStore
    private let http = HTTPClient(allowedPatterns: [
        #"^https://auth-api\.8slp\.net/v1/tokens$"#,
        #"^https://client-api\.8slp\.net/v1/users/me$"#,
        #"^https://app-api\.8slp\.net/v2/users/[^/]+/alarms$"#,
        #"^https://app-api\.8slp\.net/v1/users/[^/]+/alarms$"#,
        #"^https://app-api\.8slp\.net/v1/users/[^/]+/alarms/[^/]+$"#,
    ])

    private(set) var authState: AuthState = .notConfigured

    private var accessToken: String?
    private var tokenExpiry: Date?
    private var userID: String?

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    // MARK: Auth

    func refreshAuthState() async {
        let configured = keychain.has(.eightSleepEmail) && keychain.has(.eightSleepPassword)
        if !configured {
            authState = .notConfigured
        } else if case .needsReauth = authState {
            // Leave a known bad credential flagged until the user changes it.
        } else {
            authState = .connected
        }
    }

    func signIn(email: String, password: String) async throws {
        try keychain.save(email, for: .eightSleepEmail)
        try keychain.save(password, for: .eightSleepPassword)
        accessToken = nil
        tokenExpiry = nil
        do {
            _ = try await currentToken()
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
        authState = .notConfigured
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

        guard
            let email = try? keychain.readString(.eightSleepEmail),
            let password = try? keychain.readString(.eightSleepPassword)
        else {
            authState = .notConfigured
            throw AdapterError.notConfigured
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

        if response.status == 429 { throw AdapterError.rateLimited }
        guard response.isSuccess else {
            authState = .needsReauth("Eight Sleep rejected the email or password.")
            throw AdapterError.authenticationFailed("HTTP \(response.status)")
        }

        let json = try HTTPClient.dictionary(response.data)
        guard
            let token = json["access_token"] as? String,
            let user = json["userId"] as? String
        else {
            throw AdapterError.unexpectedResponse("Auth response was missing access_token or userId.")
        }

        // Read the lifetime off the response rather than assuming one.
        let lifetime = (json["expires_in"] as? Double) ?? 3600
        accessToken = token
        userID = user
        tokenExpiry = Date().addingTimeInterval(lifetime)
        return (token, user)
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
            // Authentication succeeded and this call is what failed. Its own error so it never
            // reads as a bug in our code.
            authState = .needsReauth("Eight Sleep alarms need an active subscription.")
            throw AdapterError.subscriptionRequired
        }
        if response.status == 429 { throw AdapterError.rateLimited }
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
            body: HTTPClient.redactedPreview(sketch)
        )
    }

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
        if response.status == 429 { throw AdapterError.rateLimited }
        guard response.isSuccess else {
            throw AdapterError.unexpectedResponse("HTTP \(response.status) updating the alarm.")
        }

        authState = .connected
        return WriteReceipt(
            device: .eightSleep,
            succeededAt: Date(),
            remoteID: alarmID,
            note: "Updated the existing alarm."
        )
    }

    /// The read back that makes this leg trustworthy.
    ///
    /// We send a bare `"06:50:00"` with no offset and Eight Sleep resolves it against a time zone
    /// stored on their side that the client never sees. If that zone is stale, the alarm fires at
    /// the wrong absolute moment and the write still returns 200. The returned `nextTimestamp` is
    /// UTC, so comparing it against the instant we intended is the only way to catch it.
    func verify(_ receipt: WriteReceipt, against target: ResolvedTarget) async throws -> Verification {
        let alarms = try await fetchAlarms()
        guard
            let updated = alarms.first(where: { ($0["id"] as? String) == receipt.remoteID }),
            let timestamp = updated["nextTimestamp"] as? String,
            let actual = ISO8601DateFormatter.parseFlexible(timestamp)
        else {
            return .unavailable(reason: "Eight Sleep did not return a next alarm time to check.")
        }

        return matches(actual, target.nextOccurrence)
            ? .confirmed(at: actual)
            : .mismatch(expected: target.nextOccurrence, actual: actual)
    }
}
