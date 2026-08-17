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
/// dictionary and sends everything back exactly as the server gave it, except the fields it owns.
/// Unknown fields survive untouched, so the contradiction cannot bite us and neither can any field
/// added upstream later. The same principle makes `clone` safe: a new alarm is a copy of a real one,
/// never a payload composed here.
///
/// **What it owns, set by Alex on 2026-08-16:** *"OneAlarm is my one single source of truth for
/// alarm setting... only the modifications of temperature, vibration etc should be done in the
/// respective app."* So three fields, and only on an alarm a routine owns: `time`,
/// `repeat.weekDays`, `enabled`. Ownership comes from `RemoteAlarmLink`. An alarm this app has never
/// owned is never written to at all.
///
/// This file changed direction twice in one day and both turns are recorded rather than tidied away.
/// Days were written, then banned at 09:00 after one hand-picked alarm serving two routines turned a
/// real Monday to Friday schedule into every day, then written again at 13:00 once ownership was
/// recorded and that ambiguity was gone. The ban was right for its reason and wrong as a rule.
actor EightSleepAdapter: DeviceAdapter {

    nonisolated let device: DeviceID = .eightSleep

    private static let authHost = "https://auth-api.8slp.net"
    private static let appHost = "https://app-api.8slp.net"

    // Public values, extracted from the Android app and hardcoded in the reference library.
    private static let clientID = "0894c7f33bb94800a03f1f4df13a4f38"
    private static let clientSecret = "f0954a3ed5763ba3d06834c73731a32f15f168f47d4f164751275def86db0c76"

    private let keychain: KeychainStore
    private var http = HTTPClient(allowedPatterns: EightSleepAdapter.allowedPatterns)

    /// Seven requests, verb included. Nothing else on this API is reachable from here.
    ///
    /// Note what is deliberately absent: `DELETE .../v1/users/{id}/alarms/{alarmId}`. It is
    /// unverified, it is irreversible, and nothing in this app needs it. A routine deleted in
    /// OneAlarm switches its alarm **off** instead, which he can undo in the Eight Sleep app in one
    /// tap. It is not listed, so it cannot be sent, including by a later edit that forgets why.
    static let allowedPatterns = [
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
        // account. What makes it safe here is not care, it is `clone`, which never composes a
        // payload. It copies an alarm the account already has, so no field is guessed, and it is
        // hard capped at `alarmCeiling`. Read those two before touching this line.
        #"^POST https://app-api\.8slp\.net/v1/users/[^/]+/alarms$"#,
        // Both versions, because which one creates an alarm is **not known**. This API is already
        // asymmetric where it has been observed: the list is `/v2/users/{id}/alarms` and the update
        // is `/v1/users/{id}/alarms/{alarmId}`, both confirmed against Alex's account. The create
        // path came from a write-up rather than a capture, and a search of every public Eight Sleep
        // project on 2026-08-16 found the list endpoint documented and the create endpoint
        // documented nowhere. A wrong path refuses every payload shape identically, which is
        // indistinguishable from a wrong payload. So both are allowlisted and both are tried, once,
        // and the answer is reported rather than assumed.
        #"^POST https://app-api\.8slp\.net/v2/users/[^/]+/alarms$"#,
        // Two reads, added to answer "which bed am I on". Neither can change anything.
        //
        // Note the third host. `client-api` is not `app-api`, and adding a host to an allowlist is
        // exactly the kind of edit that should be visible rather than incidental.
        // The routines endpoint, read only, added 2026-08-16.
        //
        // This is the object that explains three things at once. Eight Sleep's app models alarms
        // **inside routines**: a routine carries `id`, `days`, `enabled`, a `bedtime`, an `alarms`
        // array and an `alarmsToCreate` array. That is what the `routine-<uuid>` in every alarm's
        // `tags` points at. It is why an alarm created standalone through
        // `POST /v1/users/{id}/alarms` can exist on the API and never appear in their app, and it is
        // why the account returns three alarms where the app shows two.
        //
        // Alex asked for exactly this by name: *"be able to also write routines inside the 8sleep
        // app."*
        //
        // **Two versions are listed and they are not alternatives.** v2 is the object OneAlarm reads
        // and writes, `PUT /v2/users/{id}/routines/{routineId}`, confirmed in two independent public
        // captures. v1 is the **retired** Routines feature: `docs/RESEARCH.md` records that Eight
        // Sleep deleted it from the app and that any write-up PUTting to `/v1/users/{id}/routines`
        // for alarm control is obsolete. Both statements are true at once, because they are about
        // different objects that happen to share a word.
        //
        // So `fetchRoutines` reads v2 and only v2. The v1 line exists for `retiredRoutinesProbe`,
        // which runs only after v2 has failed, only to tell Alex whether the account is unreachable
        // or the address is wrong, and whose answer is printed and thrown away. Falling back to it
        // would mean reading object A and writing its fields to endpoint B, which is the shape of
        // the mistake that cost five hours on Whoop.
        #"^GET https://app-api\.8slp\.net/v2/users/[^/]+/routines$"#,
        #"^GET https://app-api\.8slp\.net/v1/users/[^/]+/routines$"#,
        // The routine write. Read modify write, exactly like the alarm write, and for exactly the
        // same reason: the shape is only partly understood, so the object the server sent comes back
        // untouched apart from the two fields OneAlarm owns. `bedtime` in particular is his and is
        // never authored. See `authorRoutine`.
        #"^PUT https://app-api\.8slp\.net/v2/users/[^/]+/routines/[^/]+$"#,
        // The only DELETE in this app, on any service.
        //
        // Alex overruled the blanket no-delete ban on 17 August after clearing three alarms off his
        // bed by hand. The allowlist is where that decision becomes narrow enough to be safe: one
        // verb, one host, one path, and the alarm id has to be one `RemoteAlarmLink.created` recorded
        // OneAlarm posting. Both gates have to agree before anything is destroyed.
        //
        // The path is the PUT path with a different verb, which is a REST **convention** and not a
        // captured request. Nothing public documents a delete here and the session cannot reach the
        // host to probe it. `E20` says so, and the code reports the status and falls back to
        // switching the alarm off rather than treating a refusal as done.
        //
        // Note what is still absent and stays absent: no DELETE on a routine, no DELETE on Whoop, no
        // DELETE anywhere near the pod, the pump or the bed frame. A path allowlisted for a read is
        // otherwise open to a destructive verb, which is the whole reason this allowlist is written
        // method-first.
        #"^DELETE https://app-api\.8slp\.net/v1/users/[^/]+/alarms/[^/]+$"#,
        #"^GET https://client-api\.8slp\.net/v1/users/me$"#,
        #"^GET https://app-api\.8slp\.net/v1/household/users/[^/]+/summary$"#,
    ]

    private(set) var authState: AuthState = .notConfigured

    private var accessToken: String?
    private var tokenExpiry: Date?
    private var userID: String?
    /// Set on a 429. No request goes out before it, so a throttle is respected rather than
    /// hammered. pyEight has no 429 handling at all, so this is ours rather than ported.
    private var retryNotBefore: Date?
    private var currentBackoff: TimeInterval = 0
    /// Which API version answered the routines read, once one has.
    ///
    /// Recorded rather than assumed because this service is version asymmetric in a way nothing
    /// public resolves, and because knowing the answer means the next version of this adapter can
    /// stop sending two requests.
    private(set) var routinesVersion: String?
    /// Why the routines read came back empty, when it did.
    ///
    /// An empty routine list and a refused routine read look identical from the outside, and the
    /// first means "you have none" while the second means "OneAlarm is calling the wrong address".
    private(set) var lastRoutineReadFailure: String?

    /// - Parameter session: a stub session, so the whole write path can be exercised offline.
    ///
    /// Added 2026-08-16. Every round that day ended with "build it and tell me what the screen
    /// says", because nothing between writing the code and Alex's bed could say whether it worked.
    /// That loop is why a create that succeeded was about to be reported to him as a failure twice.
    /// This seam moves most of the check to `Cmd+U`: the matching, the create, the routine write and
    /// the receipt text all become assertable in seconds. Only the API contract itself, whether
    /// Eight Sleep accepts these bodies, still needs a real account.
    ///
    /// Note that the session goes into `HTTPClient` rather than around it, so the allowlist, the
    /// redirect blocker and the JSON encoding all stay in the path under test. A stub that replaced
    /// the client would pass while the allowlist silently blocked every request.
    init(keychain: KeychainStore = KeychainStore(), session: URLSession? = nil) {
        self.keychain = keychain
        if let session {
            http = HTTPClient(allowedPatterns: Self.allowedPatterns, session: session)
        }
    }

    /// Skip the password grant, for tests only.
    ///
    /// `currentToken()` otherwise reaches the Keychain, which no test should touch and which is
    /// unavailable in a unit test host anyway. Nothing in the app calls this.
    func seedSessionForTesting(token: String, userID: String) {
        accessToken = token
        self.userID = userID
        tokenExpiry = Date().addingTimeInterval(3600)
        authState = .connected
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

        // Hidden alarms are excluded here for the same reason the write excludes them, and keeping
        // the two in step is the point. A screen or a status line that counts alarms the write will
        // never touch describes a different account from the one being written to.
        let report = RoutinePlan.match(
            entries: plan.entries,
            against: choices.filter { !$0.isHidden }.map(\.candidate)
        )
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
                // `group` before `rawKeys`, because that is the order `RemoteAlarmChoice` declares
                // them in and a memberwise initialiser has no other order. Swift says "Argument
                // 'group' must precede argument 'rawKeys'", which is exact and still easy to walk
                // past when the two lines read fine on their own.
                group: Self.groupName(alarm),
                rawKeys: Self.describe(alarm),
                isHidden: !Self.isVisibleToHim(alarm)
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
        // The links go with the account. Keeping them would mean a different account's alarm ids
        // sitting in a map that the next sign in trusts, and the first sync after that would author
        // alarms that belong to somebody else's bed.
        RemoteAlarmLink.forget(for: .eightSleep)
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

    /// The Autopilot resource, read only, printed for `E27`.
    ///
    /// **The first candidate address this project has had for the one time change**, and it came from
    /// outside research rather than from another guess at a field name. Eight Sleep's own description
    /// of the feature: *"you'll be able to train **Autopilot** on whether it's a one-time preference
    /// or you'd prefer it on all future nights."* A one time change is an Autopilot preference in
    /// their words, not an alarm property. And `steipete/eightctl` reads the Autopilot schedule from
    /// this endpoint, which OneAlarm has never called.
    ///
    /// Four dumps of the **alarm** object have now come back with no override field, which by
    /// elimination points at a separate resource. This is that resource, with an address.
    ///
    /// **A read, and only ever a read.** It cannot change anything, needs no capture and no ladder,
    /// and either contains the override or does not. Both other open theories require writing to a
    /// live bed. A failure returns a sentence rather than throwing, because a diagnostic that takes
    /// the screen down with it is worse than one that says it could not run.
    func autopilotDump() async -> String {
        guard let (token, user) = try? await currentToken() else {
            return "Could not read Autopilot: not signed in."
        }
        // **Two addresses, both read only, because neither is confirmed.**
        //
        // `autopilotDetails` is named after the feature and is the better candidate. `temperature`
        // carries a `smart` block that a public client calls the Autopilot schedule. Both come from
        // `steipete/eightctl`, whose alarm module contradicts this account on three counts and is
        // therefore not a source to trust, only a source of addresses to try. A GET settles that in
        // one request each.
        var report: [String] = []
        for path in ["autopilotDetails", "temperature"] {
            guard let url = URL(string: "\(Self.appHost)/v1/users/\(user)/\(path)") else { continue }
            guard let response = try? await http.send("GET", url, headers: Self.baseHeaders(token: token))
            else {
                report.append("\(path): the request failed.")
                continue
            }
            guard response.isSuccess else {
                // A 404 is an answer, not a failure: it removes an address from the list.
                report.append("\(path): HTTP \(response.status).")
                continue
            }
            guard let json = try? HTTPClient.dictionary(response.data) else {
                report.append("\(path): 200, but the body is not a JSON object.")
                continue
            }
            // The whole object when it is small, the shape when it is not. A dump nobody can read is
            // the failure this panel already exists to fix.
            let body = json.count > 40
                ? "top level keys only: " + json.keys.sorted().joined(separator: ", ")
                : Self.render(json, indent: 1)
            report.append("\(path): 200\n\(body)")
        }
        return report.joined(separator: "\n\n")
    }

    /// A nested dictionary as readable lines. Sorted, so two dumps can be compared by eye.
    ///
    /// **Sorted is the whole point.** The question this answers is "what changed between an override
    /// being set and not", and two dumps in server order cannot be diffed by a person.
    static func render(_ value: Any, indent: Int) -> String {
        let pad = String(repeating: "    ", count: indent)
        if let dict = value as? [String: Any] {
            return dict.keys.sorted().map { key in
                let inner = dict[key] ?? ""
                if inner is [String: Any] || inner is [Any] {
                    return "\(pad)\(key) =\n\(render(inner, indent: indent + 1))"
                }
                return "\(pad)\(key) = \(raw(inner))"
            }.joined(separator: "\n")
        }
        if let list = value as? [Any] {
            return list.map { "\(pad)- \(raw($0))" }.joined(separator: "\n")
        }
        return "\(pad)\(raw(value))"
    }

    // MARK: The baseline diff, which answers E23 without anybody reading a dump

    /// Every field of every alarm, flattened to `id.key.subkey = value`, for comparing two reads.
    ///
    /// **The instrument that should have existed on Monday.** Four rounds were spent asking Alex to
    /// read raw blocks and compare them by eye, and every one of them failed: three because the
    /// instruction never said which of four blocks, and the fourth because a wrong block's fields
    /// were then treated as proof of a field's absence.
    ///
    /// A person comparing two screenshots of thirteen nested fields is the wrong tool. The app has
    /// both reads. It can subtract them.
    ///
    /// Flattened rather than compared structurally, because the question is "which single value
    /// moved", and a nested diff answers a harder question than the one being asked. Computed fields
    /// are excluded: `nextTimestamp` moves on its own between any two reads, and a diff that always
    /// has noise in it is a diff nobody reads. That exclusion is the whole reason this is worth
    /// building rather than eyeballing.
    static func flatten(_ alarms: [[String: Any]]) -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ value: Any, path: String) {
            if let dict = value as? [String: Any] {
                for (key, inner) in dict where !computedFields.contains(key) {
                    walk(inner, path: "\(path).\(key)")
                }
                return
            }
            if let list = value as? [Any] {
                out[path] = list.map { raw($0) }.sorted().joined(separator: ", ")
                return
            }
            out[path] = raw(value)
        }
        for alarm in alarms {
            guard let id = alarmID(alarm) else { continue }
            // Keyed by the alarm's short label rather than its uuid, so a change reads as
            // "07:45 weekdays" rather than as eight hex characters nobody can place.
            walk(alarm, path: shortLabel(alarm) + " [\(id.prefix(4))]")
        }
        return out
    }

    /// What changed between a saved baseline and now, in words.
    ///
    /// Three kinds of change, kept apart because they mean different things: a value that moved, a
    /// field that appeared, and a field that vanished. **An appearing field is the one this exists
    /// to catch.** If Eight Sleep carries the one time change on the alarm object, setting one in
    /// their app makes a key appear that was not there before, and that is a sentence on a screen
    /// rather than two screenshots and a squint.
    static func diff(baseline: [String: String], now: [String: String]) -> [String] {
        var lines: [String] = []
        for key in Set(baseline.keys).union(now.keys).sorted() {
            switch (baseline[key], now[key]) {
            case let (old?, new?) where old != new:
                lines.append("CHANGED  \(key): \(old) -> \(new)")
            case (nil, let new?):
                lines.append("APPEARED \(key) = \(new)")
            case (let old?, nil):
                lines.append("GONE     \(key), was \(old)")
            default:
                continue
            }
        }
        return lines
    }

    private static let baselineKey = "OneAlarm.eightSleep.fieldBaseline"

    /// Remember every field of every alarm as it is right now.
    static func saveBaseline(_ alarms: [[String: Any]]) {
        UserDefaults.standard.set(flatten(alarms), forKey: baselineKey)
    }

    static func savedBaseline() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: baselineKey) as? [String: String] ?? [:]
    }

    /// The two candidate resources beyond the alarm object, flattened the same way.
    ///
    /// **So that one comparison settles every remaining theory at once.** The override has three
    /// possible homes and only three: the alarm object (`E28`), the Autopilot resource (`E27`), or
    /// nowhere reachable. Watching only the alarms would send back "nothing changed" and leave two
    /// of the three untested, which is a test that cannot fail usefully.
    ///
    /// Both are reads and a failure is simply absent from the snapshot rather than fatal. An
    /// endpoint that 404s on both passes contributes nothing and distorts nothing.
    private func sideResources() async -> [String: String] {
        var out: [String: String] = [:]
        guard let (token, user) = try? await currentToken() else { return out }
        for path in ["autopilotDetails", "temperature"] {
            guard let url = URL(string: "\(Self.appHost)/v1/users/\(user)/\(path)"),
                  let response = try? await http.send("GET", url, headers: Self.baseHeaders(token: token)),
                  response.isSuccess,
                  let json = try? HTTPClient.dictionary(response.data)
            else { continue }
            for (key, value) in Self.flattenObject(json, prefix: path) { out[key] = value }
        }
        return out
    }

    /// One object flattened to `prefix.key.subkey = value`. The alarm walker, without the alarm.
    static func flattenObject(_ object: [String: Any], prefix: String) -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ value: Any, path: String) {
            if let dict = value as? [String: Any] {
                for (key, inner) in dict where !computedFields.contains(key) {
                    walk(inner, path: "\(path).\(key)")
                }
                return
            }
            if let list = value as? [Any] {
                out[path] = list.map { raw($0) }.sorted().joined(separator: ", ")
                return
            }
            out[path] = raw(value)
        }
        walk(object, path: prefix)
        return out
    }

    /// Read everything and remember it as it is now.
    ///
    /// The fetch stays inside the adapter. `fetchAlarms` is private on purpose, and a view reaching
    /// through to it would be a second caller of the raw read with its own idea of error handling.
    func saveFieldBaseline() async -> String {
        guard let alarms = try? await fetchAlarms() else {
            return "Could not read your bed, so no baseline was saved."
        }
        var snapshot = Self.flatten(alarms)
        let side = await sideResources()
        for (key, value) in side { snapshot[key] = value }
        UserDefaults.standard.set(snapshot, forKey: Self.baselineKey)

        let extras = side.isEmpty
            ? "Autopilot returned nothing, so only the alarms are being watched."
            : "\(side.count) of those are Autopilot fields."
        return "Baseline saved: \(snapshot.count) fields across \(alarms.count) alarms. \(extras) Now set UPCOMING ALARM ONLY in the Eight Sleep app and press Compare."
    }

    /// Read the account and say what has moved since the baseline. One line when nothing has.
    func changesSinceBaseline() async -> String {
        guard let alarms = try? await fetchAlarms() else {
            return "Could not read your bed."
        }
        let baseline = Self.savedBaseline()
        guard !baseline.isEmpty else {
            return "No baseline saved yet. Press Save baseline first, then change something in the Eight Sleep app and come back."
        }
        var now = Self.flatten(alarms)
        for (key, value) in await sideResources() { now[key] = value }
        let changes = Self.diff(baseline: baseline, now: now)
        guard !changes.isEmpty else {
            // Stated rather than left blank. "Nothing changed" and "the check did not run" look
            // identical when both print nothing, and this project has fixed that confusion twice.
            return "Nothing on your bed has changed since the baseline. \(baseline.count) fields compared."
        }
        return changes.joined(separator: "\n")
    }

    /// Server computed fields. Sending them back is rejected or ignored depending on the field, so
    /// they come off before every write.
    private static let computedFields = [
        "nextTimestamp", "startTimestamp", "endTimestamp", "dismissedUntil", "snoozedUntil",
    ]

    /// Author an alarm OneAlarm owns: its time, its days, its on switch. Nothing else, ever.
    ///
    /// Alex's goal, 2026-08-16: *"OneAlarm is my one single source of truth for alarm setting...
    /// only the modifications of temperature, vibration etc should be done in the respective app."*
    /// That sentence is the whole specification for this function. Three fields are the schedule and
    /// belong to OneAlarm. Everything else on the object is his, is read from the server, and is
    /// handed straight back untouched, including every field with no known meaning.
    ///
    /// **Days are written again, and that is a reversal.** Four hours earlier this function wrote
    /// only `time`, because writing days is what turned a real Monday to Friday schedule into every
    /// day. That ban was correct at the time and it was never about days being sacred: it was about
    /// writing them to an alarm nobody had established was ours. One hand-picked alarm had to serve
    /// two routines, so every turn of the week reshaped it. With `RemoteAlarmLink` recording the
    /// owner, exactly one routine reaches each alarm and the ambiguity that made it destructive is
    /// gone. Without a recorded link this must never be called: see `write`, which only reaches here
    /// for a pair.
    ///
    /// **The on switch follows the routine**, which is also a reversal, and it has a visible cost:
    /// switch a OneAlarm-owned alarm off inside the Eight Sleep app and the next sync switches it
    /// back on. That is what a single source of truth means, and it is the right way round now that
    /// each routine carries its own switch in OneAlarm. Turn the routine off there instead.
    ///
    /// Internal rather than private so the test suite can assert that unknown fields survive.
    static func author(
        _ alarm: [String: Any],
        time: WallClockTime,
        days: Set<Locale.Weekday>,
        enabled: Bool,
        comfort: Comfort = .unchanged
    ) -> [String: Any] {
        // **Temperature, vibration and smart wake, when he has set them on the routine.**
        //
        // Defaulted to `.unchanged`, which touches nothing, so every existing caller and every
        // routine he has never edited writes precisely what it wrote before. `Comfort.apply` only
        // ever changes a key the server itself just sent and never introduces one, which is what
        // keeps this clear of the field name contradiction that made the area dangerous.
        var payload = Comfort.apply(comfort, to: alarm)
        for field in computedFields {
            payload.removeValue(forKey: field)
        }

        payload["time"] = time.hhmmss
        payload["enabled"] = enabled

        // Seven lowercase named booleans, not a bitmask and not an array. All seven are always
        // named: sending only the true ones leaves the others at whatever they were, which is a
        // merge, and this API replaces rather than merges.
        var weekDays: [String: Bool] = [:]
        for day in Locale.Weekday.displayOrder {
            weekDays[day.eightSleepKey] = days.contains(day)
        }
        var repeatBlock = (payload["repeat"] as? [String: Any]) ?? [:]
        repeatBlock["enabled"] = !days.isEmpty
        repeatBlock["weekDays"] = weekDays
        payload["repeat"] = repeatBlock

        return payload
    }

    /// Switch an owned alarm off without touching anything else about it.
    ///
    /// For an alarm whose routine has been deleted in OneAlarm. It is switched off rather than
    /// deleted because this app deletes only alarms it created itself, which this is not, and because
    /// off is something he can undo in the Eight Sleep app in one tap. Leaving it alone is not an
    /// option: an abandoned alarm goes on firing on a morning he deleted the routine for.
    /// Skip the next occurrence, using Eight Sleep's own field, leaving the weekly alarm switched on.
    ///
    /// **`E11`, and it is the half of the one-off problem that can be fixed from what his account
    /// already returns.** Every raw dump he has sent carries `skipNext = 0` and
    /// `skippedUntil = 1970-01-01T00:00:00Z`. That pair is a native skip, sitting in the object,
    /// unused, while OneAlarm expresses a skip as `enabled: false` on the recurring alarm and repairs
    /// it on the next sync.
    ///
    /// Same shape of mistake as the bend, and the same cost: OneAlarm edits his real weekly alarm to
    /// express something about one morning, and if the repair never runs, his week stays switched
    /// off. On 17 August he watched the bend version of this move his whole Monday to Friday series.
    ///
    /// **Why this is safe to try when reasoning about a field name is normally banned here.** It is
    /// not being reasoned about, it is being **checked against an absolute instant**, which is this
    /// project's own standard for the one thing a 200 cannot tell you. `nextTimestamp` says when the
    /// alarm next fires. If `skipNext` does what its name says, that instant moves past the morning
    /// being skipped. If it does not move, the write did nothing and the caller falls back to
    /// `enabled: false`, exactly as before. A wrong guess costs one request and changes nothing.
    ///
    /// `skippedUntil` is echoed rather than authored. The server issues it, and the difference
    /// between "I am telling you to skip" and "I am telling you until when" is the difference between
    /// a request and a guess.
    static func skipNextOccurrence(_ alarm: [String: Any]) -> [String: Any] {
        var payload = alarm
        for field in computedFields { payload.removeValue(forKey: field) }
        payload["skipNext"] = true
        return payload
    }

    /// Whether an alarm's next firing has moved past a morning, which is how a skip is confirmed.
    ///
    /// Compares two absolute instants and nothing else. Deliberately not "did `skipNext` come back as
    /// 1": a server that stores a field it does not act on would pass that check and let him sleep
    /// through a morning he thought was handled.
    static func skipTookEffect(before: [String: Any], after: [String: Any]) -> Bool {
        guard let wasText = before["nextTimestamp"] as? String,
              let nowText = after["nextTimestamp"] as? String,
              let was = ISO8601DateFormatter.parseFlexible(wasText),
              let now = ISO8601DateFormatter.parseFlexible(nowText)
        else { return false }
        // Strictly later. Equal means the server took the field and did nothing with it, which is
        // the outcome that must NOT read as success: he would think a morning was handled and be
        // woken by it. The same parser `verify` uses, because two readers of one field is how a
        // check and a write end up disagreeing about what the server said.
        return now > was
    }

    /// The useful half of an `agreementLine`, or `nil` when it does not report an override.
    ///
    /// **The summary named the alarm and not the fact.** On 18 August Alex's panel read
    /// `OVERRIDDEN: 07:45, weekdays · vibration 100, enabled=1, skipNext=0`, which says an override is
    /// in force and not what it is. The one number he needs, what it is firing at instead, was three
    /// lines further down inside a block he has to expand.
    ///
    /// `agreementLine` already computes it. This is only the trimming, kept here rather than in the
    /// view so it can be tested, because a string transform in a SwiftUI property is a string
    /// transform nobody ever runs.
    static func overrideDetail(_ line: String) -> String? {
        guard line.contains("SOMETHING is overriding") else { return nil }
        return line
            .replacingOccurrences(of: "OVERRIDE CHECK: ", with: "")
            .replacingOccurrences(of: ", so SOMETHING is overriding it", with: "")
    }

    /// Whether this alarm's **next** firing falls on a given day, according to the server.
    ///
    /// Against `nextTimestamp`, the absolute instant Eight Sleep issues, rather than against the day
    /// set and a calendar of our own. Same reason `skipTookEffect` reads it: the server already knows
    /// when this alarm next rings, including whatever it does about skips and overrides, and a second
    /// opinion computed here is a second thing that can be wrong.
    ///
    /// Used to decide whether a one day override's morning is close enough to suppress the weekly
    /// alarm for. `skipNext` skips the **next** occurrence and nothing else, so asking for it while
    /// the override is still three days out would silence the wrong morning.
    static func fires(_ alarm: [String: Any], on day: CalendarDay, in calendar: Calendar = .current) -> Bool {
        guard let text = alarm["nextTimestamp"] as? String,
              let instant = ISO8601DateFormatter.parseFlexible(text)
        else { return false }
        return CalendarDay(instant, in: calendar) == day
    }

    /// Did the one time change land, and did it leave the rest of the week alone?
    ///
    /// **The app answers this, not Alex.** Three times in a row he was asked for a raw block from the
    /// Eight Sleep app and three times the wrong one came back, not because he misread it but because
    /// following the instruction meant parsing sixteen fields across four blocks. The fix that worked
    /// last time was to compute the answer and print one line, and this is the same move for the one
    /// time change: everything needed is already in a list this app just read.
    ///
    /// Two independent facts, because they fail separately and mean different things:
    ///
    /// - the routine's own alarm still carries the **routine's** time. If it carries the override's,
    ///   the whole week moved and the bug is back.
    /// - an alarm exists for the one weekday at the override time. If it does not, the override never
    ///   reached the bed whatever the create said.
    ///
    /// Pure, so a test can hold every combination without a server. Compared on `HH:mm`, because the
    /// account returns `"06:20:00"` in some places and `"06:20"` in others and the seconds have never
    /// carried meaning here.
    static func oneOffVerdict(
        alarms: [[String: Any]],
        routineAlarmID: String,
        routineTime: WallClockTime,
        overrideTime: WallClockTime,
        weekday: Locale.Weekday
    ) -> String {
        func clock(_ alarm: [String: Any]) -> String {
            (alarm["time"] as? String).map { String($0.prefix(5)) } ?? ""
        }
        let routineAlarm = alarms.first { alarmID($0) == routineAlarmID }
        let weeklyIntact = routineAlarm.map { clock($0) == routineTime.hhmm } ?? false
        let weeklyMoved = routineAlarm.map { clock($0) == overrideTime.hhmm } ?? false
        // **A one-shot has no days at all, and that is what success looks like now.**
        //
        // This asked for `weekdays(of:) == [weekday]`, which was right while the override was a
        // single day repeating alarm. Eight Sleep's own one-off carries no `repeat` block, so
        // `weekdays(of:)` is empty, and the check would have called a perfect write "did not land"
        // the moment the one-shot rung started being tried first.
        //
        // Empty is accepted only for an alarm at exactly the override time, so an unrelated alarm
        // with no days cannot satisfy it.
        let overrideLanded = alarms.contains { candidate in
            guard alarmID(candidate) != routineAlarmID, clock(candidate) == overrideTime.hhmm
            else { return false }
            let days = weekdays(of: candidate)
            return days == [weekday] || days.isEmpty
        }

        let day = weekday.shortLabel
        switch (weeklyIntact, overrideLanded) {
        case (true, true):
            return "ONE TIME CHECK: your bed has a \(day) \(overrideTime.hhmm) alarm and your routine still says \(routineTime.hhmm). This worked."
        case (true, false):
            return "ONE TIME CHECK: your routine is safe at \(routineTime.hhmm), but no \(day) \(overrideTime.hhmm) alarm is on your bed. The one time change did not land."
        case (false, _) where weeklyMoved:
            // The exact failure this whole change exists to prevent, named in the words he used for
            // it, so there is nothing to interpret.
            return "ONE TIME CHECK: your routine's alarm now reads \(overrideTime.hhmm). The one time change moved the whole series, which is the bug. Send me this line."
        default:
            return "ONE TIME CHECK: cannot tell. Your routine's alarm is not reading back as \(routineTime.hhmm) or \(overrideTime.hhmm)."
        }
    }

    /// What his bed will actually do on each of the seven mornings, against what OneAlarm intends.
    ///
    /// **Alex's own diagnosis of the last weakness, 18 August:** *"if you set it up this way to match
    /// the actual settings in the apps, then it usually works because then it gets the right data.
    /// The problem is when something changes, if one alarm would change the entire thing then it
    /// usually doesn't work."*
    ///
    /// He is describing a system that reconciles correctly from a matched starting state and has no
    /// way to notice when a change has broken the match. Every failure on this leg has that shape:
    /// merging two routines orphaned both alarms and left them ringing; changing a routine's days
    /// stranded the alarm that had served it; a refused create left a morning with nothing on it. In
    /// every case the sync reported what it **did**, which was correct, and nobody was told what the
    /// week now looks like, which was the thing that had gone wrong.
    ///
    /// So this asks the only question that matters at the end of a sync, once per morning: **will
    /// this bed wake him, and at the time he asked for?** Answered against the account as read back,
    /// not against intent.
    ///
    /// **One finding, deliberately.** A morning a routine covers, with no enabled alarm on the bed
    /// that rings on it. That is the dangerous direction, and the only failure on this leg whose next
    /// symptom is him not waking up.
    ///
    /// The first version also reported alarms ringing at a time nothing asked for, and that was cut
    /// before it shipped: the stranded-alarm line four lines below already says it, by alarm rather
    /// than by day, and more usefully, because it names what to do about it. Two sentences about one
    /// alarm in two vocabularies is how a row stops being read. The loud direction is covered; the
    /// silent one was not covered anywhere.
    ///
    /// Override times still count as intended, because the one day alarm this adapter creates is
    /// real coverage for that morning and a week check that ignored it would be wrong about the one
    /// day the app is most likely to be asked about.
    ///
    /// Returns an empty array when the week is whole, and the caller says nothing at all.
    static func weekFindings(
        alarms: [[String: Any]],
        entries: [RoutinePlan.Entry],
        overrides: [RoutinePlan.Entry] = [],
        knownOneOffIDs: Set<String> = []
    ) -> [String] {
        // Hidden alarms are not coverage. Two are on his real account, both enabled and both
        // ringing, and counting one would report a genuinely silent morning as fine on the strength
        // of an alarm he can neither see nor switch off.
        let live = alarms.filter { ($0["enabled"] as? Bool) != false && isVisibleToHim($0) }

        // **An alarm with no day flags may still ring, so no morning can honestly be called silent
        // while one is on the account.**
        //
        // An alarm created inside a routine through `alarmsToCreate` takes its days from the
        // **routine**, so its own `repeat.weekDays` comes back with every flag false. That is
        // documented a few hundred lines above, where it caused a create loop for exactly the same
        // reason: an empty day set matches no routine.
        //
        // Without this, the first alarm OneAlarm creates inside a routine makes the week check
        // report every morning that routine covers as one he will not be woken on. That warning goes
        // into `highlights`, which means the Good night screen, which means the loudest false alarm
        // this app is capable of, on a setup that is working.
        //
        // Caught by `testAFullySuccessfulRunIsNotFlaggedAsPartial`, a test written for something else
        // three days earlier. Its fixture models exactly this alarm.
        //
        // Silence rather than a guess, which is this project's rule about absence: not knowing which
        // mornings an alarm covers is not the same as knowing it covers none.
        //
        // **An override we made ourselves is excluded from that guard.** Eight Sleep's own one-off
        // carries no `repeat`, so from 18 August every armed override puts an empty-day alarm on the
        // account, and without this the week check would fall silent on exactly the syncs where a one
        // time change is being tested. We know which morning our own one-off covers, because we
        // asked for it. The doubt only applies to an empty-day alarm we cannot account for.
        //
        // **Silence became a hiding place the moment one-shots arrived, so it now names what it
        // cannot account for.** Returning nothing was right when a day-less alarm meant "created
        // inside a routine", a rare and benign case. From 18 August a day-less alarm is also what a
        // failed one-off recovery leaves behind: the create succeeded, the id could not be
        // determined, so there is no link. Such an alarm is invisible to **everything** else, since
        // the orphan sweep works from links and `alarmsWithNoRoutine` deliberately skips day-less
        // alarms. It would ring at the override time and nothing would ever mention it again.
        //
        // Before tonight the fallback created a single **day** alarm, which at least appeared in the
        // stray list. Making the one-shot the first rung removed that safety net, so this replaces
        // it. Still not a coverage claim, which would be a guess: it reports the alarm and says the
        // rest of the check is off.
        let unaccounted = live.filter { alarm in
            guard weekdays(of: alarm).isEmpty else { return false }
            guard let id = alarmID(alarm) else { return true }
            return !knownOneOffIDs.contains(id)
        }
        if !unaccounted.isEmpty {
            return unaccounted.map { alarm in
                "There is a \(shortLabel(alarm)) alarm on your bed with no days set, and OneAlarm cannot tell which mornings it covers. It will ring and nothing here manages it. Check it in the Eight Sleep app. The rest of the week check is switched off while it is there."
            }
        }

        var findings: [String] = []
        for day in Locale.Weekday.displayOrder {
            let covering = entries.filter { $0.isOn && $0.weekdays.contains(day) }

            // **A skipped morning is not a broken one, and this check would call it one.**
            //
            // The skip's fallback path switches the weekly alarm off, so a morning he deliberately
            // cleared would be reported as one he will not wake up on. He cleared it on purpose,
            // and it is already named elsewhere on this row.
            if covering.contains(where: \.isSkippedNextMorning) { continue }

            // Whether OneAlarm expects to wake him at all on this morning. `isOn` rather than
            // `shouldBeEnabled`, because this asks what the week is supposed to look like, not what
            // is armed tonight.
            //
            // A morning no routine covers is a morning off, and an alarm on it is his business. It is
            // not judged here at all.
            let expected = !covering.isEmpty
                || overrides.contains { $0.overrideDay?.weekday == day && $0.bentTo != nil }
            guard expected else { continue }

            let ringing = live.contains { weekdays(of: $0).contains(day) }
            if !ringing {
                findings.append("Nothing on your bed rings on \(day.shortLabel), and a routine covers it. You will not be woken.")
            }
        }
        return findings
    }

    static func silence(_ alarm: [String: Any]) -> [String: Any] {
        var payload = alarm
        for field in computedFields { payload.removeValue(forKey: field) }
        payload["enabled"] = false
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
    /// `tags` is **stripped**, and getting that backwards is what caused the whole failure.
    ///
    /// **E14, answered on Alex's account 17 August, in the opposite direction from the prediction.**
    /// This function used to keep `tags`, reasoning that it carried a `routine-<uuid>` and that
    /// copying it would put the new alarm where their app could see it. Both halves were wrong.
    ///
    /// Careful with the claim, because the record contradicts a loose version of it. One alarm on his
    /// account **did** carry `routine-94b49169-...` on 16 August, and it no longer exists. Routine
    /// tags are real here. What is not real is the idea that one is required to be visible:
    ///
    /// | time | days | `tags` | in the Eight Sleep app |
    /// |---|---|---|---|
    /// | 05:57 | weekdays | `()` | **yes**, and he made it by hand in their app |
    /// | 05:55 | weekdays | `temporary-mode`, `oneOff-napMode` | no |
    /// | 09:56 | Sa Su | `temporary-mode`, `oneOff-napMode` | no |
    ///
    /// The alarm their app shows today has **no tags at all**. The two it hides are the two OneAlarm
    /// created, and
    /// both carry a nap tag. Their app does not list nap timers under Alarms, which is reasonable of
    /// it. So keeping `tags` was not neutral: it copied a "this is a nap" marker onto a real alarm
    /// and made it invisible, then every later clone inherited the marker from the clone before it.
    /// One ghost became two by exactly this route.
    ///
    /// Stripping is also the more conservative act, which is worth saying because this adapter's
    /// standing rule is to echo what it does not understand. `tags` is server bookkeeping, not a
    /// setting of Alex's. Nothing he chose lives there. Vibration, thermal and audio are his and are
    /// still echoed untouched.
    ///
    /// The `no tags` rung of `cloneVariants` is now the same payload as the full clone. That is left
    /// in place deliberately rather than tidied away, because the ladder's job is to survive a
    /// refusal, and collapsing two rungs into one is a change to make when something is known, not
    /// while the create is being tested again.
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

        // See the note above. This one line is the difference between an alarm he can see in the
        // Eight Sleep app and an alarm only this screen knows about.
        payload.removeValue(forKey: "tags")

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

    /// A genuine single occurrence alarm: **no `repeat` block at all**.
    ///
    /// **This is Eight Sleep's own one-off mechanism, and it is now confirmed by two independent
    /// sources**, which is this project's bar for treating something as a capture rather than a
    /// guess:
    ///
    /// 1. `docs/RESEARCH.md` 1.5, from the older reference library: *"Omitting `repeat` entirely is
    ///    what makes it one-off."* That sat in this repo unused since the first day.
    /// 2. `lukas-clarke/eight_sleep`, the maintained Home Assistant integration, read at source on
    ///    18 August. It has a function called `set_one_off_alarm` which POSTs to
    ///    `v1/users/{id}/alarms` with exactly `time`, `enabled`, `vibration` and `thermal`, and
    ///    **no `repeat`**. The same file's alarm reader carries the comment *"not just
    ///    recommendedAlarm, which may skip one-off alarms"*, so one-offs are first class entries in
    ///    the alarm list.
    ///
    /// **What this replaces.** Until 18 August the override was a single day **repeating** alarm,
    /// which is why it needed a synthetic ownership key, a link, and an explicit delete the morning
    /// after. A true one-shot fires once. Most of that machinery becomes unnecessary if this rung is
    /// accepted, which is why it goes first.
    ///
    /// **His settings still ride along.** `vibration` and `thermal` are copied from a template alarm
    /// rather than composed, because the reference documentation contradicts itself about those field
    /// names thirty lines apart and a guess there ends up in the bed's temperature. Only `time` and
    /// `enabled` are authored.
    ///
    /// `tags` is deliberately absent. It is absent from the integration's payload too, and copying it
    /// is what made a fortnight of alarms invisible.
    static func oneShot(like template: [String: Any], at time: WallClockTime) -> [String: Any] {
        var payload: [String: Any] = [
            "time": time.hhmmss,
            "enabled": true,
        ]
        // Echoed, never authored. Absent from the template means absent here: sending a composed
        // default would be choosing a vibration strength on his behalf.
        for field in ["vibration", "thermal", "audio"] {
            if let value = template[field] { payload[field] = value }
        }
        return payload
    }

    /// The create payload, in the order worth trying, each one differing from the last by **one**
    /// thing.
    ///
    /// This is the ladder that solved the Whoop write, reused because the situation is identical: a
    /// create is being refused, the refusal is opaque, and reasoning about which field is at fault
    /// has already been wrong repeatedly. Send the fullest honest shape first, and on a refusal drop
    /// exactly one class of field and try again, reporting which rung was accepted so it can be
    /// pinned later and the ladder deleted.
    ///
    /// The rungs, and the single question each one asks:
    ///
    /// 1. **The full clone.** Every field the server gave us. Asks: does a create accept the same
    ///    object shape a read returns?
    /// 2. **Without `tags`.** `tags` holds a `routine-<uuid>` belonging to the alarm we copied. If
    ///    their server treats that as a claim on another routine's slot, it is the field that
    ///    refuses. This is `E14` and it is the rung most likely to be the answer.
    /// 3. **Schedule and comfort only.** Everything but `time`, `enabled`, `repeat`, `vibration`,
    ///    `thermal` and `audio` dropped, including fields with no known meaning. Asks: is some other
    ///    echoed field the problem? Last rung because it is the one that discards the most, and
    ///    discarding is how a create ends up with settings he did not choose.
    ///
    /// Ordered so the first accepted rung is also the most faithful copy of his own alarm.
    static func cloneVariants(
        _ template: [String: Any],
        days: Set<Locale.Weekday>,
        time: WallClockTime
    ) -> [(name: String, payload: [String: Any])] {
        let full = clone(template, days: days, time: time)

        var untagged = full
        untagged.removeValue(forKey: "tags")

        let keep: Set<String> = ["time", "enabled", "repeat", "vibration", "thermal", "audio"]
        let minimal = untagged.filter { keep.contains($0.key) }

        return [("full", full), ("no tags", untagged), ("schedule only", minimal)]
    }

    /// The create ladder for a **one day override**, one-shot first.
    ///
    /// Separate from `cloneVariants`, which builds a recurring alarm for a routine. The two have
    /// different best-first answers and folding them together would put the wrong rung first for one
    /// of them.
    ///
    /// Rung 1 is the evidence-backed one: a genuine single occurrence with no `repeat`, matching what
    /// Eight Sleep's own client does. Rungs 2 and 3 are the single day repeating alarm this app
    /// shipped on 18 August, kept as a fallback because it is built from a create that is confirmed
    /// working on this account, where the one-shot is confirmed only in someone else's code.
    static func oneOffVariants(
        _ template: [String: Any],
        day: Locale.Weekday,
        time: WallClockTime
    ) -> [(name: String, payload: [String: Any])] {
        [("one-shot, no repeat", oneShot(like: template, at: time))]
            + cloneVariants(template, days: [day], time: time)
    }

    /// Tags Eight Sleep's own app uses to mean "this is not one of your alarms".
    ///
    /// Read off Alex's account rather than a write-up: the alarm their app lists carries no tags, and
    /// the two it hides both carry these. Named as a set rather than matched loosely, because a
    /// substring test on `tags` would eventually hide a real alarm and a hidden real alarm is a
    /// missed morning.
    static let hiddenTags: Set<String> = ["temporary-mode", "oneOff-napMode"]

    /// Every tagged, hidden alarm on the account, as "09:56 Sa Su".
    ///
    /// **For `E26`, which is the best explanation yet of what `UPCOMING ALARM ONLY` actually is.**
    /// Alex's dump of 18 August carries thirteen keys and no override field anywhere, the fourth in a
    /// row to do so. But two alarms on his account are tagged `temporary-mode` and `oneOff-napMode`,
    /// and `clone` copies a template's tags, so those tags had to come from an alarm of **his**
    /// before OneAlarm ever ran. Eight Sleep tags alarms that way, and one of those words is
    /// literally `oneOff`.
    ///
    /// If their one-off is a separate tagged alarm rather than a field, then setting
    /// `UPCOMING ALARM ONLY` in their app makes a new hidden alarm appear at the override time, and
    /// that is visible with no field hunting at all. Putting these on the panel turns the test into
    /// one glance instead of a scroll through four blocks.
    static func hiddenAlarmLabels(_ alarms: [[String: Any]]) -> [String] {
        alarms.filter { !isVisibleToHim($0) }.map(shortLabel)
    }

    /// Whether Eight Sleep's app will show this alarm to Alex.
    ///
    /// An alarm he cannot see is one he cannot check, cannot change and cannot switch off. OneAlarm
    /// treating one as its own means his week is bound to something invisible, and the first symptom
    /// is a morning that rings at the wrong time with nothing on any screen explaining why.
    static func isVisibleToHim(_ alarm: [String: Any]) -> Bool {
        guard let tags = alarm["tags"] as? [Any] else { return true }
        return !tags.contains { hiddenTags.contains(($0 as? String) ?? "") }
    }

    // MARK: Clearing up after ourselves

    /// The mess OneAlarm made before 17 August, ready to be shown to Alex before anything happens.
    ///
    /// Pure read. Two alarms on his account carry `oneOff-napMode`, ring, and are invisible in the
    /// Eight Sleep app, so there is nothing there for him to switch off and OneAlarm cannot prove it
    /// created these two, which is the only thing that ever licenses a delete on
    /// any service by design. Switching them off is the only remedy that exists, and he asked for it
    /// on 17 August: *"yes"*.
    ///
    /// **Two filters, and the second one is the one that matters.**
    ///
    /// Hidden, obviously. And **recurring**: it must have days. A nap timer Alex starts himself from
    /// the Nap tool in the Eight Sleep app would carry the same tags, and switching off something he
    /// just set going would be exactly the "never silently change a setting Alex chose" failure this
    /// project already has a rule about. A real nap is a one-off and carries no day set; both of the
    /// alarms this is for carry weekdays and Sa Su respectively.
    ///
    /// Already-off ones are excluded too, so running it twice is not a second write.
    func retiredAlarms() async throws -> [RemoteAlarmChoice] {
        try await availableAlarms().filter {
            $0.isHidden && !$0.weekdays.isEmpty && $0.isEnabled
        }
    }

    /// Switch off specific alarms by id, and report each one by name.
    ///
    /// **Off, not deleted, because this alarm is his.** Deleting exists as of 17 August but reaches
    /// only alarms `RemoteAlarmLink.created` records OneAlarm posting. Adoption is not authorship.
    /// An alarm switched off keeps its time, its days, its temperature and its vibration, so this is
    /// reversible by anybody who can see it, which for these particular alarms means the API rather
    /// than his app. That asymmetry is why he is asked first rather than told after.
    ///
    /// Takes ids rather than re-deriving the list, so what he confirmed on screen is exactly what is
    /// written. Re-reading here would let the account change between the dialog and the write, and
    /// "it switched off something I did not see" is the one outcome worth engineering against.
    /// Delete the tagged alarms his own app will not show him. **The one deliberate exception to
    /// provenance**, authorised by Alex on 19 August.
    ///
    /// The standing rule is that only an id in `RemoteAlarmLink.created` may ever be deleted, and
    /// these two predate that list, so OneAlarm cannot prove it made them. It plainly did: they carry
    /// `oneOff-napMode`, they sit at a routine time minus this device's ten minute lead, and the tags
    /// bug that produced them is documented and fixed.
    ///
    /// Alex, 19 August, after switching them off: *"I do see the old artifacts, the alarms, but I
    /// cannot delete them. So if they poison everything, then we should delete them from the system,
    /// and you should do it."* He cannot remove them himself, because the Eight Sleep app does not
    /// list a tagged alarm. Leaving litter on his bed that only this app can see, and then refusing
    /// to clear it, is the app protecting a rule instead of the person the rule is for.
    ///
    /// **What keeps the exception narrow**, and it is three things, all re-checked here against a
    /// fresh read rather than trusted from the screen that offered the button:
    ///
    /// 1. hidden by a nap tag, so it is invisible in his app and cannot be one he manages there
    /// 2. **already switched off**, so it is doing nothing and he has already seen and approved it
    ///    once through the silence flow
    /// 3. named in a confirmation he tapped, one row per alarm
    ///
    /// Anything failing any of those is skipped and says so. This never widens to "delete what
    /// OneAlarm thinks is stale": an alarm he can see in his own app is his to delete in his own app.
    func deleteRetiredAlarms(_ ids: [String]) async throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let (token, user) = try await currentToken()
        let alarms = try await fetchAlarms()

        var done: [String] = []
        for id in ids {
            guard let existing = alarms.first(where: { Self.alarmID($0) == id }) else {
                done.append("\(id) was already gone")
                continue
            }
            guard Self.isVisibleToHim(existing) == false else {
                done.append("\(Self.shortLabel(existing)) was left alone, you can see that one in the Eight Sleep app")
                continue
            }
            // Switched off first, always. A ringing alarm gets silenced and looked at, not deleted in
            // the same breath, and this is the check that keeps the exception from widening.
            guard (existing["enabled"] as? Bool) == false || (existing["enabled"] as? Int) == 0 else {
                done.append("\(Self.shortLabel(existing)) is still on, so it was switched off rather than deleted. Press this again to remove it.")
                continue
            }
            guard let url = URL(string: "\(Self.appHost)/v1/users/\(user)/alarms/\(id)") else { continue }

            let response = try await http.send("DELETE", url, headers: Self.baseHeaders(token: token))

            if response.status == 403 { throw AdapterError.subscriptionRequired }
            if response.status == 429 {
                backOff()
                throw AdapterError.rateLimited
            }
            if response.status == 401 {
                accessToken = nil
                throw AdapterError.authenticationFailed("Token was rejected.")
            }
            // 404 counts, because the outcome he wanted is the outcome he has.
            guard response.isSuccess || response.status == 404 else {
                // **This is `E20`'s answer arriving through a different door.** The delete endpoint
                // is a convention rather than a capture, so its status is reported rather than
                // swallowed, and the alarm stays off, which is where it already was.
                done.append("\(Self.shortLabel(existing)) could not be deleted (HTTP \(response.status): \(Self.serverMessage(response.data))). It is still switched off.")
                continue
            }
            RemoteAlarmLink.forgetCreated(id, on: .eightSleep)
            done.append("\(Self.shortLabel(existing)) is deleted")
        }
        return done
    }

    func silenceAlarms(_ ids: [String]) async throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let (token, user) = try await currentToken()
        let alarms = try await fetchAlarms()

        var done: [String] = []
        for id in ids {
            guard let existing = alarms.first(where: { Self.alarmID($0) == id }) else {
                // Gone since he looked. Not an error: the outcome he wanted is the outcome he has.
                done.append("\(id) was already gone")
                continue
            }
            // Re-checked against the object rather than trusted from the screen. The id came from a
            // dialog and a dialog is not evidence about what is on the account now.
            guard Self.isVisibleToHim(existing) == false, !Self.weekdays(of: existing).isEmpty else {
                done.append("\(Self.shortLabel(existing)) was left alone, it is not one of these")
                continue
            }
            guard let url = URL(string: "\(Self.appHost)/v1/users/\(user)/alarms/\(id)") else { continue }

            let body = try HTTPClient.json(Self.silence(existing))
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
                done.append("\(Self.shortLabel(existing)) could not be switched off (HTTP \(response.status))")
                continue
            }
            done.append("\(Self.shortLabel(existing)) is off")
        }
        return done
    }

    /// Which existing alarm to copy settings from.
    ///
    /// Prefers one he can actually see, then one that can actually fire. An inert alarm, no days and
    /// switched off, is the one Eight Sleep's own app hides, and copying its settings would clone
    /// whatever state made it inert. Falls back to any alarm, because a template from his account
    /// always beats a payload composed here.
    ///
    /// **Visibility comes first, and that ordering is the fix for a loop.** Before 17 August this
    /// took the first alarm that could fire, which on his account was a nap-tagged one OneAlarm had
    /// created earlier. Cloning it copied the nap tag onto the next alarm, which then became the
    /// template for the one after. Two invisible alarms by that route, and it would have kept going
    /// to the account's cap of eight. Stripping `tags` in `clone` breaks the loop on its own; this
    /// makes the template a real alarm of his as well, so the vibration and thermal settings being
    /// copied are the ones he actually chose.
    static func template(from alarms: [[String: Any]]) -> [String: Any]? {
        let visible = alarms.filter(isVisibleToHim)
        return visible.first { !weekdays(of: $0).isEmpty && ($0["enabled"] as? Bool) != false }
            ?? visible.first { !weekdays(of: $0).isEmpty }
            ?? visible.first
            ?? alarms.first { !weekdays(of: $0).isEmpty && ($0["enabled"] as? Bool) != false }
            ?? alarms.first { !weekdays(of: $0).isEmpty }
            ?? alarms.first
    }

    nonisolated func preview(_ target: ResolvedTarget) -> WritePreview {
        preview(target, plan: RoutinePlan(device: .eightSleep, entries: [], skipsNextMorning: false))
    }

    nonisolated func preview(_ target: ResolvedTarget, plan: RoutinePlan) -> WritePreview {
        var weekDays: [String: Bool] = [:]
        for day in Locale.Weekday.displayOrder { weekDays[day.eightSleepKey] = target.weekdays.contains(day) }
        let sketch: [String: Any] = [
            "time": target.localTime.hhmmss,
            "enabled": true,
            "repeat": ["enabled": true, "weekDays": weekDays] as [String: Any],
        ]

        // **`localTime`, not `timeToWrite`.**
        //
        // `timeToWrite` returns the bent time when an override is armed, and this leg stopped writing
        // that to the routine's alarm on 18 August. So the preview said "Weekdays to 08:05" while the
        // write sent 06:05, which is a gate lying about the one thing it exists to show.
        //
        // This project has paid for that once already: the preview claimed to be built by the same
        // code as the real request, was a reconstruction, and omitted the field most likely to be
        // causing a refusal. Alex found it by opening the screen. **A gate that lies is worse than no
        // gate, because it is where you go to rule the thing out.**
        let lines: String
        if plan.entries.isEmpty {
            lines = "one PUT, setting time to \(target.localTime.hhmm)"
        } else {
            lines = plan.entries
                .map { "\($0.routineName) (\($0.weekdays.count) days) to \($0.localTime.hhmm)\($0.shouldBeEnabled ? "" : ", switched off")" }
                .joined(separator: ", ")
        }

        // The one day override is a second request and a third, and neither was mentioned here.
        let bends = plan.entries.compactMap { entry -> String? in
            guard let day = entry.overrideDay, let time = entry.bentTo else { return nil }
            return "\(day.weekday.shortLabel) \(time.hhmm)"
        }
        let overrideLine = bends.isEmpty ? "" : " Plus your one time change: a POST creating a separate single day alarm for \(bends.joined(separator: " and ")), copied from an alarm you already have, and a PUT setting `skipNext` on the routine's own alarm so it does not also ring that morning. The routine's alarm keeps its own time and all of its days. The extra alarm is deleted on the first sync after that morning."

        return WritePreview(
            device: .eightSleep,
            summary: "One PUT per routine, carrying three changed fields: `time`, `repeat.weekDays` and `enabled`. \(lines). Vibration, thermal, level, pattern and every field with no known meaning are echoed back exactly as the server gave them. A routine with no alarm on the bed gets one created, as a copy of an alarm you already have, capped at \(Self.alarmCeiling) alarms. An alarm whose routine you deleted is removed if OneAlarm made it, and switched off rather than removed if you made it. An alarm OneAlarm has never owned is not touched at all.\(overrideLine)",
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
    /// Whether the next firing lands at the weekly time, in words.
    ///
    /// **The detector that needed no new field.** `time` is the weekly wall clock. `nextTimestamp` is
    /// the absolute instant it next fires. If Eight Sleep's `UPCOMING ALARM ONLY` is in force, the
    /// alarm fires at a different moment from the one its weekly time describes, so these two must
    /// disagree, **whatever field carries the override and wherever that field lives**.
    ///
    /// Alex sent three raw dumps on 17 and 18 August hunting for the override's field name and every
    /// one came back with the same sixteen keys. That leaves two possibilities nobody could tell apart
    /// by reading them: the override was never set, or it does not live on the alarm object at all.
    /// This separates them without knowing anything about the field.
    ///
    /// Says "cannot compare" rather than guessing when either side is unreadable. A detector that
    /// reports agreement on data it could not parse is worse than none, because this panel exists to
    /// answer a question nothing else can.
    static func agreementLine(time: String, nextTimestamp: String) -> String {
        guard let instant = ISO8601DateFormatter.parseFlexible(nextTimestamp) else {
            return "OVERRIDE CHECK: cannot compare, nextTimestamp is unreadable"
        }
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else {
            return "OVERRIDE CHECK: cannot compare, time is unreadable"
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let fields = calendar.dateComponents([.hour, .minute], from: instant)
        guard let hour = fields.hour, let minute = fields.minute else {
            return "OVERRIDE CHECK: cannot compare"
        }
        let weekly = parts[0] * 60 + parts[1]
        let firing = hour * 60 + minute
        guard weekly != firing else {
            return "OVERRIDE CHECK: next firing matches the weekly time, so NO override is in force"
        }
        // Signed and wrapped across midnight, because "20 earlier" and "1420 later" are the same fact
        // and only one of them reads as one.
        var delta = firing - weekly
        if delta > 720 { delta -= 1440 }
        if delta < -720 { delta += 1440 }
        let direction = delta < 0 ? "earlier" : "later"
        let firingText = String(format: "%02d:%02d", hour, minute)
        return "OVERRIDE CHECK: next firing is \(abs(delta)) min \(direction) than the weekly time (\(firingText) against \(time)), so SOMETHING is overriding it"
    }

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

        // **Every key gets its value printed, and the curated list this replaces was a trap.**
        //
        // Until 17 August this printed values for fourteen named keys and nothing else. Every one of
        // them was a field somebody already knew to look for, which makes it a diagnostic that can
        // only ever confirm what is already believed. `CLAUDE.md` has a rule for exactly this shape,
        // "a diagnostic that only fires on failure answers nothing", and this is its twin: a
        // diagnostic that only reports fields already known answers nothing either.
        //
        // Found the moment it mattered. Alex sent a screenshot of the Eight Sleep app showing
        // **UPCOMING ALARM ONLY, 09:10, with 09:30 struck through**: a native one-off that changes the
        // next occurrence and leaves the weekly series alone. OneAlarm has no idea that exists and
        // implements a one-off by rewriting the recurring alarm's `time`, which is why bending Monday
        // moves his whole Monday to Friday series. Whatever field carries that override was never in
        // the list above, so the panel would have shown its name and hidden its value, which is the
        // one thing needed.
        //
        // Ordering is kept: `time` and `nextTimestamp` first because they settle whether a write
        // landed, then the rest alphabetically so a new field is easy to spot between two runs.
        // **Does the next firing agree with the weekly time?** Computed, printed first, and it is the
        // one line in this panel that needed no new field to exist. See `agreementLine`.
        if let clock = alarm["time"] as? String,
           let stamp = alarm["nextTimestamp"] as? String {
            lines.append(Self.agreementLine(time: clock, nextTimestamp: stamp))
        }

        let first = ["time", "nextTimestamp", "enabled"]
        for key in first where alarm[key] != nil {
            if let value = alarm[key], !(value is NSNull) { lines.append("\(key) = \(value)") }
        }
        for key in alarm.keys.sorted() where !first.contains(key) {
            guard let value = alarm[key], !(value is NSNull) else { continue }
            lines.append("\(key) = \(value)")
        }
        return lines
    }

    /// One key, because one key is now the entire diff. It used to have to name every weekday too,
    /// because the write rebuilt the whole `repeat` block; that write is gone.
    private static let previewKeys: Set<String> = Set(["time", "enabled", "repeat", "weekDays"])
        .union(Locale.Weekday.displayOrder.map(\.eightSleepKey))

    func write(_ target: ResolvedTarget) async throws -> WriteReceipt {
        // A plan with no entries. Every routine-aware caller goes through the overload; this exists
        // so the protocol stays satisfiable and so a single-target write still has one meaning.
        try await write(target, plan: RoutinePlan(device: .eightSleep, entries: [], skipsNextMorning: false))
    }

    /// Make his bed's alarms say what OneAlarm says.
    ///
    /// Alex's goal, 2026-08-16: *"OneAlarm is my one single source of truth for alarm setting...
    /// whenever I change something on the routine or one time off, it should be done in the OneAlarm
    /// app and should be written into the other apps."*
    ///
    /// Four things happen, in this order, and each one is reported by name:
    ///
    /// 1. **Owned alarms are authored.** Time, days and on switch all follow the routine. Ownership
    ///    comes from `RemoteAlarmLink`, or from an exact day set match the first time round, which
    ///    is then recorded so a later change of days cannot lose the alarm.
    /// 2. **A routine with no alarm gets one**, cloned from one he already has so no field is
    ///    composed.
    /// 3. **An alarm whose routine was deleted is switched off**, not deleted, and its link dropped.
    ///    Leaving it would leave it firing on a morning he deleted the routine for.
    /// 4. **Everything else is untouched.** An alarm OneAlarm has never owned stays his, and every
    ///    field on an owned alarm other than those three is read from the server and handed back
    ///    exactly as it came. Temperature, vibration, level and pattern are his, in their app.
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
        let planned = plan.entries.isEmpty
            ? [RoutinePlan.Entry(routineID: "target", routineName: "your alarm",
                                 weekdays: target.weekdays, localTime: target.localTime,
                                 bentTo: nil, isOn: true, isSkippedNextMorning: false)]
            : plan.entries

        // **A one day override never rides the routine's own alarm on this leg.**
        //
        // This is the fix for the thing Alex reported on 18 August: *"the one time change, even
        // though it's placed correctly on the OneAlarm app, instead of changing it for one time, it
        // changes the entire Monday to Friday routine on Eight Sleep."* He was describing exactly
        // what the code did. An Eight Sleep alarm has a weekly wall clock and a day set and no
        // per-day time, so writing the override into `time` moved every morning that routine covers,
        // and the only thing putting it back was a later sync. If the app never ran again, his whole
        // week kept the one morning's time.
        //
        // It is not narrower than it looks. A Saturday-only routine has the same defect: bending it
        // moves **every future Saturday**, not just this one.
        //
        // So the routine's alarm is written with the routine's real time, always, and the override
        // becomes its own single day alarm. Two alarms is how Eight Sleep can express "Tuesday at
        // 09:45 and the rest of the week at 07:45", and it is the shape their own app produces.
        let entries = planned.map { $0.withoutBend() }
        let bends = planned.filter { $0.bentTo != nil && $0.overrideDay != nil }

        // Alarms Eight Sleep's own app hides are not candidates for anything.
        //
        // His account has three alarms and their app lists one. The two it hides carry a nap tag,
        // and both were made by OneAlarm. Matching a routine to one of them is what produced the bed
        // screen listing "Weekdays" twice: two alarms had identical weekday sets, OneAlarm adopted
        // whichever the server happened to return first, and from then on it maintained an alarm he
        // could not see while his real one drifted two minutes away from it.
        //
        // The rule underneath: **OneAlarm may only own an alarm Alex can look at.** An invisible
        // alarm cannot be checked, changed or switched off by him, so binding his week to one means
        // the first symptom of any mistake is a morning that rings wrong with nothing on any screen
        // to explain it.
        let hiddenIDs = Set(alarms.filter { !Self.isVisibleToHim($0) }.compactMap(Self.alarmID))
        let described = alarms.compactMap { alarm -> RoutinePlan.CandidateAlarm? in
            guard let id = Self.alarmID(alarm), !hiddenIDs.contains(id) else { return nil }
            return RoutinePlan.CandidateAlarm(
                id: id,
                weekdays: Self.weekdays(of: alarm),
                isEnabled: (alarm["enabled"] as? Bool) ?? true,
                label: Self.shortLabel(alarm)
            )
        }

        // A link already pointing at one of them is dropped, so the routine falls through to a
        // visible alarm or to a create. Only for an alarm the read actually returned and showed to be
        // hidden: forgetting a link because an alarm is merely absent would turn one bad read into a
        // duplicate alarm on the next run.
        var links = RemoteAlarmLink.all(for: .eightSleep)
        for (routine, alarmID) in links where hiddenIDs.contains(alarmID) {
            RemoteAlarmLink.unlink(routine: routine, on: .eightSleep)
            links.removeValue(forKey: routine)
        }

        var report = RoutinePlan.match(entries: entries, against: described, links: links)
        let (token, user) = try await currentToken()

        // Record every adoption before anything is written. From here on this routine's alarm is
        // identified by the link rather than by its days, which is what lets the days change.
        for pair in report.pairs where pair.isAdoption {
            RemoteAlarmLink.link(routine: pair.routineID, to: pair.alarmID, on: .eightSleep)
        }

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
        // Two lists, not one, and the split decides whether the sync reports as done or as a
        // warning.
        //
        // `createNotes` is what happened, including the good news: an alarm was added inside a
        // routine and his app will show it. `createProblems` is what did not happen. Lumping them
        // together made a completely successful create report as a warning, because the success
        // message itself was evidence of a problem. Reporting success as a warning is the same class
        // of lie as reporting a failure as done, one direction further from useful.
        var createNotes: [String] = []
        // Every reason a create did not happen, in words. Silence here is what made "it does not
        // create them" impossible to diagnose: a refused POST and a branch that never ran looked
        // exactly the same on screen, which is to say they both looked like nothing.
        var createProblems: [String] = []

        if !report.routinesWithNoAlarm.isEmpty {
            guard let template = Self.template(from: alarms) else {
                throw AdapterError.noAlarmToUpdate
            }
            // Fetched once, before the loop. A create needs to know whether a routine on his bed
            // already covers these days, because adding the alarm there is the difference between
            // an alarm he can see and one only the API knows about.
            let existingRoutines = (try? await fetchRoutines()) ?? []
            // Every alarm id that existed before this run created anything, so a newly created one
            // can be told apart and linked. Without this the routine create path repeats itself on
            // every sync. See the comment where it is used.
            var knownAlarmIDs = Set(described.map(\.id))
            for entry in entries where report.routinesWithNoAlarm.contains(entry.routineName) {
                guard !entry.weekdays.isEmpty, entry.isOn else { continue }
                guard alarms.count + created.count < Self.alarmCeiling else {
                    createProblems.append("Did not create \(entry.routineName): this account is already at the \(Self.alarmCeiling) alarm limit OneAlarm will not go past.")
                    continue
                }

                // Try each shape in turn, stopping at the first the server accepts. Every rung is
                // reported, accepted or refused, so one round trip answers which field was the
                // problem instead of producing another "it still does not create them".
                var outcome: CreateOutcome = .refused("not attempted")
                var attempts: [String] = []

                // First, the routine the alarm should live in.
                //
                // A standalone POST creates an alarm that belongs to no routine, and their app
                // renders alarms through routines, so it exists on the API and shows up nowhere.
                // That is the best explanation of what Alex has been reporting for two rounds: the
                // account returned a Monday to Friday alarm at 08:55 and his app listed none.
                //
                // So when a routine on his bed already has these days, the new alarm is added to it
                // through `alarmsToCreate`, which is the field their own client uses. Only when no
                // routine matches does this fall back to the standalone POST, and it says so.
                if let host = existingRoutines.first(where: { Self.days(of: $0) == entry.weekdays }),
                   let hostID = Self.routineIdentifier(host) {
                    var payload = host
                    var pending = (payload["alarmsToCreate"] as? [[String: Any]]) ?? []
                    pending.append(Self.newRoutineAlarm(like: template, at: entry.timeToWrite))
                    payload["alarmsToCreate"] = pending
                    payload["enabled"] = entry.shouldBeEnabled

                    if let why = try await putRoutine(payload, id: hostID, token: token, user: user) {
                        attempts.append("routine \(hostID.prefix(8)): \(why)")
                    } else {
                        attempts.append("routine \(hostID.prefix(8)): accepted")
                        created.append(entry.routineName)

                        // Find the alarm that just appeared, and own it now.
                        //
                        // The first version left this to "the next sync will adopt it by its days",
                        // which is wrong and would have been expensive. An alarm created through
                        // `alarmsToCreate` takes its days from the **routine**, so its own
                        // `repeat.weekDays` may be empty. An empty day set matches no routine, so
                        // the next sync would see the same routine with no alarm and create another,
                        // and the one after that another, until `alarmCeiling` stopped it at eight.
                        // Eight unwanted alarms on his bed, from a feature that reported success
                        // every time.
                        //
                        // So the account is re-read and the id that was not there before is linked.
                        // If more than one appeared, nothing is linked: guessing which is which
                        // would put a routine in charge of an alarm it does not own.
                        let after = (try? await fetchAlarms()) ?? []
                        let fresh = after.compactMap(Self.alarmID).filter { !knownAlarmIDs.contains($0) }
                        if fresh.count == 1, let newID = fresh.first {
                            RemoteAlarmLink.link(routine: entry.routineID, to: newID, on: .eightSleep)
                            // Provenance, recorded the instant the create is confirmed and before
                            // anything else can fail. This list is the only thing that ever makes an
                            // alarm eligible for deletion. See `RemoteAlarmLink.created`.
                            RemoteAlarmLink.markCreated(newID, on: .eightSleep)
                            createdIDs.insert(newID)
                            knownAlarmIDs.insert(newID)
                            createNotes.append("Added the \(entry.routineName) alarm inside a routine that already runs on those days, so the Eight Sleep app shows it.")
                        } else {
                            // Reported rather than silently accepted, because the consequence is a
                            // duplicate next time and he is the only one who can see it.
                            createProblems.append("Added the \(entry.routineName) alarm inside its routine, but could not tell which new alarm is it (\(fresh.count) appeared). Check the Eight Sleep app before the next sync, in case it makes a second one.")
                        }
                        continue
                    }
                }

                // Shape outer, path inner, so the **full** clone is tried on both paths before any
                // field is dropped. If the path is the problem, that shows up in two requests and no
                // setting of his is discarded chasing a phantom payload error. Change one thing per
                // step, which is the rule that took six rounds to learn on the Whoop write.
                outer: for variant in Self.cloneVariants(template, days: entry.weekdays, time: entry.timeToWrite) {
                    for version in Self.createPaths {
                        outcome = try await postAlarm(variant.payload, version: version,
                                                      token: token, user: user)
                        if case .refused(let why) = outcome {
                            attempts.append("\(version) \(variant.name): \(why)")
                            continue
                        }
                        attempts.append("\(version) \(variant.name): accepted")
                        break outer
                    }
                }

                switch outcome {
                case .created(let newID):
                    created.append(entry.routineName)
                    createdIDs.insert(newID)
                    // Linked immediately. An alarm created and not recorded is one this app will
                    // fail to recognise the moment its days change, and will then create again.
                    RemoteAlarmLink.link(routine: entry.routineID, to: newID, on: .eightSleep)
                    RemoteAlarmLink.markCreated(newID, on: .eightSleep)
                    report.pairs.append(
                        AlarmMatchReport.Pair(
                            routineID: entry.routineID,
                            routineName: entry.routineName,
                            alarmID: newID,
                            time: entry.timeToWrite,
                            weekdays: entry.weekdays,
                            shouldBeEnabled: entry.shouldBeEnabled,
                            isAdoption: false
                        )
                    )
                case .createdUnknownID:
                    // The alarm is real, it just cannot be verified this run. Reported as created,
                    // because sending him looking for something that is not there is the worse lie.
                    created.append(entry.routineName)
                case .refused:
                    // Every rung, with the server's own words for each. This is the dump, and it is
                    // the only thing that can end this without another guess.
                    createProblems.append("Eight Sleep refused the new \(entry.routineName) alarm. Tried \(attempts.joined(separator: " | ")).")
                }

                // Which rung landed, when it was not the first. Worth saying out loud so the shape
                // can be pinned and this ladder deleted: the Whoop leg still sends three bodies
                // every night because nobody ever read the equivalent line.
                if attempts.count > 1, attempts.last?.hasSuffix("accepted") == true {
                    createNotes.append("\(entry.routineName) was created on attempt \(attempts.count). Ladder: \(attempts.joined(separator: " | ")).")
                }

            }
            // The create already carried the right time, so these need no follow up PUT.
            report.routinesWithNoAlarm.removeAll { created.contains($0) }
        }

        // `created` counts too. An alarm added inside a routine through `alarmsToCreate` comes back
        // with no id of its own, so it produces no pair this run, and without this clause a create
        // that worked would be thrown as "no alarm on your bed covers Weekend" one line after
        // succeeding. It is picked up by day set adoption on the next sync and linked then.
        guard !report.pairs.isEmpty || !created.isEmpty else {
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
        var verifiableID = report.pairs.first { pair in
            entries.first { $0.routineID == pair.routineID }?.weekdays.contains(nextWeekday) == true
        }?.alarmID

        // Sequential rather than concurrent. Two or three requests against a personal account stays
        // well inside a single-digit rate, and one at a time means a failure names which routine
        // failed instead of arriving as a race.
        var failures: [String] = []
        var written = Set<String>()
        // Declared before the loop that fills them, because Swift has no forward reference and the
        // first version of this put them below it. Same slip as `created` on the Whoop leg an hour
        // earlier, and the same fix.
        var skippedNatively: [String] = []
        var skipNotes: [String] = []

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

            // **A skip goes through Eight Sleep's own `skipNext`, and falls back if it does nothing.**
            //
            // `E11`. Their alarm object has carried `skipNext` and `skippedUntil` in every dump Alex
            // has sent, unused, while OneAlarm expressed a skip by switching the weekly alarm off and
            // repairing it later. Same edit-and-repair shape as the bend, and on 17 August he watched
            // the bend version move his entire Monday to Friday series.
            //
            // Checked against an absolute instant rather than a status code, which is this project's
            // own standard: if `skipNext` does what its name says, `nextTimestamp` moves past the
            // morning being skipped. If it does not move, nothing was skipped, and the old behaviour
            // runs instead. A wrong guess costs one request and changes nothing on his bed.
            let wantsSkip = !pair.shouldBeEnabled
                && entries.first { $0.routineID == pair.routineID }?.isSkippedNextMorning == true
                && (existing["enabled"] as? Bool) != false

            if wantsSkip {
                let skipBody = try HTTPClient.json(Self.skipNextOccurrence(existing))
                let attempt = try await http.send("PUT", url, headers: Self.baseHeaders(token: token), body: skipBody)
                if attempt.isSuccess {
                    let after = (try? await fetchAlarms()) ?? []
                    let reread = after.first { Self.alarmID($0) == pair.alarmID }
                    if let reread, Self.skipTookEffect(before: existing, after: reread) {
                        skippedNatively.append(pair.routineName)
                        written.insert(pair.alarmID)
                        continue
                    }
                    skipNotes.append("Eight Sleep took the skip for \(pair.routineName) and its next alarm did not move, so OneAlarm switched the alarm off for the morning instead.")
                } else {
                    skipNotes.append("Eight Sleep refused the skip for \(pair.routineName) (HTTP \(attempt.status)), so OneAlarm switched the alarm off for the morning instead.")
                }
            }

            let body = try HTTPClient.json(
                Self.author(existing, time: pair.time, days: pair.weekdays,
                            enabled: pair.shouldBeEnabled,
                            comfort: entries.first { $0.routineID == pair.routineID }?.comfort ?? .unchanged)
            )
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

        // **A one day override, written as its own single day alarm.**
        //
        // The routine's alarm has already been written above with the routine's real time, so all
        // this has to add is the one morning. Three steps, and each one reports what happened:
        //
        // 1. The override's own alarm, one weekday, at the override time. Created by cloning, like
        //    every other alarm this app makes, and recorded in `RemoteAlarmLink.created`.
        // 2. Filed under a key that behaves like a routine id and carries the date. That is what
        //    expires it: once the morning has passed the key stops being generated, the sweep at the
        //    bottom of this function finds the alarm orphaned, and deletes it. No new cleanup path.
        // 3. The routine's own alarm skipped for that morning, so the bed does not ring twice, but
        //    **only through Eight Sleep's own `skipNext` and only when that morning is genuinely the
        //    next one.**
        //
        // Step 3 does not fall back to switching the weekly alarm off, and that is deliberate. The
        // fallback used elsewhere in this file repairs itself on the next sync, and if there is no
        // next sync the cost here is a whole week with no alarm. Leaving it alone costs one morning
        // rung at 07:45 instead of 09:45. Between an alarm that rings early and an alarm that does
        // not ring, this leg picks early, every time, and says which it did.
        var oneOffNotes: [String] = []
        var oneOffKeys = Set<String>()
        // Whether the one time change he just made actually reached the bed. Reported as a partial
        // sync rather than a success, because "Set all alarms" going green while the override was
        // refused is the exact shape of lie this project keeps writing rules against.
        var oneOffFailed = false
        if !bends.isEmpty {
            // Re-read, because the loop above has just written to some of these alarms and step 3
            // compares against `nextTimestamp`, which the write moves.
            let current = (try? await fetchAlarms()) ?? alarms
            let owned = RemoteAlarmLink.all(for: .eightSleep)

            for entry in bends {
                guard let bend = entry.overrideDay, let bentTime = entry.bentTo else { continue }
                let key = bend.linkKey(routine: entry.routineID)
                // Added whatever happens below. A create that failed leaves no link and no alarm, and
                // a key with nothing behind it costs nothing; a key missing while its alarm exists
                // would have the sweep delete the override the moment it was made.
                oneOffKeys.insert(key)
                let when = "\(bend.weekday.shortLabel) \(bentTime.hhmm)"

                var overrideAlarmID: String?

                // **Whether this override is the alarm that rings next.**
                //
                // If it is, it is the only alarm on the bed whose `nextTimestamp` can be compared
                // against the instant the target describes, because the target has been bent to the
                // override's time. See where `verifiableID` is reassigned below.
                let carriesNextMorning = bend.weekday == nextWeekday

                if let existingID = owned[key],
                   let existing = current.first(where: { Self.alarmID($0) == existingID }),
                   let url = URL(string: "\(Self.appHost)/v1/users/\(user)/alarms/\(existingID)") {
                    // Already made on an earlier sync. Moved rather than remade, so changing his mind
                    // about the time does not leave two override alarms on the bed.
                    let body = try HTTPClient.json(
                        Self.author(existing, time: bentTime, days: [bend.weekday],
                                    enabled: entry.isOn, comfort: entry.comfort)
                    )
                    let response = try await http.send("PUT", url, headers: Self.baseHeaders(token: token), body: body)
                    if response.isSuccess {
                        overrideAlarmID = existingID
                        oneOffNotes.append("Set your one time \(when) alarm on your bed.")
                    } else {
                        oneOffFailed = true
                        oneOffNotes.append("Could not move your one time \(when) alarm on your bed (HTTP \(response.status)).")
                    }
                } else if let template = Self.template(from: alarms) {
                    guard current.count < Self.alarmCeiling else {
                        oneOffFailed = true
                        oneOffNotes.append("Did not add your one time \(when) alarm: this account is already at the \(Self.alarmCeiling) alarm limit OneAlarm will not go past.")
                        continue
                    }
                    var outcome: CreateOutcome = .refused("not attempted")
                    var attempts: [String] = []
                    // **Which rung landed, reported on success as well as on failure.**
                    //
                    // The ladder recorded only its refusals, so a create that worked said "added a
                    // one time alarm" and nothing about how. That throws away the single most
                    // valuable fact the first run can produce: whether Eight Sleep's own one-shot
                    // was accepted, or whether it fell back to the single day repeating alarm.
                    //
                    // Those two have different consequences. A one-shot may clear itself; the
                    // fallback definitely needs deleting. Not knowing which is on the bed means not
                    // knowing whether the cleanup matters, which is the release-blocking question.
                    var acceptedRung: String?
                    outer: for variant in Self.oneOffVariants(template, day: bend.weekday, time: bentTime) {
                        for version in Self.createPaths {
                            outcome = try await postAlarm(variant.payload, version: version,
                                                          token: token, user: user)
                            if case .refused(let why) = outcome {
                                attempts.append("\(version) \(variant.name): \(why)")
                                continue
                            }
                            acceptedRung = "\(variant.name) on \(version)"
                            break outer
                        }
                    }
                    switch outcome {
                    case .created(let newID):
                        overrideAlarmID = newID
                        RemoteAlarmLink.link(routine: key, to: newID, on: .eightSleep)
                        RemoteAlarmLink.markCreated(newID, on: .eightSleep)
                        oneOffNotes.append("Added a one time \(when) alarm to your bed for \(entry.routineName) using \(acceptedRung ?? "the create"), and it goes away by itself after that morning.")
                    case .createdUnknownID:
                        // **The alarm is real and its id is not in the response, so go and find it.**
                        //
                        // This used to give up here and tell him to delete it by hand after the
                        // morning. That is the exact chore he asked never to do again: *"I had to
                        // delete all the alarms in the eight sleep app and set all alarms again from
                        // the one alarm app."* An override alarm nobody can prove OneAlarm made can
                        // never be deleted by the sweep, so it rings every week at the override time
                        // until he notices.
                        //
                        // The routine create path a few hundred lines above already solves this: read
                        // the account back and take the id that was not there before. Exactly one new
                        // alarm, or nothing is claimed, because guessing which of two is which would
                        // put a delete licence on an alarm that might be his.
                        let after = (try? await fetchAlarms()) ?? []
                        let known = Set(current.compactMap(Self.alarmID))
                        let fresh = after.compactMap(Self.alarmID).filter { !known.contains($0) }
                        if fresh.count == 1, let newID = fresh.first {
                            overrideAlarmID = newID
                            RemoteAlarmLink.link(routine: key, to: newID, on: .eightSleep)
                            RemoteAlarmLink.markCreated(newID, on: .eightSleep)
                            oneOffNotes.append("Added a one time \(when) alarm to your bed for \(entry.routineName) using \(acceptedRung ?? "the create"), and it goes away by itself after that morning.")
                        } else {
                            // Named rather than swallowed, because this is now the only path that
                            // leaves him something to tidy by hand, and he is the only one who can
                            // see it.
                            oneOffFailed = true
                            oneOffNotes.append("Added a one time \(when) alarm to your bed, but could not tell which one it is (\(fresh.count) appeared), so it will not clear itself. Delete it in the Eight Sleep app after that morning.")
                        }
                    case .refused:
                        oneOffFailed = true
                        oneOffNotes.append("Eight Sleep refused a one time \(when) alarm, so \(entry.routineName) is unchanged and will ring at \(entry.localTime.hhmm). Tried \(attempts.joined(separator: " | ")).")
                    }
                } else {
                    oneOffFailed = true
                    oneOffNotes.append("No alarm on your bed to copy, so the one time \(when) alarm was not made.")
                }

                // **Verify against the alarm that actually rings tomorrow.**
                //
                // Until now `verifiableID` was always the **routine's** alarm, and on the morning an
                // override is armed that is the wrong one twice over: it carries the routine's time
                // while the target carries the override's, and it has just been skipped so its
                // `nextTimestamp` points a day further on. `verify` would compare a bent target
                // against a skipped alarm and raise a mismatch, which is the loudest warning this app
                // has, for a write that went perfectly.
                //
                // The row would then have read "Accepted, but it reads back as Wed 06:05 instead of
                // Tue 08:05" on exactly the test Alex was asked to run, and the `.mismatch` branch
                // does not carry highlights either, so the sentence saying it worked would have been
                // dropped as well.
                if let id = overrideAlarmID {
                    // Counted as written, because it was: created or moved successfully in this run.
                    // Without this the receipt's `written.contains` guard nils the id straight back
                    // out and `verify` reports unavailable, and the stranded check three hundred
                    // lines down would count it as an alarm nobody touched.
                    written.insert(id)
                    if carriesNextMorning { verifiableID = id }
                }

                // Step 3. Only once the override's own alarm actually exists: silencing the routine
                // and then failing to add the replacement is the one combination that ends with no
                // alarm at all on a morning he asked to be woken.
                guard overrideAlarmID != nil,
                      let pair = report.pairs.first(where: { $0.routineID == entry.routineID }),
                      let routineAlarm = current.first(where: { Self.alarmID($0) == pair.alarmID }),
                      let url = URL(string: "\(Self.appHost)/v1/users/\(user)/alarms/\(pair.alarmID)")
                else { continue }

                guard Self.fires(routineAlarm, on: bend.date) else {
                    // The override is further out than the next morning. Nothing to do yet, and
                    // saying so beats silence, because "both will ring" is a real outcome he would
                    // otherwise discover in bed.
                    oneOffNotes.append("\(entry.routineName) still rings at \(entry.localTime.hhmm) that morning too. Open OneAlarm the day before and it gets skipped.")
                    continue
                }

                let skipBody = try HTTPClient.json(Self.skipNextOccurrence(routineAlarm))
                let attempt = try await http.send("PUT", url, headers: Self.baseHeaders(token: token), body: skipBody)
                // Written out rather than folded into a ternary. A `try? await` inside a `?:` has
                // twice defeated this project's type checker for reasons no message explained.
                var reread: [String: Any]?
                if attempt.isSuccess {
                    let after = (try? await fetchAlarms()) ?? []
                    reread = after.first { Self.alarmID($0) == pair.alarmID }
                }
                if let reread, Self.skipTookEffect(before: routineAlarm, after: reread) {
                    oneOffNotes.append("Skipped \(entry.routineName) for that one morning, so only the \(bentTime.hhmm) alarm rings.")
                } else {
                    oneOffNotes.append("Could not skip \(entry.routineName) for that morning, so your bed rings at \(entry.localTime.hhmm) as well and the earlier one wins. Switch it off in the Eight Sleep app if you want only \(bentTime.hhmm).")
                }
            }

        }

        // The routine each owned alarm belongs to, brought into line.
        //
        // This is the half that was missing, and it is the half Alex asked for by name: *"be able to
        // also write routines inside the 8sleep app."* Their app models alarms **inside** routines,
        // and the routine carries the `days`. Writing `repeat.weekDays` on the alarm alone may well
        // be writing to a field their UI never reads, which would make "change Monday to Friday into
        // Monday to Wednesday" impossible through the alarm object no matter how correct the write.
        //
        // Read modify write, same as everywhere else here. Two fields are replaced, `days` and
        // `enabled`, and the entire rest of the object is echoed back, `bedtime` included: when he
        // goes to bed is not an alarm setting and is not OneAlarm's.
        //
        // Only routines that own an alarm OneAlarm owns are touched. A routine with no relationship
        // to any OneAlarm routine is never opened.
        var routineNotes: [String] = []
        if !plan.entries.isEmpty, !report.pairs.isEmpty {
            let routines = (try? await fetchRoutines()) ?? []
            // An empty list and a refused read look identical from here, and they mean opposite
            // things: "you have no routines" against "OneAlarm is calling the wrong address". The
            // second is the one that makes this whole leg do nothing while reporting success.
            if routines.isEmpty, let failure = lastRoutineReadFailure {
                routineNotes.append("Could not read your Eight Sleep routines (\(failure)), so their days were not updated. Times still were.")
            }
            for pair in report.pairs {
                guard let alarm = alarms.first(where: { Self.alarmID($0) == pair.alarmID }),
                      let routineID = Self.routineID(of: alarm),
                      let routine = routines.first(where: { Self.routineIdentifier($0) == routineID })
                else { continue }

                let current = Self.days(of: routine)
                let currentlyOn = (routine["enabled"] as? Bool) ?? true
                // Only when it actually disagrees. A PUT that changes nothing is still a write to a
                // live account, and this endpoint has never been exercised before today.
                guard current != pair.weekdays || currentlyOn != pair.shouldBeEnabled else { continue }

                let body = Self.authorRoutine(routine, days: pair.weekdays, enabled: pair.shouldBeEnabled)
                if let why = try await putRoutine(body, id: routineID, token: token, user: user) {
                    routineNotes.append("Could not update the \(pair.routineName) routine on your bed: \(why)")
                } else {
                    routineNotes.append("Set the \(pair.routineName) routine on your bed to \(pair.weekdays.count) days.")
                }
            }
        }

        // A routine deleted in OneAlarm leaves a real alarm on his bed. Clearing it is the other half
        // of being the source of truth: without this, deleting a routine here changes nothing there
        // and the bed goes on waking him on a morning he removed.
        //
        // **Two different endings, decided by who made the alarm.** Alex overruled the blanket
        // no-delete ban on 17 August, after ending up with three alarms on his bed and clearing them
        // by hand: *"the one alarm app should be able to delete alarms if there are changes."*
        //
        // - **OneAlarm created it** → deleted. It only ever existed to serve a routine that is now
        //   gone, so switching it off leaves litter he has to tidy, which is the chore he just did
        //   manually and asked never to do again.
        // - **He made it, or OneAlarm adopted it for matching days** → switched off, never deleted.
        //   Adoption means the alarm was his before OneAlarm saw it. Off is reversible in his own app
        //   in one tap; a delete is not reversible anywhere.
        //
        // The list in `RemoteAlarmLink.created` is the whole safety mechanism. Not "alarms OneAlarm
        // manages", which would include his: only ones that did not exist until OneAlarm posted them.
        var silenced: [String] = []
        var deleted: [String] = []
        var deleteProblems: [String] = []
        if !plan.entries.isEmpty {
            // One day override alarms count as living while their morning is still ahead. The moment
            // it is behind, `RulesEngine` stops emitting the override, this set stops containing its
            // key, and the sweep below deletes the alarm because OneAlarm made it. That is the whole
            // expiry mechanism, and it reuses a path that already exists rather than adding one.
            let living = Set(entries.map(\.routineID)).union(oneOffKeys)
            let ours = RemoteAlarmLink.created(for: .eightSleep)
            for (routineID, alarmID) in RemoteAlarmLink.orphans(for: .eightSleep, livingRoutines: living) {
                guard let existing = alarms.first(where: { Self.alarmID($0) == alarmID }) else {
                    // Already gone from the account, so the links are all that is left to clean up.
                    //
                    // **Silent until 19 August, and that silence hid the one open question.** When a
                    // one day override has vanished on its own, this branch is Eight Sleep telling us
                    // its one-shot self-clears, which is the whole of `E25`'s remaining unknown: if it
                    // does, the synthetic key, the link and the delete are all unnecessary. Cleaning
                    // up quietly and moving on meant the morning-after run would print nothing at all
                    // and the question would stay open after the exact test designed to close it.
                    //
                    // Only reported for an override key. A routine's alarm disappearing means he
                    // deleted it in their app, which is his business and not news.
                    if routineID.hasPrefix("oneoff:") {
                        deleted.append("the one time alarm, which Eight Sleep had already removed by itself")
                    }
                    RemoteAlarmLink.unlink(routine: routineID, on: .eightSleep)
                    RemoteAlarmLink.forgetCreated(alarmID, on: .eightSleep)
                    continue
                }
                guard let url = URL(string: "\(Self.appHost)/v1/users/\(user)/alarms/\(alarmID)") else { continue }

                if ours.contains(alarmID) {
                    // **The endpoint is the PUT path with a different verb, and that is a convention
                    // rather than a capture.** No public source documents a delete on this API and
                    // the session cannot reach the host to probe it. So a refusal is reported with
                    // its status rather than swallowed, and the alarm is switched off instead, which
                    // leaves him no worse off than before deleting existed. `E20` carries the
                    // prediction. If it turns out to be a different address, the ladder is one line.
                    let response = try await http.send("DELETE", url, headers: Self.baseHeaders(token: token))
                    if response.isSuccess || response.status == 404 {
                        deleted.append(Self.shortLabel(existing))
                        RemoteAlarmLink.unlink(routine: routineID, on: .eightSleep)
                        RemoteAlarmLink.forgetCreated(alarmID, on: .eightSleep)
                        continue
                    }
                    deleteProblems.append("Could not delete the \(Self.shortLabel(existing)) alarm OneAlarm made (HTTP \(response.status)). Switched it off instead.")
                }

                guard (existing["enabled"] as? Bool) != false else {
                    RemoteAlarmLink.unlink(routine: routineID, on: .eightSleep)
                    continue
                }
                let response = try await http.send(
                    "PUT", url, headers: Self.baseHeaders(token: token),
                    body: try HTTPClient.json(Self.silence(existing))
                )
                if response.isSuccess {
                    silenced.append(Self.shortLabel(existing))
                    RemoteAlarmLink.unlink(routine: routineID, on: .eightSleep)
                }
            }
        }

        guard failures.isEmpty || failures.count < report.pairs.count else {
            throw AdapterError.unexpectedResponse("Every routine failed to write: \(failures.joined(separator: ", ")).")
        }

        authState = .connected

        // **One read back at the very end, and the app answers the two questions he cannot.**
        //
        // Last, deliberately: after the writes, after the routines, after anything deleted or
        // switched off. Everything before this reports what OneAlarm **did**, which is a different
        // question from what is on his bed. `E14` is a fortnight of creates that all returned
        // accepted while nothing appeared in his app.
        //
        // It also ends a handoff that failed three times in two days. He was asked to open the Eight
        // Sleep app, decide which alarm is which, and say what changed. The app has the list.
        var oneOffVerdicts: [String] = []
        var weekProblems: [String] = []
        let settled = (try? await fetchAlarms()) ?? []
        if settled.isEmpty {
            // **A skipped check is not a passed check, and it gets named.**
            //
            // If this read fails, both checks below simply do not run, and their silence is
            // indistinguishable from "nothing to report". That is the shape of every diagnostic this
            // project has had to fix: `preflight` prints what it could not reach and refuses to call
            // that run green, and this is the same rule inside the app.
            //
            // Only said when there was something to check. On an ordinary sync with no override, the
            // week check having been skipped is not worth a sentence on his row.
            if !bends.isEmpty {
                oneOffVerdicts.append("Could not read your bed back afterwards, so I cannot tell you whether the one time change landed. The write itself was accepted.")
            }
        } else {
            for entry in bends {
                guard let bend = entry.overrideDay, let bentTime = entry.bentTo,
                      let pair = report.pairs.first(where: { $0.routineID == entry.routineID })
                else { continue }
                oneOffVerdicts.append(Self.oneOffVerdict(
                    alarms: settled,
                    routineAlarmID: pair.alarmID,
                    routineTime: entry.localTime,
                    overrideTime: bentTime,
                    weekday: bend.weekday
                ))
            }
            weekProblems = Self.weekFindings(
                alarms: settled, entries: entries, overrides: bends,
                // Our own override alarms. Their day set is empty by design now, and we know exactly
                // which morning each one covers.
                knownOneOffIDs: Set(oneOffKeys.compactMap { RemoteAlarmLink.alarmID(for: $0, on: .eightSleep) })
            )
        }

        var note = report.note
        if !created.isEmpty {
            // Named, and named first. Creating an alarm on a live account is the most consequential
            // thing this app does, it cannot be undone from here, and a user who did not expect it
            // needs to know which one to go and look at.
            note = "Created a new alarm on your bed for \(created.joined(separator: " and ")), copied from your existing one. " + note
        }
        if !createProblems.isEmpty {
            // A refusal is louder than a success. Nothing was created and something was meant to be.
            note = createProblems.joined(separator: " ") + " " + note
        }
        if !createNotes.isEmpty {
            note += " " + createNotes.joined(separator: " ")
        }
        if !failures.isEmpty {
            note += " Failed: \(failures.joined(separator: ", "))."
        }
        if !weekProblems.isEmpty {
            // First in the sentence, ahead of everything the sync did. A morning with no alarm on it
            // outranks every other thing this row can say, and it is the one failure whose next
            // symptom is him not waking up.
            note = weekProblems.joined(separator: " ") + " " + note
        }
        if !oneOffVerdicts.isEmpty {
            oneOffNotes.append(contentsOf: oneOffVerdicts)
        }
        if !oneOffNotes.isEmpty {
            // First after the headline, because a one time change is the thing he just did and the
            // thing this leg got wrong until 18 August. Every outcome above writes a line here,
            // including the ones where nothing happened.
            note += " " + oneOffNotes.joined(separator: " ")
        }
        if !routineNotes.isEmpty {
            note += " " + routineNotes.joined(separator: " ")
        }
        if !deleted.isEmpty {
            // Named, and named plainly. A delete cannot be undone from here or anywhere else, so it
            // is the one outcome he must never have to discover for himself.
            note += " Deleted \(deleted.joined(separator: ", ")) from your bed, because the routine that owned it is gone and OneAlarm was the one that made it. Alarms you made yourself are never deleted."
        }
        if !deleteProblems.isEmpty {
            note += " " + deleteProblems.joined(separator: " ")
        }
        // **An alarm no routine covers, still switched on, named on the row he actually reads.**
        //
        // Alex, 18 August: *"the problem is when something changes, if one alarm would change the
        // entire thing then it usually doesn't work."* This is that, made visible. Merging two
        // routines into one, or widening a routine's days, leaves the alarms they owned matching
        // nothing. OneAlarm correctly stops touching them, and they correctly keep ringing, and until
        // now the only place that was said was a panel three taps away in Connections.
        //
        // He does not go looking. He reads the row after pressing Set all alarms. So it goes there,
        // with the count, because "one" and "three" are different amounts of trouble.
        // **Everything OneAlarm owns, including the one day override's own alarm.**
        //
        // `report.pairs` only covers routines. An override's alarm is owned through a key that is not
        // a routine id, so without this it is "an alarm matching no routine that OneAlarm did not
        // touch", and he is told, every sync while the override is armed, to give it a routine or
        // delete it in the Eight Sleep app. A warning telling him to delete the thing the feature
        // just made for him.
        //
        // Read fresh rather than from the `links` captured at the top, because the one-off pass above
        // may have added one in this same run.
        let ownedNow = Set(RemoteAlarmLink.all(for: .eightSleep).values)
        let strandedAndLive = alarms.filter { candidate in
            guard let id = Self.alarmID(candidate) else { return false }
            guard !written.contains(id), !ownedNow.contains(id), Self.isVisibleToHim(candidate) else { return false }
            guard (candidate["enabled"] as? Bool) != false else { return false }
            guard !Self.weekdays(of: candidate).isEmpty else { return false }
            return !report.pairs.contains { $0.alarmID == id }
        }
        if !strandedAndLive.isEmpty {
            let names = strandedAndLive.map(Self.shortLabel).joined(separator: ", ")
            note += " \(strandedAndLive.count) alarm\(strandedAndLive.count == 1 ? "" : "s") on your bed match no routine and OneAlarm did not touch \(strandedAndLive.count == 1 ? "it" : "them"): \(names). \(strandedAndLive.count == 1 ? "It still rings" : "They still ring"). Give a routine those days to take \(strandedAndLive.count == 1 ? "it" : "them") over, or delete \(strandedAndLive.count == 1 ? "it" : "them") in the Eight Sleep app."
        }
        if !silenced.isEmpty {
            note += " Switched off \(silenced.joined(separator: ", ")) on your bed, because the routine that owned it is gone. Yours are switched off rather than deleted, so you can turn it back on in the Eight Sleep app if that was not what you wanted."
        }
        // **Two different things can have happened and he needs to know which**, because only one of
        // them leaves his weekly alarm switched on. `E11`.
        if !skippedNatively.isEmpty {
            note += " \(skippedNatively.joined(separator: " and ")) is skipped for one morning using Eight Sleep's own skip, so the weekly alarm stays on and nothing has to be put back."
        }
        if !skipNotes.isEmpty {
            note += " " + skipNotes.joined(separator: " ")
        }
        let fellBack = entries.filter { $0.isSkippedNextMorning && !skippedNatively.contains($0.routineName) }
        if let skipped = fellBack.first {
            note += " \(skipped.routineName) is switched off on your bed for one morning and comes back on the next sync."
        }

        return WriteReceipt(
            device: .eightSleep,
            succeededAt: Date(),
            // `nil` when the morning's own alarm is not among the ones that landed. `verify` then
            // reports unavailable, which is the honest answer, rather than confirming a different
            // alarm and calling tonight verified.
            remoteID: verifiableID.flatMap { written.contains($0) ? $0 : nil },
            note: note,
            // A morning with nothing on it makes this a warning whatever else succeeded. Everything
            // in this expression is something that did not happen; a silent morning is the one that
            // is measured on his bed rather than inferred from a status code.
            isPartial: !report.isComplete || !failures.isEmpty || !createProblems.isEmpty
                || oneOffFailed || !weekProblems.isEmpty
                || routineNotes.contains { $0.hasPrefix("Could not") },
            // The one time change and any silent morning, on the screen whether this went perfectly
            // or not. Everything else in `note` is about the routines, and a clean write already says
            // that in its own words.
            highlights: weekProblems + oneOffVerdicts
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
    /// The outcome of one create, with the server's own words when it refused.
    ///
    /// A bare `String?` was the first version, and it was wrong for exactly the reason this project
    /// keeps re-learning: a refusal came back as `nil`, the reason was discarded, and the screen
    /// then said nothing at all about a create that had been attempted and rejected. Alex reported
    /// "it does not create them" and there was no way to tell a refusal from a code path that never
    /// ran. **When it fails, print what the server said.**
    enum CreateOutcome {
        case created(String)
        /// Succeeded, but the response carried no id we could read. The alarm is real.
        case createdUnknownID
        case refused(String)
    }

    /// The two paths a create might live at.
    ///
    /// `v1` first because that is where the working update lives, so it is the likelier neighbour.
    /// `v2` second because that is where the working list lives. One of these two is right and
    /// nothing public says which.
    static let createPaths = ["v1", "v2"]

    private func postAlarm(
        _ payload: [String: Any],
        version: String,
        token: String,
        user: String
    ) async throws -> CreateOutcome {
        guard let url = URL(string: "\(Self.appHost)/\(version)/users/\(user)/alarms") else {
            return .refused("bad URL")
        }

        let response = try await http.send(
            "POST", url, headers: Self.baseHeaders(token: token), body: try HTTPClient.json(payload)
        )

        // These three are about the account rather than about this one alarm, so they stop
        // everything rather than being reported per routine.
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
            return .refused("HTTP \(response.status), \(Self.serverMessage(response.data))")
        }

        // The id can arrive bare or wrapped. Both spellings are read rather than assumed. Note the
        // separate `createdUnknownID` case: the alarm exists either way, and reporting it as failed
        // would send him looking for something that is sitting on his bed.
        guard let json = try? HTTPClient.dictionary(response.data) else { return .createdUnknownID }
        if let id = Self.alarmID(json) ?? (json["alarm"] as? [String: Any]).flatMap(Self.alarmID) {
            return .created(id)
        }
        return .createdUnknownID
    }

    /// Whatever the server sent back, trimmed to something that fits on a phone.
    ///
    /// Ported from the Whoop leg, where printing the response body is what ended five hours of
    /// wrong reasoning. Same rule, same reason.
    static func serverMessage(_ data: Data) -> String {
        guard var text = String(data: data, encoding: .utf8), !text.isEmpty else { return "no body" }
        text = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return text.count > 200 ? String(text.prefix(200)) + "..." : text
    }

    /// His routines, as the server returns them, flattened to printable lines.
    ///
    /// Read only, and it stays read only until a real routine object off this account has been seen.
    /// The shape below is from a public capture of somebody else's account, which is evidence about
    /// what the endpoint is and no evidence at all about what his holds.
    ///
    /// Returns an empty array rather than throwing. This is a diagnostic, and a diagnostic that can
    /// take an alarm write down with it is worse than no diagnostic.
    func routineDump() async -> [String] {
        let routines = (try? await fetchRoutines()) ?? []
        guard !routines.isEmpty else {
            guard let failure = lastRoutineReadFailure else {
                return ["This account returned no routines, and the read itself succeeded."]
            }
            var lines = ["The routines read was refused. \(failure).",
                         "This is the object Eight Sleep's app renders alarms through, so if it cannot be read, OneAlarm cannot make a new alarm appear in their app."]
            if let probe = await retiredRoutinesProbe() {
                lines.append("v1, the retired Routines API, answered HTTP \(probe.status). Recorded, never used: it is a different object from the one OneAlarm writes.")
                if probe.isSuccess { lines.append(Self.serverMessage(probe.data)) }
            }
            return lines
        }

        // Printed rather than parsed. Parsing it would mean deciding what it means, and the point of
        // this panel is to find that out from the account rather than from a write-up.
        var lines = ["read from /\(routinesVersion ?? "?")/users/{id}/routines"]
        for routine in routines {
            lines.append("---")
            for key in routine.keys.sorted() {
                lines.append("\(key) = \(Self.raw(routine[key]))")
            }
        }
        return lines
    }

    // MARK: Routines

    /// A read of the **retired** v1 Routines API, for the diagnostic panel and nothing else.
    ///
    /// `docs/RESEARCH.md` is explicit that Eight Sleep deleted the Routines feature from its app and
    /// that any write-up PUTting to `/v1/users/{id}/routines` for alarm control is obsolete. So an
    /// answer here is a **different object** from the one OneAlarm writes, and its fields must never
    /// reach a v2 write. It is read only when v2 has already failed, only to tell Alex whether the
    /// account is unreachable or the address is wrong, and the result is printed and dropped.
    ///
    /// Returns nil rather than throwing, and each `try?` stands alone: a diagnostic that can raise
    /// is a diagnostic that hides the thing it was added to show.
    private func retiredRoutinesProbe() async -> HTTPClient.Response? {
        guard let session = try? await currentToken() else { return nil }
        guard let url = URL(string: "\(Self.appHost)/v1/users/\(session.userID)/routines") else { return nil }
        return try? await http.send("GET", url, headers: Self.baseHeaders(token: session.token))
    }

    /// Every routine on the account, raw.
    ///
    /// Their app models alarms **inside** routines, so this is the object that decides what he
    /// actually sees. Returned as raw dictionaries for the same reason the alarms are: this adapter
    /// writes back what it does not understand rather than dropping it.
    func fetchRoutines() async throws -> [[String: Any]] {
        let (token, user) = try await currentToken()

        // **v2 only, and the v1 fallback that was here has been removed.**
        //
        // `docs/RESEARCH.md` is explicit: Eight Sleep deleted the Routines feature from its app and
        // "any write-up that PUTs to `/v1/users/{id}/routines` for alarm control is obsolete". The
        // object this adapter writes is a different one, `PUT /v2/users/{id}/routines/{routineId}`,
        // carrying `days`, `bedtime` and `alarmsToCreate`, and confirmed in two independent public
        // captures. Both statements are true: v1 routines is the retired feature, v2 routines is the
        // current one.
        //
        // Which makes falling back to v1 actively dangerous rather than merely useless. If it
        // answers, it answers with the **retired** object, and this function's caller would then
        // echo those fields into a v2 write. Reading object A and writing it to endpoint B is the
        // exact shape of the mistake that cost five hours on the Whoop read. The v1 probe survives
        // in `routineDump`, where it is labelled and never written back.
        guard let url = URL(string: "\(Self.appHost)/v2/users/\(user)/routines") else { return [] }
        let response = try await http.send("GET", url, headers: Self.baseHeaders(token: token))
        if response.status == 403 { throw AdapterError.subscriptionRequired }
        if response.status == 401 {
            accessToken = nil
            throw AdapterError.authenticationFailed("Token was rejected.")
        }
        guard response.isSuccess else {
            lastRoutineReadFailure = "v2: HTTP \(response.status)"
            return []
        }
        routinesVersion = "v2"

        guard let json = try? HTTPClient.dictionary(response.data) else { return [] }

        // Two envelope shapes, because nobody has seen this account's yet and guessing one would
        // return empty and read as "you have no routines".
        //
        // Written out rather than as one `??` chain crossing an `as?` cast. That chain typechecks by
        // precedence rules most readers would have to look up, and the compiler that would settle it
        // is on Alex's Mac rather than here.
        if let direct = json["routines"] as? [[String: Any]] { return direct }
        if let settings = json["settings"] as? [String: Any],
           let nested = settings["routines"] as? [[String: Any]] {
            return nested
        }
        return []
    }

    /// The routine an alarm belongs to, from its own `tags`.
    ///
    /// `tags` holds entries like `routine-94b49169-...`. That string has been printed in the
    /// diagnostics since 16 August with nobody able to say what it referenced. It references this.
    static func routineID(of alarm: [String: Any]) -> String? {
        guard let tags = alarm["tags"] as? [Any] else { return nil }
        for tag in tags {
            guard let text = tag as? String, text.hasPrefix("routine-") else { continue }
            return String(text.dropFirst("routine-".count))
        }
        return nil
    }

    static func routineIdentifier(_ routine: [String: Any]) -> String? {
        for key in ["id", "routineId", "routine_id"] {
            if let text = routine[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    /// A routine's days, as their app spells them: lowercase names in a flat array.
    static func days(of routine: [String: Any]) -> Set<Locale.Weekday> {
        guard let days = routine["days"] as? [Any] else { return [] }
        let names = Set(days.compactMap { ($0 as? String)?.lowercased() })
        return Set(Locale.Weekday.displayOrder.filter { names.contains($0.eightSleepKey) })
    }

    /// Change a routine's days and its switch. Nothing else, and `bedtime` above all.
    ///
    /// Alex, 2026-08-16: *"OneAlarm is my one single source of truth for alarm setting... only the
    /// modifications of temperature, vibration etc should be done in the respective app."* A
    /// routine's **days** are alarm setting, so they are OneAlarm's. A routine's **bedtime** is not
    /// an alarm at all, it is when he goes to bed, and it is his. It is echoed back exactly as the
    /// server sent it, along with every other field on the object including the ones with no known
    /// meaning.
    ///
    /// This is the same read modify write the alarm side uses, and it is what makes writing to an
    /// object this project has never fully seen defensible: nothing is composed, one field is
    /// replaced, everything else is a copy.
    static func authorRoutine(
        _ routine: [String: Any],
        days: Set<Locale.Weekday>,
        enabled: Bool
    ) -> [String: Any] {
        var payload = routine
        // Flat lowercase names, matching the shape the server sends, rather than the seven named
        // booleans an alarm uses. Two spellings of a weekday on one API, which is exactly why this
        // is read off the object rather than assumed.
        payload["days"] = Locale.Weekday.displayOrder
            .filter { days.contains($0) }
            .map(\.eightSleepKey)
        payload["enabled"] = enabled
        return payload
    }

    /// One entry for a routine's `alarmsToCreate`, built from an alarm he already has.
    ///
    /// The routine object spells an alarm differently from the alarm object: `timeWithOffset` rather
    /// than `time`, and `settings` wrapping `vibration` and `thermal`. Two spellings on one API,
    /// which is the whole reason this project reads before it writes.
    ///
    /// His vibration and thermal blocks are copied across verbatim from a real alarm rather than
    /// composed. The reference library's create payload and its own documented read shape disagree
    /// about those field names thirty lines apart, and the difference lands in the bed's temperature
    /// at 6am.
    static func newRoutineAlarm(like template: [String: Any], at time: WallClockTime) -> [String: Any] {
        var settings: [String: Any] = [:]
        if let vibration = template["vibration"] { settings["vibration"] = vibration }
        if let thermal = template["thermal"] { settings["thermal"] = thermal }

        return [
            "enabled": true,
            "disabledIndividually": false,
            // `dayOffset` is a **string enum**, not a number.
            //
            // The first version of this sent `0`, taken from one public capture read too quickly. A
            // second independent implementation settles it: both spell it `"MinusOne"` for a bedtime
            // and `"Zero"` for an alarm. An integer here is the kind of type error that comes back
            // as a bare 400 with an empty body, which is precisely the failure that has been eating
            // this evening, and it would have been blamed on the endpoint rather than the payload.
            //
            // The annotation is separate and also required: a nested literal mixing a String and an
            // Int is a hard Swift error, not a warning.
            "timeWithOffset": ["time": time.hhmmss, "dayOffset": "Zero"] as [String: Any],
            "settings": settings,
            // Both sources send these, both as the epoch. Absent, they are two fields the server
            // expects and does not get, and this API replaces rather than merges.
            "dismissedUntil": "1970-01-01T00:00:00Z",
            "snoozedUntil": "1970-01-01T00:00:00Z",
        ]
    }

    /// Push a routine back. Returns nil on success, or the reason it was refused.
    private func putRoutine(_ routine: [String: Any], id: String, token: String, user: String) async throws -> String? {
        guard let url = URL(string: "\(Self.appHost)/v2/users/\(user)/routines/\(id)") else {
            return "bad routine URL"
        }
        let response = try await http.send(
            "PUT", url, headers: Self.baseHeaders(token: token), body: try HTTPClient.json(routine)
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
        guard response.isSuccess else {
            return "HTTP \(response.status), \(Self.serverMessage(response.data))"
        }
        return nil
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
