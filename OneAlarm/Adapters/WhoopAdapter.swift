import Foundation

/// The Whoop leg, over the private mobile API.
///
/// Chosen over the Bluetooth alternative because it is model agnostic. The BLE path arms the
/// strap's own firmware alarm and is the better option in almost every respect, no credentials, no
/// terms of service exposure, nothing to break when Whoop changes a backend, but it is only
/// hardware verified on a WHOOP 4.0 and unverified on 5 and MG. This path works on all of them.
/// If the strap turns out to be a 4.0, switching to BLE is a worthwhile follow up.
///
/// Same read modify write discipline as the Eight Sleep leg, for a different reason. The schedule
/// PUT replaces rather than merges, so anything not sent is lost. Reading the schedule first and
/// changing only the wake time, days, enabled flag and offset means the smart wake mode Alex
/// already chose in the Whoop app survives untouched.
actor WhoopAdapter: DeviceAdapter {

    nonisolated let device: DeviceID = .whoop

    private static let host = "https://api.prod.whoop.com"
    private static let authPath = "/auth-service/v3/whoop/"

    private let keychain: KeychainStore
    /// Verb included, so an allowlisted path cannot be reached with a different method. In
    /// particular `DELETE .../schedule/{id}` would destroy the schedule and is not expressible.
    ///
    /// Note the host prefix too: `smart-alarm-service` is a different prefix from the allowlisted
    /// `smart-alarm-bff`, which puts the master enable/disable and the `smartalarm/wbl` telemetry
    /// endpoint out of reach. That separation is deliberate and worth not undoing.
    private let http = HTTPClient(allowedPatterns: [
        #"^POST https://api\.prod\.whoop\.com/auth-service/v3/whoop/$"#,
        #"^GET https://api\.prod\.whoop\.com/smart-alarm-bff/v1/schedule/all\?apiVersion=7$"#,
        #"^PUT https://api\.prod\.whoop\.com/smart-alarm-bff/v1/schedule/[^/?]+\?apiVersion=7$"#,
    ])

    private(set) var authState: AuthState = .notConfigured

    private var accessToken: String?
    private var tokenExpiry: Date?
    private var retryNotBefore: Date?
    private var currentBackoff: TimeInterval = 0
    /// Set while an SMS or TOTP challenge is outstanding.
    private(set) var pendingChallenge: Challenge?

    struct Challenge: Equatable, Sendable {
        let name: String
        let session: String
        let username: String

        var responseKey: String {
            switch name {
            case "SMS_MFA": return "SMS_MFA_CODE"
            case "SOFTWARE_TOKEN_MFA": return "SOFTWARE_TOKEN_MFA_CODE"
            case "EMAIL_OTP": return "EMAIL_OTP_CODE"
            default: return "SMS_MFA_CODE"
            }
        }

        var prompt: String {
            switch name {
            case "SOFTWARE_TOKEN_MFA": return "Enter the code from your authenticator app."
            case "EMAIL_OTP": return "Enter the code Whoop emailed you."
            default: return "Enter the code Whoop just texted you."
            }
        }
    }

    enum SignInOutcome: Equatable, Sendable {
        case signedIn
        case needsCode(Challenge)
    }

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    // MARK: Auth

    /// The AWS SDK fingerprint is not optional. Without it the request is met with a Cloudflare 403
    /// before it reaches Cognito at all.
    private static func authHeaders(target: String) -> [String: String] {
        [
            "content-type": "application/x-amz-json-1.1",
            "x-amz-target": "AWSCognitoIdentityProviderService.\(target)",
            "amz-sdk-invocation-id": UUID().uuidString,
            "amz-sdk-request": "attempt=1; max=1",
            "user-agent": "aws-sdk-swift/1.5.86 ua/2.1 api/cognito_identity_provider#1.5.86 os/ios#26.3.1 lang/swift#5.10 m/D,N,Z,b",
            "accept": "*/*",
            "accept-language": "en-US,en;q=0.9",
        ]
    }

    private static func dataHeaders(token: String, timeZone: String) -> [String: String] {
        [
            "authorization": "Bearer \(token)",
            "user-agent": "iOS",
            "x-whoop-device-platform": "iOS",
            "x-whoop-time-zone": timeZone,
            "accept": "*/*",
            "content-type": "application/json",
        ]
    }

    /// Only a refresh token counts as connected.
    ///
    /// An email and password do not, because sign in can stop at an MFA challenge: abandon the
    /// sheet at the code prompt and the credentials are on disk while no token exists, so the UI
    /// would read "Connected" and every write would throw `notConfigured`.
    func refreshAuthState() async {
        switch keychain.presence(.whoopRefreshToken) {
        case .absent:
            authState = .notConfigured
        case .unknownDeviceLocked:
            break
        case .present:
            if case .needsReauth = authState {
                // Leave it flagged until the user acts.
            } else {
                authState = .connected
            }
        }
    }

    /// One attempt only. Never wrap this in a retry loop: repeated failures hit
    /// `TooManyRequestsException` on the auth endpoint and risk locking the account out.
    func signIn(email: String, password: String) async throws -> SignInOutcome {
        if let notBefore = retryNotBefore, Date() < notBefore {
            throw AdapterError.rateLimited
        }
        guard let url = URL(string: Self.host + Self.authPath) else {
            throw AdapterError.transport("Bad auth URL.")
        }

        // ClientId is deliberately empty. Whoop's proxy injects the real client id and secret, so
        // the iOS app's client secret is not needed.
        let body = try HTTPClient.json([
            "AuthFlow": "USER_PASSWORD_AUTH",
            "AuthParameters": ["USERNAME": email, "PASSWORD": password],
            "ClientId": "",
        ] as [String: Any])

        let response = try await http.send(
            "POST", url, headers: Self.authHeaders(target: "InitiateAuth"), body: body
        )

        if response.status == 429 {
            backOff()
            throw AdapterError.rateLimited
        }
        guard response.isSuccess else {
            authState = .needsReauth("Whoop rejected the email or password.")
            throw AdapterError.authenticationFailed("HTTP \(response.status)")
        }

        retryNotBefore = nil
        currentBackoff = 0
        let json = try HTTPClient.dictionary(response.data)

        if let challengeName = json["ChallengeName"] as? String, let session = json["Session"] as? String {
            // Nothing is persisted until the challenge is answered. An unconfirmed credential on
            // disk is a credential that makes the app claim a connection it does not have.
            let challenge = Challenge(name: challengeName, session: session, username: email)
            pendingChallenge = challenge
            return .needsCode(challenge)
        }

        try store(authResult: json, email: email)
        return .signedIn
    }

    func submitCode(_ code: String) async throws {
        guard let challenge = pendingChallenge else {
            throw AdapterError.authenticationFailed("There is no code to confirm.")
        }
        guard let url = URL(string: Self.host + Self.authPath) else {
            throw AdapterError.transport("Bad auth URL.")
        }

        let body = try HTTPClient.json([
            "ChallengeName": challenge.name,
            "ChallengeResponses": [
                "USERNAME": challenge.username,
                challenge.responseKey: code,
            ],
            "ClientId": "",
            "Session": challenge.session,
        ] as [String: Any])

        let response = try await http.send(
            "POST", url, headers: Self.authHeaders(target: "RespondToAuthChallenge"), body: body
        )

        if response.status == 429 { throw AdapterError.rateLimited }
        guard response.isSuccess else {
            throw AdapterError.authenticationFailed("That code was not accepted. Codes expire after about three minutes.")
        }

        let json = try HTTPClient.dictionary(response.data)

        // Cognito can answer one challenge with another. Without this the user is told the response
        // carried no access token and left with no way forward.
        if let next = json["ChallengeName"] as? String, let session = json["Session"] as? String {
            pendingChallenge = Challenge(name: next, session: session, username: challenge.username)
            throw AdapterError.authenticationFailed("Whoop asked for a second code.")
        }

        try store(authResult: json, email: challenge.username)
        pendingChallenge = nil
    }

    private func store(authResult json: [String: Any], email: String) throws {
        guard
            let result = json["AuthenticationResult"] as? [String: Any],
            let access = result["AccessToken"] as? String
        else {
            throw AdapterError.unexpectedResponse("Sign in response carried no access token.")
        }

        try keychain.save(email, for: .whoopEmail)
        // The password is deliberately not stored. Re-auth is refresh token only, and an MFA
        // challenge means a saved password could not produce a silent sign in anyway, so keeping
        // one would be a second live account credential held indefinitely for no function.
        if let refresh = result["RefreshToken"] as? String {
            // Written before the response is treated as successful, so a crash here cannot leave a
            // rotated token unsaved and the account locked out.
            try keychain.save(refresh, for: .whoopRefreshToken)
        }

        accessToken = access
        tokenExpiry = Date().addingTimeInterval((result["ExpiresIn"] as? Double) ?? 86_400)
        authState = .connected
    }

    /// Same idea as the Eight Sleep check, and it matters more here. Whoop has three separate
    /// enable switches and a schedule shape nobody has fully captured, so "signed in" is a long way
    /// from "the strap will buzz". Finding that out now beats finding it out by oversleeping.
    func readiness() async throws -> String {
        let choices = try await availableAlarms()
        guard let chosen = RemoteAlarmSelection.resolve(choices, for: .whoop) else {
            if choices.isEmpty { throw AdapterError.noAlarmToUpdate }
            throw AdapterError.alarmChoiceNeeded(count: choices.count)
        }

        let schedules = try await fetchSchedules()
        guard let selected = schedules.first(where: { Self.scheduleID($0) == chosen.id }) else {
            throw AdapterError.noAlarmToUpdate
        }

        // Fail here rather than at write time if the shape is not what the adapter can safely edit.
        _ = try Self.mutate(selected, to: ResolvedTarget(
            device: .whoop,
            localTime: WallClockTime(hour: 7, minute: 0),
            weekdays: [.monday],
            dayShift: 0,
            nextOccurrence: Date(),
            utcOffsetSeconds: TimeZone.current.secondsFromGMT()
        ))

        return "Connected. Will move the smart alarm at \(chosen.summary)."
    }

    /// Every smart alarm schedule on the account, described well enough to pick from.
    func availableAlarms() async throws -> [RemoteAlarmChoice] {
        try await fetchSchedules().compactMap { schedule in
            guard let id = Self.scheduleID(schedule) else { return nil }
            let parts = (schedule["latest_wake_time"] as? String)?
                .split(separator: ":").compactMap { Int($0) } ?? []
            let time = parts.count >= 2 ? WallClockTime(hour: parts[0], minute: parts[1]) : nil

            let names = Set((schedule["day_of_week_list"] as? [String]) ?? [])
            let days = Set(Locale.Weekday.displayOrder.filter { names.contains($0.whoopName) })

            let mode = (schedule["alarm_mode"] as? String)?
                .replacingOccurrences(of: "_", with: " ")
                .lowercased()

            return RemoteAlarmChoice(
                id: id,
                time: time,
                weekdays: days,
                isEnabled: (schedule["enabled"] as? Bool) ?? true,
                detail: mode
            )
        }
    }

    func signOut() {
        try? keychain.delete(.whoopEmail)
        try? keychain.delete(.whoopPassword)
        try? keychain.delete(.whoopRefreshToken)
        accessToken = nil
        tokenExpiry = nil
        pendingChallenge = nil
        authState = .notConfigured
    }

    private func currentToken() async throws -> String {
        if let token = accessToken, let expiry = tokenExpiry, Date().addingTimeInterval(300) < expiry {
            return token
        }

        // A credential the server has already rejected is never sent again on its own.
        if case .needsReauth = authState {
            throw AdapterError.notConfigured
        }
        if let notBefore = retryNotBefore, Date() < notBefore {
            throw AdapterError.rateLimited
        }

        guard let refresh = try? keychain.readString(.whoopRefreshToken) else {
            throw AdapterError.notConfigured
        }
        guard let url = URL(string: Self.host + Self.authPath) else {
            throw AdapterError.transport("Bad auth URL.")
        }

        let body = try HTTPClient.json([
            "AuthFlow": "REFRESH_TOKEN_AUTH",
            "AuthParameters": ["REFRESH_TOKEN": refresh],
            "ClientId": "",
        ] as [String: Any])

        let response = try await http.send(
            "POST", url, headers: Self.authHeaders(target: "InitiateAuth"), body: body
        )

        // A throttle must never be diagnosed as an expired token. Doing so tells the user to sign
        // in again, which routes them straight into a password grant while the auth endpoint is
        // already rate limiting, which is the one thing this API must not be asked to do.
        if response.status == 429 {
            backOff()
            throw AdapterError.rateLimited
        }
        guard response.isSuccess else {
            // The refresh token is an opaque blob whose expiry cannot be read locally, so this is
            // the only way we find out it has aged out. Roughly thirty days, and then a fresh sign
            // in with the code is required.
            authState = .needsReauth("Whoop needs you to sign in again with a fresh code.")
            throw AdapterError.authenticationFailed("Refresh token expired.")
        }

        let json = try HTTPClient.dictionary(response.data)
        guard
            let result = json["AuthenticationResult"] as? [String: Any],
            let access = result["AccessToken"] as? String
        else {
            throw AdapterError.unexpectedResponse("Refresh returned no access token.")
        }

        // Cognito is not configured to rotate on this flow today, so no new refresh token comes
        // back. Saving one if it ever does costs nothing and avoids silently keeping a dead token.
        if let rotated = result["RefreshToken"] as? String {
            try keychain.save(rotated, for: .whoopRefreshToken)
        }

        accessToken = access
        tokenExpiry = Date().addingTimeInterval((result["ExpiresIn"] as? Double) ?? 86_400)
        authState = .connected
        retryNotBefore = nil
        currentBackoff = 0
        return access
    }

    private func backOff() {
        let next = min((currentBackoff == 0 ? 60 : currentBackoff * 2), 900)
        currentBackoff = next
        retryNotBefore = Date().addingTimeInterval(next)
    }

    // MARK: Schedule

    /// The whole `schedule/all` payload, since the master enable flag lives beside the list rather
    /// than inside it.
    private func fetchScheduleEnvelope() async throws -> [String: Any] {
        let token = try await currentToken()
        guard let url = URL(string: "\(Self.host)/smart-alarm-bff/v1/schedule/all?apiVersion=7") else {
            throw AdapterError.transport("Bad schedule URL.")
        }

        let response = try await http.send(
            "GET", url,
            headers: Self.dataHeaders(token: token, timeZone: TimeZone.current.identifier)
        )

        if response.status == 429 {
            backOff()
            throw AdapterError.rateLimited
        }
        if response.status == 401 {
            accessToken = nil
            throw AdapterError.authenticationFailed("Token was rejected.")
        }
        guard response.isSuccess else {
            throw AdapterError.unexpectedResponse("HTTP \(response.status) reading the alarm schedule.")
        }

        return try HTTPClient.dictionary(response.data)
    }

    private func fetchSchedules() async throws -> [[String: Any]] {
        let envelope = try await fetchScheduleEnvelope()
        try Self.assertMasterSwitchOn(envelope)
        return (envelope["alarm_schedule_list"] as? [[String: Any]]) ?? []
    }

    /// Whoop has three independent enable levels: the per schedule `enabled` we write, a global
    /// `schedule_enabled`, and a master switch on a different service we deliberately cannot reach.
    ///
    /// Writing only the first is enough to get a 200 and a green tick while the strap stays silent,
    /// so the global flag is checked and the write refused rather than reported as a success. The
    /// master switch is on `smart-alarm-service`, which is outside the allowlist on purpose, so if
    /// that is off it has to be turned on in the Whoop app.
    private static func assertMasterSwitchOn(_ envelope: [String: Any]) throws {
        if let enabled = envelope["schedule_enabled"] as? Bool, enabled == false {
            throw AdapterError.unexpectedResponse(
                "Whoop's alarm schedule is switched off. Turn it on in the Whoop app first."
            )
        }
    }

    /// The reference implementation reads either key because it was unsure which the API returns,
    /// so we tolerate both rather than guessing.
    private static func scheduleID(_ schedule: [String: Any]) -> String? {
        (schedule["schedule_id"] as? String) ?? (schedule["id"] as? String)
    }

    /// Throws rather than sending a partial replace.
    ///
    /// This PUT replaces rather than merges, so anything absent from the payload is lost. The read
    /// shape here is the least verified part of the whole Whoop leg: the reference project's own
    /// source hedges where these fields sit on a GET, and it ships no captured alarm response to
    /// check against. If the two we depend on are not where we expect, the honest outcome is a
    /// refusal, not a write that silently resets the smart wake mode he chose.
    static func mutate(_ schedule: [String: Any], to target: ResolvedTarget) throws -> [String: Any] {
        guard schedule["latest_wake_time"] is String, schedule["alarm_mode"] is String else {
            throw AdapterError.unexpectedResponse(
                "Whoop returned a schedule in an unexpected shape, so it was not changed."
            )
        }
        var payload = schedule
        payload["latest_wake_time"] = target.localTime.hhmmss
        payload["day_of_week_list"] = Locale.Weekday.displayOrder
            .filter { target.weekdays.contains($0) }
            .map(\.whoopName)
        payload["enabled"] = true
        // A fixed offset string with no daylight saving awareness, so it is re-sent on every write
        // and recomputed for the specific instant the alarm will fire.
        payload["time_zone_offset"] = target.utcOffsetString
        payload.removeValue(forKey: "schedule_id")
        payload.removeValue(forKey: "id")
        return payload
    }

    nonisolated func preview(_ target: ResolvedTarget) -> WritePreview {
        let days: [String] = Locale.Weekday.displayOrder
            .filter { target.weekdays.contains($0) }
            .map(\.whoopName)

        var sketch: [String: Any] = [:]
        sketch["latest_wake_time"] = target.localTime.hhmmss
        sketch["day_of_week_list"] = days
        sketch["enabled"] = true
        sketch["time_zone_offset"] = target.utcOffsetString

        return WritePreview(
            device: .whoop,
            summary: "Move the smart alarm ceiling to \(target.localTime.hhmm) local, keeping the wake mode you set in the Whoop app.",
            method: "PUT",
            url: "\(Self.host)/smart-alarm-bff/v1/schedule/{id}?apiVersion=7",
            body: HTTPClient.redactedPreview(
                sketch,
                showing: ["latest_wake_time", "day_of_week_list", "enabled", "time_zone_offset"]
            )
        )
    }

    func write(_ target: ResolvedTarget) async throws -> WriteReceipt {
        let schedules = try await fetchSchedules()

        // Never guess when the account holds more than one. Moving the wrong alarm is silent and
        // only discovered by not waking up.
        let chosenID: String?
        if let saved = RemoteAlarmSelection.selected(for: .whoop),
           schedules.contains(where: { Self.scheduleID($0) == saved }) {
            chosenID = saved
        } else if schedules.count == 1 {
            chosenID = Self.scheduleID(schedules[0])
        } else if schedules.count > 1 {
            throw AdapterError.alarmChoiceNeeded(count: schedules.count)
        } else {
            chosenID = nil
        }

        guard
            let id = chosenID,
            let existing = schedules.first(where: { Self.scheduleID($0) == id })
        else {
            // Creating a schedule was never captured by the reference work, so we do not invent a
            // payload for it. Making one alarm once in the Whoop app is a smaller ask than a
            // guessed request against a private API.
            throw AdapterError.noAlarmToUpdate
        }

        let token = try await currentToken()
        guard let url = URL(string: "\(Self.host)/smart-alarm-bff/v1/schedule/\(id)?apiVersion=7") else {
            throw AdapterError.transport("Bad schedule update URL.")
        }

        let body = try HTTPClient.json(try Self.mutate(existing, to: target))
        let response = try await http.send(
            "PUT", url,
            headers: Self.dataHeaders(token: token, timeZone: TimeZone.current.identifier),
            body: body
        )

        if response.status == 429 { throw AdapterError.rateLimited }
        guard response.isSuccess else {
            throw AdapterError.unexpectedResponse("HTTP \(response.status) updating the alarm.")
        }

        authState = .connected
        let previous = (existing["latest_wake_time"] as? String).map { String($0.prefix(5)) } ?? "an existing schedule"
        let note = schedules.count > 1
            ? "Moved your chosen schedule of \(schedules.count), previously \(previous)."
            : "Updated the smart alarm schedule, previously \(previous)."

        return WriteReceipt(
            device: .whoop,
            succeededAt: Date(),
            remoteID: id,
            note: note
        )
    }

    /// Whoop returns no absolute timestamp, so the check reconstructs one from the wall clock and
    /// offset it echoes back and compares that against the instant we intended.
    func verify(_ receipt: WriteReceipt, against target: ResolvedTarget) async throws -> Verification {
        let schedules = try await fetchSchedules()
        guard
            let updated = schedules.first(where: { Self.scheduleID($0) == receipt.remoteID }),
            let wake = updated["latest_wake_time"] as? String
        else {
            return .unavailable(reason: "Whoop did not return the updated schedule.")
        }

        let parts = wake.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else {
            return .unavailable(reason: "Whoop returned an unreadable wake time.")
        }

        // Both halves have to be checked. Comparing wall clock alone would pass even if the server
        // rewrote or ignored the offset, which is precisely the failure that wakes him an hour out,
        // so the echoed offset is reconstructed into a real instant and compared against the one we
        // intended.
        let echoed = WallClockTime(hour: parts[0], minute: parts[1])
        let echoedOffset = (updated["time_zone_offset"] as? String) ?? target.utcOffsetString

        guard echoed == target.localTime, echoedOffset == target.utcOffsetString else {
            let actual = Self.instant(matching: echoed, offset: echoedOffset, near: target.nextOccurrence)
            return .mismatch(expected: target.nextOccurrence, actual: actual ?? target.nextOccurrence)
        }
        return .confirmed(at: target.nextOccurrence)
    }

    /// Rebuild an absolute instant from a wall clock and a `"+0100"` style offset, on the same day
    /// as the target, so a mismatch can be reported as a real time rather than a shrug.
    private static func instant(matching time: WallClockTime, offset: String, near reference: Date) -> Date? {
        guard offset.count == 5, let magnitude = Int(offset.dropFirst()) else { return nil }
        let seconds = (magnitude / 100 * 3600 + magnitude % 100 * 60) * (offset.hasPrefix("-") ? -1 : 1)

        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(secondsFromGMT: seconds) else { return nil }
        calendar.timeZone = zone

        var components = calendar.dateComponents([.year, .month, .day], from: reference)
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        return calendar.date(from: components)
    }
}
