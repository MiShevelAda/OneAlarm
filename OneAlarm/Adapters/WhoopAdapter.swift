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
        // The edit screen for one schedule. A read, and the only place the write contract is stated
        // by the server rather than inferred by us: it returns repeat_days, wake_mode, wake_time
        // and sleep_goal, which is the vocabulary the PUT is validated against.
        #"^GET https://api\.prod\.whoop\.com/smart-alarm-bff/v1/schedule/components/populated/[^/?]+\?apiVersion=7$"#,
        #"^PUT https://api\.prod\.whoop\.com/smart-alarm-bff/v1/schedule/[^/?]+\?apiVersion=7$"#,
    ])

    private(set) var authState: AuthState = .notConfigured

    private var accessToken: String?
    private var tokenExpiry: Date?
    private var retryNotBefore: Date?
    private var currentBackoff: TimeInterval = 0
    /// Set while an SMS or TOTP challenge is outstanding.
    private(set) var pendingChallenge: Challenge?

    struct Challenge: Equatable, Sendable, Codable {
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
            "x-whoop-bundle-name": "com.whoop.iphone",
            "x-whoop-clock-format": "TWELVE_HOUR",
            "accept-language": "en",
            "accept": "*/*",
            "content-type": "application/json",
        ]
    }

    /// The edit screen for one schedule, as top level key names.
    ///
    /// A read, and the only description of the write contract that comes from the server rather
    /// than from us. `schedule/all` renders the list; this renders the form, so its fields are the
    /// ones a save is built from. Failure here is reported rather than thrown: this runs while
    /// explaining a different failure and must not replace it with its own.
    private func editScreenKeys(for id: String) async -> String {
        guard
            let token = try? await currentToken(),
            let url = URL(string: "\(Self.host)/smart-alarm-bff/v1/schedule/components/populated/\(id)?apiVersion=7"),
            let response = try? await http.send(
                "GET", url,
                headers: Self.dataHeaders(token: token, timeZone: TimeZone.current.identifier)
            )
        else {
            return "unreadable"
        }
        guard response.isSuccess else { return "HTTP \(response.status)" }
        guard let object = try? HTTPClient.dictionary(response.data) else { return "not an object" }
        return object.keys.sorted().joined(separator: " ")
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
            rememberChallenge(challenge)
            return .needsCode(challenge)
        }

        try store(authResult: json, email: email)
        return .signedIn
    }

    /// - Parameter known: the challenge the caller was handed by `signIn`.
    ///
    /// Taken as a parameter rather than read from actor state, because relying on state that has to
    /// survive the user leaving the app to fetch the code has now failed twice: once in memory, and
    /// once through the Keychain. The caller already holds the value, so it hands it back and there
    /// is nothing left to lose. Actor state and the stored copy remain as fallbacks.
    func submitCode(_ code: String, using known: Challenge? = nil) async throws {
        guard let challenge = known ?? pendingChallenge ?? storedChallenge() else {
            throw AdapterError.authenticationFailed(
                "That sign in attempt has expired. Tap Send a new code and try again."
            )
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
            rememberChallenge(Challenge(name: next, session: session, username: challenge.username))
            throw AdapterError.authenticationFailed("Whoop asked for a second code.")
        }

        try store(authResult: json, email: challenge.username)
        forgetChallenge()
    }

    private func rememberChallenge(_ challenge: Challenge) {
        pendingChallenge = challenge
        if let data = try? JSONEncoder().encode(challenge) {
            try? keychain.save(data, for: .whoopChallenge)
        }
    }

    private func storedChallenge() -> Challenge? {
        guard let data = try? keychain.readData(.whoopChallenge) else { return nil }
        return try? JSONDecoder().decode(Challenge.self, from: data)
    }

    private func forgetChallenge() {
        pendingChallenge = nil
        try? keychain.delete(.whoopChallenge)
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
            let time = Self.wakeTime(from: schedule["latest_wake_time"])
            let days = Self.days(from: schedule["scheduled_days"])

            let mode = (schedule["alarm_mode"] as? String)?
                .replacingOccurrences(of: "_", with: " ")
                .lowercased()

            return RemoteAlarmChoice(
                id: id,
                time: time,
                weekdays: days,
                isEnabled: (schedule["alarm_on"] as? Bool) ?? true,
                detail: mode,
                rawKeys: Self.describe(schedule)
            )
        }
    }

    func signOut() {
        try? keychain.delete(.whoopEmail)
        try? keychain.delete(.whoopPassword)
        try? keychain.delete(.whoopRefreshToken)
        accessToken = nil
        tokenExpiry = nil
        forgetChallenge()
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

    /// Tolerant of what Whoop might actually be sending, since the spec was wrong about the names
    /// and is therefore not trustworthy about the shape either.
    ///
    /// A real account returned `"7:45 am"`. The spec showed `"07:45:00"`. Both parse here. The
    /// write does **not** mirror whichever arrived: see `encodeWakeTime`.
    static func wakeTime(from value: Any?) -> WallClockTime? {
        if let text = value as? String {
            let lower = text.lowercased()
            let isPM = lower.contains("pm")
            let isAM = lower.contains("am")
            let digits = lower
                .replacingOccurrences(of: "am", with: "")
                .replacingOccurrences(of: "pm", with: "")
                .trimmingCharacters(in: .whitespaces)

            let parts = digits
                .split(separator: ":")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

            if parts.count >= 2 {
                var hour = parts[0]
                // Only apply the 12 hour rules when a suffix says to. A bare "13:30" must not be
                // touched, and "12:30 am" is half past midnight, not half past noon.
                if isPM, hour < 12 { hour += 12 }
                if isAM, hour == 12 { hour = 0 }
                return WallClockTime(hour: hour, minute: parts[1])
            }
            // Could be an ISO instant rather than a wall clock.
            if let date = ISO8601DateFormatter.parseFlexible(text) {
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                if let h = c.hour, let m = c.minute { return WallClockTime(hour: h, minute: m) }
            }
            return nil
        }
        if let number = value as? NSNumber {
            let raw = number.intValue
            // Minutes since midnight, or seconds since midnight.
            if raw < 1440 { return WallClockTime(minutesSinceMidnight: raw) }
            if raw < 86_400 { return WallClockTime(minutesSinceMidnight: raw / 60) }
        }
        return nil
    }

    /// The canonical `"HH:mm:ss"`, whatever the read looked like.
    ///
    /// Deliberately **not** a mirror of the incoming format, which is what this was before. The
    /// reason is the captured request that returned 200, which used `"07:30:00"`.
    ///
    /// It is **not** the 400 we got for `"1:00 pm"`, though an earlier version of this comment said
    /// so with some confidence. Those two requests differed in three ways at once: the format, the
    /// clock value, and the fact that 13:00 is an implausible wake ceiling. "400 because 13:00 is
    /// out of range" fits that pair exactly as well as "400 because the string would not parse".
    /// One observation with three variables moved is not evidence for either, and it was written
    /// into two doc comments as though it were settled.
    static func encodeWakeTime(_ time: WallClockTime, like existing: Any?) -> Any {
        guard existing is String else {
            // Numeric, so the units follow the same reading the parser made.
            if let number = existing as? NSNumber, number.intValue >= 1440 {
                return time.minutesSinceMidnight * 60
            }
            return time.minutesSinceMidnight
        }
        return time.hhmmss
    }

    /// `true` as the same kind of value the server sent.
    ///
    /// JSON `true` and JSON `1` both arrive as `NSNumber` and both print as `1`, so the only way to
    /// tell them apart is the CoreFoundation type. Sending the wrong one is another 422 candidate.
    static func encodeFlag(_ flag: Bool, like existing: Any?) -> Any {
        if let existing, CFGetTypeID(existing as AnyObject) != CFBooleanGetTypeID() {
            return flag ? 1 : 0
        }
        return flag
    }

    static func days(from value: Any?) -> Set<Locale.Weekday> {
        if let names = value as? [String] {
            let upper = Set(names.map { $0.uppercased() })
            return Set(Locale.Weekday.displayOrder.filter {
                upper.contains($0.whoopName) || upper.contains(String($0.whoopName.prefix(3)))
            })
        }
        if let numbers = value as? [Int] {
            return Set(numbers.map { Locale.Weekday.from(calendarIndex: $0) })
        }
        return []
    }

    static func encodeDays(_ days: Set<Locale.Weekday>, like existing: Any?) -> Any {
        let ordered = Locale.Weekday.displayOrder.filter { days.contains($0) }
        if let sample = (existing as? [String])?.first {
            // Follow whatever spelling is already there rather than imposing one.
            let short = sample.count <= 3
            return ordered.map { short ? String($0.whoopName.prefix(3)) : $0.whoopName }
        }
        if existing is [Int] {
            return ordered.map(\.calendarIndex)
        }
        return ordered.map(\.whoopName)
    }

    /// A body in the reference spec's field names, built from scratch rather than edited into the
    /// view model.
    ///
    /// This is the correction to a wrong conclusion. When the GET came back with `scheduled_days`
    /// and `alarm_on`, I declared the spec's `day_of_week_list`, `enabled`, `time_zone_offset` and
    /// `sleep_goal` nonexistent. The envelope says otherwise: that GET returns
    /// `delete_error_modal`, `schedule_button_component` and `should_show_overlay` alongside the
    /// schedule, so it is a **rendered screen**, not the resource. Its `latest_wake_time` of
    /// `"7:45 am"` is a display string, which is exactly why sending it back earned a parse error.
    /// A view model and a domain object are allowed to disagree about names, and this pair does.
    ///
    /// The spec's names were never actually tried on their own: the first attempt set them **on
    /// top of** the view model, so the body was half screen description and half resource. That is
    /// its own reason for a 422 and it masked whether the names were right.
    static func domainBody(
        _ schedule: [String: Any],
        to target: ResolvedTarget,
        mode: String? = nil
    ) -> [String: Any] {
        [
            "latest_wake_time": target.localTime.hhmmss,
            "day_of_week_list": Locale.Weekday.displayOrder
                .filter { target.weekdays.contains($0) }
                .map(\.whoopName),
            "enabled": true,
            "time_zone_offset": target.utcOffsetString,
            "alarm_mode": mode ?? (schedule["alarm_mode"] as? String) ?? Self.observedMode,
            // Empty string in the captured request, so an empty string here. Not a placeholder.
            "sleep_goal": "",
        ]
    }

    /// The only `alarm_mode` ever observed to be accepted on a write.
    ///
    /// The view model reports the mode the app is displaying, which is not necessarily a value the
    /// write enum accepts: `SLEEP_GOAL` and `EXACT_TIME` are recent, and the captured 200 used this.
    static let observedMode = "IN_THE_GREEN"

    /// The body shapes still worth a request, best hypothesis first.
    ///
    /// The view model echo, full and trimmed, has been refused twice each, so it is retained as a
    /// single control rather than two. The domain body has never actually run: it was written after
    /// the last attempt, so every 422 so far belongs to the echo.
    static func variants(_ schedule: [String: Any], to target: ResolvedTarget) throws -> [(String, [String: Any])] {
        var shapes: [(String, [String: Any])] = [
            ("domain", Self.domainBody(schedule, to: target)),
        ]
        // A rejected enum is a parse failure, so a mode the write does not know would fail the whole
        // body for a reason that has nothing to do with the rest of it. One retry on the value that
        // is known to have worked, and only when it differs from what we just sent.
        if (schedule["alarm_mode"] as? String) != Self.observedMode {
            shapes.append(("domain/\(Self.observedMode)",
                           Self.domainBody(schedule, to: target, mode: Self.observedMode)))
        }
        shapes.append(("viewmodel", Self.trimmed(try Self.mutate(schedule, to: target))))
        return shapes
    }

    /// What the server actually objected to, so the next fix is read rather than guessed.
    ///
    /// This is an error about an alarm schedule on a request whose credential is in the headers, so
    /// there is nothing here to redact. Truncated because it has to fit in a row on a phone.
    static func serverMessage(_ data: Data) -> String {
        guard var text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return "nothing"
        }
        text = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return text.count > 200 ? String(text.prefix(200)) + "..." : text
    }

    /// Whether a JSON value means off, whichever of the three ways this API spells it.
    ///
    /// Unknown shapes are **not** false. A guard that refuses on anything it does not recognise
    /// would block every write the moment Whoop returned something new, and this one guards an
    /// alarm.
    static func isFalse(_ value: Any) -> Bool {
        if let flag = value as? Bool { return flag == false }
        if let number = value as? NSNumber { return number.intValue == 0 }
        if let text = value as? String {
            return ["false", "0", "no", "off"].contains(text.lowercased())
        }
        return false
    }

    /// The whole `/schedule/all` envelope, flattened to printable lines.
    ///
    /// **Why this exists, and why now.** On 17 August Alex deleted every schedule on his Whoop
    /// account. OneAlarm moves schedules and does not create them, so with zero of them it can do
    /// nothing at all, and Whoop's own `CREATE SCHEDULE` button did nothing either. He asked whether
    /// there is a way around it.
    ///
    /// There might be, and the answer is probably already in a response this adapter has been
    /// fetching all along and never printing. `docs/RESEARCH.md` §2.3 records that this endpoint is a
    /// **rendered screen**, not a resource, and lists what its top level carries:
    /// `delete_error_modal`, `deleting_in_progress_modal`, `schedule_disabled_text`,
    /// `should_show_overlay`, and **`schedule_button_component`**.
    ///
    /// That last one is Whoop's own description of the button he is looking at. With the account in
    /// its current empty state, this endpoint is rendering the create screen, so whatever the app
    /// does when that button is pressed is the most likely thing to be described in there.
    ///
    /// This is the project's one method that has ever worked on this service: **dump the response, do
    /// not reason about it.** Both Whoop breakthroughs came from printing what the server sent, after
    /// six rounds of reasoning produced six wrong answers and cost five hours. Nothing is inferred
    /// here and nothing is written.
    ///
    /// Read only, on a path already allowlisted. Nested objects are expanded one level, because the
    /// interesting keys are inside `schedule_button_component` rather than beside it.
    func envelopeDump() async -> [String] {
        guard let envelope = try? await fetchScheduleEnvelope() else {
            return ["Could not read the alarm screen. Check the Whoop connection above."]
        }
        var lines: [String] = []
        for key in envelope.keys.sorted() {
            let value = envelope[key]
            if let nested = value as? [String: Any] {
                lines.append("\(key) = {")
                for inner in nested.keys.sorted() {
                    lines.append("    \(inner) = \(Self.describeValue(nested[inner]))")
                }
                lines.append("}")
            } else if let list = value as? [[String: Any]] {
                lines.append("\(key) = [\(list.count) item\(list.count == 1 ? "" : "s")]")
                for (index, item) in list.enumerated() {
                    lines.append("  [\(index)]")
                    for inner in item.keys.sorted() {
                        lines.append("    \(inner) = \(Self.describeValue(item[inner]))")
                    }
                }
            } else {
                lines.append("\(key) = \(Self.describeValue(value))")
            }
        }
        return lines.isEmpty ? ["The alarm screen came back empty."] : lines
    }

    /// A value with its type, because `"7:45 am"` and `7:45 am` are different bugs.
    static func describeValue(_ value: Any?) -> String {
        guard let value else { return "nothing" }
        if let text = value as? String { return "\"\(text)\"" }
        return "\(value)"
    }

    /// Field names, and the values for the two that decide whether a write can work at all.
    /// Alarm schedule data, never a credential.
    static func describe(_ schedule: [String: Any]) -> [String] {
        var lines = schedule.keys.sorted()
        for key in ["latest_wake_time", "scheduled_days", "alarm_on"] {
            if let value = schedule[key] {
                lines.append("\(key) = \(value)")
            }
        }
        return lines
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
        // Not `as? Bool`. This envelope already returns alarm_on as 1 rather than true, so a
        // boolean-only read of schedule_enabled would silently pass on a number or a string and
        // report a green write against a disabled alarm, which is the exact failure this guard is
        // here to prevent. Absent stays permissive; present and false is a refusal.
        if let raw = envelope["schedule_enabled"], Self.isFalse(raw) {
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
        // Reading it back is the gate, not merely finding the key. If we cannot parse the value we
        // cannot reproduce its format either, and writing a format the server did not ask for is
        // exactly the failure this whole function now exists to avoid.
        guard let existing = schedule["latest_wake_time"], Self.wakeTime(from: existing) != nil else {
            throw AdapterError.unexpectedResponse(
                "Whoop returned a wake time OneAlarm could not read, so nothing was changed."
            )
        }

        var payload = schedule

        // 24 hour. The captured request that returned 200 used "07:30:00", which is the reason,
        // rather than the 400 we got for "1:00 pm": see `encodeWakeTime` for why that comparison
        // proves less than I claimed.
        payload["latest_wake_time"] = Self.encodeWakeTime(target.localTime, like: existing)

        if schedule["scheduled_days"] != nil {
            payload["scheduled_days"] = Self.encodeDays(target.weekdays, like: schedule["scheduled_days"])
        }
        if let flag = schedule["alarm_on"] {
            payload["alarm_on"] = Self.encodeFlag(true, like: flag)
        }
        return payload
    }

    /// `mutate` with everything we are not certain the server needs taken back out.
    ///
    /// The two differ only in what is removed, and which one is right is not something to reason
    /// about from first principles: a read modify write should send back what it was given, but
    /// echoing an identifier into a body and returning six stale `*_label_display` strings that
    /// describe the previous time both look wrong. So both are tried, in the order that keeps the
    /// server's own object intact first, and the receipt records which one it took.
    static func trimmed(_ payload: [String: Any]) -> [String: Any] {
        var copy = payload
        for key in Array(copy.keys) where key.hasSuffix("_label_display") {
            copy.removeValue(forKey: key)
        }
        copy.removeValue(forKey: "schedule_id")
        copy.removeValue(forKey: "id")
        return copy
    }

    nonisolated func preview(_ target: ResolvedTarget) -> WritePreview {
        let days: [String] = Locale.Weekday.displayOrder
            .filter { target.weekdays.contains($0) }
            .map(\.whoopName)

        // A sketch, and it says so. The real body is the schedule the server returned with these
        // three fields replaced, so it also carries `alarm_mode` and, in the untrimmed attempt, the
        // identifier and the display strings. None of that is visible from here.
        var sketch: [String: Any] = [:]
        sketch["latest_wake_time"] = target.localTime.hhmmss
        sketch["scheduled_days"] = days
        sketch["alarm_on"] = true
        sketch["alarm_mode"] = "(kept from your account)"

        return WritePreview(
            device: .whoop,
            summary: "Move the smart alarm ceiling to \(target.localTime.hhmm) local, keeping the wake mode you set in the Whoop app. Whoop's own wake mode decides how far before that ceiling the strap actually buzzes, so this is a latest time rather than a time.",
            method: "PUT",
            url: "\(Self.host)/smart-alarm-bff/v1/schedule/{id}?apiVersion=7",
            body: HTTPClient.redactedPreview(
                sketch,
                showing: ["latest_wake_time", "scheduled_days", "alarm_on", "alarm_mode"]
            ),
            reconstructed: true
        )
    }

    /// A bend must never shrink his Whoop week to the single day it falls on.
    ///
    /// **Observed on his account, 17 August 14:52.** He bent Monday. Whoop's own screen then showed
    /// one scheduled day, `MONDAY 08:51`, a `CREATE SCHEDULE` button, and:
    ///
    /// > You have unscheduled days. On unscheduled days, Sleep Planner will default to your most
    /// > recent wake time and set your alarm to off.
    ///
    /// Tuesday to Friday had no schedule and no alarm. One tap on `+15` deleted four mornings of
    /// strap alarm, silently, and the OneAlarm row went green while it happened.
    ///
    /// The cause is upstream and correct for a different leg. `ScheduleStore.recompute` sets
    /// `schedule.weekdays = [next.weekday]` while a bend is armed, because AlarmKit offers `.never`
    /// and `.weekly` and nothing between, so arming one weekday is the only way the phone can express
    /// "this Monday". Eight Sleep is unaffected: it takes its days from the plan, one alarm per
    /// routine, and a bend there changes a time and nothing else.
    ///
    /// Whoop holds **one schedule for the whole account**, with one time and one day list, so the
    /// collapsed set is not a narrower instruction, it is a deletion of every other day.
    ///
    /// So this leg takes its days from the plan: the routine covering the bent morning, at its full
    /// width. The cost, stated plainly rather than hidden: while the bend is armed the **bent time**
    /// sits on all of that routine's days, so Tuesday to Friday would buzz at the bent time until the
    /// next sync. That is a wrong time on a leg that is already the least authoritative of the three,
    /// against no alarm at all on four mornings. The expiry now also raises "Changed since last set",
    /// so the correction is one press away and visible.
    /// The target with its day set widened back to the covering routine's.
    ///
    /// Only ever narrows to a single day during a bend, and only on the single schedule path. On the
    /// per routine path each schedule already carries its own routine's days, so nothing is
    /// collapsed and this is not needed.
    private static func widened(_ target: ResolvedTarget, plan: RoutinePlan) -> ResolvedTarget {
        // The routine that owns the morning being written. `target.weekdays` is the collapsed set
        // during a bend, so it is used to find the routine rather than as the answer itself.
        let covering = plan.entries.first { entry in
            entry.shouldBeEnabled && !entry.weekdays.isDisjoint(with: target.weekdays)
        }
        guard let covering, covering.weekdays != target.weekdays else { return target }

        // Rebuilt rather than mutated: every field on `ResolvedTarget` is a `let`. Only the day set
        // changes, and `nextOccurrence` in particular is carried through untouched, because it is the
        // absolute instant the verification compares against and recomputing it here would be a
        // second answer to a question already answered.
        return ResolvedTarget(
            device: target.device,
            localTime: target.localTime,
            weekdays: covering.weekdays,
            dayShift: target.dayShift,
            nextOccurrence: target.nextOccurrence,
            utcOffsetSeconds: target.utcOffsetSeconds
        )
    }

    /// "07:00 Mo Tu We Th Fr", for naming a schedule on screen. Never used for matching.
    static func shortLabel(_ schedule: [String: Any]) -> String {
        let time = Self.wakeTime(from: schedule["latest_wake_time"])?.hhmm ?? "??:??"
        let days = Locale.Weekday.displayOrder
            .filter { Self.days(from: schedule["scheduled_days"]).contains($0) }
            .map(\.shortLabel)
        return days.isEmpty ? time : "\(time) \(days.joined(separator: " "))"
    }

    /// One schedule updated, through the two body shapes, reporting every outcome.
    ///
    /// Extracted on 17 August so the single schedule path and the per routine path share exactly one
    /// PUT. Two copies of a write that is already the least understood thing in this app is how the
    /// two of them would end up disagreeing about the body, and only one of them would be the one
    /// that was tested.
    ///
    /// Two shapes at most, and every outcome is reported rather than only the last, because
    /// "full 422, trimmed 422" and "full 200" are different findings and only one screenshot comes
    /// back per round.
    private func putSchedule(
        _ existing: [String: Any],
        id: String,
        to target: ResolvedTarget,
        token: String
    ) async throws -> (shape: String, written: [String: Any]) {
        guard let url = URL(string: "\(Self.host)/smart-alarm-bff/v1/schedule/\(id)?apiVersion=7") else {
            throw AdapterError.transport("Bad schedule update URL.")
        }

        var accepted: (String, [String: Any])?
        var outcomes: [String] = []

        for (label, payload) in try Self.variants(existing, to: target) {
            let response = try await http.send(
                "PUT", url,
                headers: Self.dataHeaders(token: token, timeZone: TimeZone.current.identifier),
                body: try HTTPClient.json(payload)
            )

            if response.status == 429 { throw AdapterError.rateLimited }
            if response.isSuccess {
                accepted = (label, payload)
                break
            }

            // Per attempt, not collapsed into one. Two attempts that fail differently is the most
            // informative thing this can report, and a single shared string hid it: whichever
            // attempt spoke first silenced the other.
            var line = "\(label) \(payload.keys.count) fields: \(response.status)"
            let said = Self.serverMessage(response.data)
            if said != "nothing" { line += " (\(said))" }
            let fromHeaders = response.diagnosticHeaders
            if said == "nothing", !fromHeaders.isEmpty { line += " [\(fromHeaders)]" }
            if let redirected = response.redirectedTo { line += " REDIRECTED to \(redirected)" }
            outcomes.append(line)

            // Only a complaint about the body is worth a second shape. Anything else, stop.
            guard response.status == 400 || response.status == 422 else { break }
        }

        guard let accepted else {
            // A read, and the one description of the write contract that comes from the server.
            // Worth a request precisely because every guess so far has come from us.
            let editScreen = await editScreenKeys(for: id)
            throw AdapterError.unexpectedResponse(
                "Rejected updating the alarm. "
                    + outcomes.joined(separator: " | ")
                    + ". Sent \"\(target.localTime.hhmmss)\", account mode "
                    + Self.describeValue(existing["alarm_mode"])
                    + ". Edit screen: " + editScreen
            )
        }
        return accepted
    }

    /// One Whoop schedule per routine, matched by day set, exactly as the Eight Sleep leg works.
    ///
    /// **The premise this replaces was wrong, and his own account disproved it.** `STATUS.md` problem
    /// 5 and `E12` both said Whoop holds one schedule per account, so it could never express two
    /// routines and its days would always be rewritten by whichever routine covered tonight. The
    /// whole leg followed from that: one chosen schedule, `RemoteAlarmSelection` to pick it, and
    /// `alarmChoiceNeeded` thrown the moment a second appeared.
    ///
    /// On 17 August Alex made a Monday to Thursday schedule in the Whoop app, watched OneAlarm extend
    /// it to Friday, then made a **second** schedule for Saturday. Two live schedules on one account.
    /// `alarm_schedule_list` is a list because it is one. What he then reported is the direct
    /// consequence of the old design: *"I clicked again in the one alarm app for the weekend, Saturday
    /// and Sunday, but now it did not update Sunday inside whoop."* His weekend routine never reached
    /// this leg at all, because only one schedule was ever written and it was the one covering the
    /// next morning.
    ///
    /// **What is deliberately not copied from the Eight Sleep leg: the create.** A routine with no
    /// schedule is reported and left alone. Eight Sleep can create because a create there is a copy of
    /// an alarm he already owns with two fields changed, so nothing is invented. No public source
    /// documents creating a Whoop schedule, and composing one from scratch against this API is the
    /// thing that cost five hours. He makes it once in the Whoop app and OneAlarm keeps it from then
    /// on, which is exactly the deal Eight Sleep had before it earned the create.
    func write(_ target: ResolvedTarget, plan: RoutinePlan) async throws -> WriteReceipt {
        let envelope = try await fetchScheduleEnvelope()
        try Self.assertMasterSwitchOn(envelope)
        let schedules = (envelope["alarm_schedule_list"] as? [[String: Any]]) ?? []

        // One schedule, or none, or no plan: the old path, which also carries the bend widening.
        // Deliberately not routed through the matcher, because with a single schedule "the one he
        // has" and "the one this routine owns" are the same answer and the matcher would only add a
        // way to decide there is nothing to write.
        guard schedules.count > 1, !plan.entries.isEmpty else {
            return try await writeSingle(target, plan: plan)
        }

        let candidates = schedules.compactMap { schedule -> RoutinePlan.CandidateAlarm? in
            guard let id = Self.scheduleID(schedule) else { return nil }
            return RoutinePlan.CandidateAlarm(
                id: id,
                weekdays: Self.days(from: schedule["scheduled_days"]),
                isEnabled: !Self.isFalse(schedule["alarm_on"] ?? true),
                label: Self.shortLabel(schedule)
            )
        }

        let links = RemoteAlarmLink.all(for: .whoop)
        let report = RoutinePlan.match(entries: plan.entries, against: candidates, links: links)

        // Recorded before anything is written, so from here on a routine's schedule is identified by
        // the link rather than by its days. That is what lets the days change without the routine
        // losing track of which schedule is its own.
        for pair in report.pairs where pair.isAdoption {
            RemoteAlarmLink.link(routine: pair.routineID, to: pair.alarmID, on: .whoop)
        }

        guard !report.pairs.isEmpty else {
            throw AdapterError.noMatchingDays(
                routines: report.routinesWithNoAlarm,
                alarms: candidates.map(\.label)
            )
        }

        let token = try await currentToken()
        var moved: [String] = []
        var failures: [String] = []

        for pair in report.pairs {
            guard let existing = schedules.first(where: { Self.scheduleID($0) == pair.alarmID }) else { continue }
            let entry = plan.entries.first { $0.routineID == pair.routineID }
            let perRoutine = ResolvedTarget(
                device: .whoop,
                localTime: pair.time,
                weekdays: pair.weekdays,
                dayShift: target.dayShift,
                // Only the schedule covering the next morning has a meaningful absolute instant, and
                // it is the only one `verify` looks at. The others carry the same one rather than a
                // recomputed guess, because a second answer to a question already answered is how
                // this project has been wrong before.
                nextOccurrence: target.nextOccurrence,
                utcOffsetSeconds: target.utcOffsetSeconds
            )
            do {
                _ = try await putSchedule(existing, id: pair.alarmID, to: perRoutine, token: token)
                moved.append("\(entry?.routineName ?? pair.routineName) to \(pair.time.hhmm)")
            } catch {
                failures.append("\(pair.routineName): \((error as? AdapterError)?.errorDescription ?? "refused")")
            }
        }

        guard failures.count < report.pairs.count else {
            throw AdapterError.unexpectedResponse("Every schedule failed: \(failures.joined(separator: " | ")).")
        }

        authState = .connected
        var note = moved.isEmpty ? "Nothing to move." : "Moved \(moved.joined(separator: ", "))."
        if !report.routinesWithNoAlarm.isEmpty {
            note += " No Whoop schedule runs on \(report.routinesWithNoAlarm.joined(separator: " or ")). Make one in the Whoop app, any time, and OneAlarm keeps it from then on."
        }
        if !failures.isEmpty { note += " " + failures.joined(separator: " ") }

        return WriteReceipt(
            device: .whoop,
            succeededAt: Date(),
            // The schedule covering the next morning, because that is the one `verify` checks and a
            // receipt naming any other would compare the wrong row against the wrong instant.
            remoteID: report.pairs.first { !$0.weekdays.isDisjoint(with: target.weekdays) }?.alarmID
                ?? report.pairs[0].alarmID,
            note: note
        )
    }

    func write(_ target: ResolvedTarget) async throws -> WriteReceipt {
        try await writeSingle(target, plan: RoutinePlan(device: .whoop, entries: [], skipsNextMorning: false))
    }

    private func writeSingle(_ rawTarget: ResolvedTarget, plan: RoutinePlan) async throws -> WriteReceipt {
        // A bend collapses `weekdays` to one day upstream, which is right for AlarmKit and a deletion
        // here, because a single Whoop schedule carries the whole week. See `widened`.
        let target = Self.widened(rawTarget, plan: plan)
        // The envelope rather than just the list, because its other keys are the only part of this
        // endpoint's shape we have never looked at, and a 422 with an empty body has to be
        // diagnosed from something.
        let envelope = try await fetchScheduleEnvelope()
        try Self.assertMasterSwitchOn(envelope)
        let schedules = (envelope["alarm_schedule_list"] as? [[String: Any]]) ?? []

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
        let (shape, written) = try await putSchedule(existing, id: id, to: target, token: token)

        authState = .connected
        let previous = Self.wakeTime(from: existing["latest_wake_time"])?.hhmm ?? "an existing schedule"
        var note = schedules.count > 1
            ? "Moved your chosen schedule of \(schedules.count), previously \(previous)."
            : "Updated the smart alarm schedule, previously \(previous)."
        // Which shape it took, because that is the fact this leg keeps failing to have.
        note += " Accepted the \(shape) body, \(Self.describeValue(written["latest_wake_time"]))."

        return WriteReceipt(
            device: .whoop,
            succeededAt: Date(),
            remoteID: id,
            note: note
        )
    }

    /// Whoop returns no absolute timestamp, so the check reconstructs one from the wall clock it
    /// echoes back and compares that against the instant we intended.
    func verify(_ receipt: WriteReceipt, against target: ResolvedTarget) async throws -> Verification {
        let schedules = try await fetchSchedules()
        guard let updated = schedules.first(where: { Self.scheduleID($0) == receipt.remoteID }) else {
            return .unavailable(reason: "Whoop did not return the updated schedule.")
        }
        guard let echoed = Self.wakeTime(from: updated["latest_wake_time"]) else {
            return .unavailable(reason: "Whoop returned an unreadable wake time.")
        }

        // A real account carries no timezone field on the schedule, so there is nothing to check the
        // offset against and no honest way to pretend otherwise. Whoop stores a local wall clock and
        // resolves the zone from the strap, which is also why the wall clock alone is the answer
        // here rather than half of it.
        let echoedOffset = target.utcOffsetString

        guard echoed == target.localTime else {
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
