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
    private let http = HTTPClient(allowedPatterns: [
        #"^https://api\.prod\.whoop\.com/auth-service/v3/whoop/$"#,
        #"^https://api\.prod\.whoop\.com/smart-alarm-bff/v1/schedule/all\?apiVersion=7$"#,
        #"^https://api\.prod\.whoop\.com/smart-alarm-bff/v1/schedule/[^/?]+\?apiVersion=7$"#,
    ])

    private(set) var authState: AuthState = .notConfigured

    private var accessToken: String?
    private var tokenExpiry: Date?
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

    func refreshAuthState() async {
        let configured = keychain.has(.whoopRefreshToken)
            || (keychain.has(.whoopEmail) && keychain.has(.whoopPassword))
        if !configured {
            authState = .notConfigured
        } else if case .needsReauth = authState {
            // Leave it flagged until the user acts.
        } else {
            authState = .connected
        }
    }

    /// One attempt only. Never wrap this in a retry loop: repeated failures hit
    /// `TooManyRequestsException` on the auth endpoint and risk locking the account out.
    func signIn(email: String, password: String) async throws -> SignInOutcome {
        guard let url = URL(string: Self.host + Self.authPath) else {
            throw AdapterError.transport("Bad auth URL.")
        }

        // ClientId is deliberately empty. Whoop's proxy injects the real client id and secret, so
        // the iOS app's client secret is not needed.
        let body = try HTTPClient.json([
            "AuthFlow": "USER_PASSWORD_AUTH",
            "AuthParameters": ["USERNAME": email, "PASSWORD": password],
            "ClientId": "",
        ])

        let response = try await http.send(
            "POST", url, headers: Self.authHeaders(target: "InitiateAuth"), body: body
        )

        if response.status == 429 { throw AdapterError.rateLimited }
        guard response.isSuccess else {
            authState = .needsReauth("Whoop rejected the email or password.")
            throw AdapterError.authenticationFailed("HTTP \(response.status)")
        }

        let json = try HTTPClient.dictionary(response.data)

        if let challengeName = json["ChallengeName"] as? String, let session = json["Session"] as? String {
            try keychain.save(email, for: .whoopEmail)
            try keychain.save(password, for: .whoopPassword)
            let challenge = Challenge(name: challengeName, session: session, username: email)
            pendingChallenge = challenge
            return .needsCode(challenge)
        }

        try store(authResult: json, email: email, password: password)
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
        ])

        let response = try await http.send(
            "POST", url, headers: Self.authHeaders(target: "RespondToAuthChallenge"), body: body
        )

        if response.status == 429 { throw AdapterError.rateLimited }
        guard response.isSuccess else {
            throw AdapterError.authenticationFailed("That code was not accepted. Codes expire after about three minutes.")
        }

        let json = try HTTPClient.dictionary(response.data)
        try store(authResult: json, email: challenge.username, password: nil)
        pendingChallenge = nil
    }

    private func store(authResult json: [String: Any], email: String, password: String?) throws {
        guard
            let result = json["AuthenticationResult"] as? [String: Any],
            let access = result["AccessToken"] as? String
        else {
            throw AdapterError.unexpectedResponse("Sign in response carried no access token.")
        }

        try keychain.save(email, for: .whoopEmail)
        if let password {
            try keychain.save(password, for: .whoopPassword)
        }
        if let refresh = result["RefreshToken"] as? String {
            // Written before the response is treated as successful, so a crash here cannot leave a
            // rotated token unsaved and the account locked out.
            try keychain.save(refresh, for: .whoopRefreshToken)
        }

        accessToken = access
        tokenExpiry = Date().addingTimeInterval((result["ExpiresIn"] as? Double) ?? 86_400)
        authState = .connected
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

        guard let refresh = try? keychain.readString(.whoopRefreshToken) else {
            authState = .notConfigured
            throw AdapterError.notConfigured
        }
        guard let url = URL(string: Self.host + Self.authPath) else {
            throw AdapterError.transport("Bad auth URL.")
        }

        let body = try HTTPClient.json([
            "AuthFlow": "REFRESH_TOKEN_AUTH",
            "AuthParameters": ["REFRESH_TOKEN": refresh],
            "ClientId": "",
        ])

        let response = try await http.send(
            "POST", url, headers: Self.authHeaders(target: "InitiateAuth"), body: body
        )

        guard response.isSuccess else {
            // The refresh token is an opaque blob whose expiry cannot be read locally, so this is
            // the only way we find out it has aged out. Roughly thirty days, and then a fresh sign
            // in with the SMS code is required.
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

        accessToken = access
        tokenExpiry = Date().addingTimeInterval((result["ExpiresIn"] as? Double) ?? 86_400)
        authState = .connected
        return access
    }

    // MARK: Schedule

    private func fetchSchedules() async throws -> [[String: Any]] {
        let token = try await currentToken()
        guard let url = URL(string: "\(Self.host)/smart-alarm-bff/v1/schedule/all?apiVersion=7") else {
            throw AdapterError.transport("Bad schedule URL.")
        }

        let response = try await http.send(
            "GET", url,
            headers: Self.dataHeaders(token: token, timeZone: TimeZone.current.identifier)
        )

        if response.status == 429 { throw AdapterError.rateLimited }
        if response.status == 401 {
            accessToken = nil
            throw AdapterError.authenticationFailed("Token was rejected.")
        }
        guard response.isSuccess else {
            throw AdapterError.unexpectedResponse("HTTP \(response.status) reading the alarm schedule.")
        }

        let json = try HTTPClient.dictionary(response.data)
        return (json["alarm_schedule_list"] as? [[String: Any]]) ?? []
    }

    /// The reference implementation reads either key because it was unsure which the API returns,
    /// so we tolerate both rather than guessing.
    private static func scheduleID(_ schedule: [String: Any]) -> String? {
        (schedule["schedule_id"] as? String) ?? (schedule["id"] as? String)
    }

    private static func mutate(_ schedule: [String: Any], to target: ResolvedTarget) -> [String: Any] {
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
            body: HTTPClient.redactedPreview(sketch)
        )
    }

    func write(_ target: ResolvedTarget) async throws -> WriteReceipt {
        let schedules = try await fetchSchedules()
        guard
            let existing = schedules.first,
            let id = Self.scheduleID(existing)
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

        let body = try HTTPClient.json(Self.mutate(existing, to: target))
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
        return WriteReceipt(
            device: .whoop,
            succeededAt: Date(),
            remoteID: id,
            note: "Updated the smart alarm schedule."
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

        let echoed = WallClockTime(hour: parts[0], minute: parts[1])
        guard echoed == target.localTime else {
            return .unavailable(
                reason: "Whoop reads back \(echoed.hhmm) instead of \(target.localTime.hhmm)."
            )
        }
        return .confirmed(at: target.nextOccurrence)
    }
}
