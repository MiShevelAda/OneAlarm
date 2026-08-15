import Foundation
import os

/// Shared HTTP plumbing for the two remote legs.
///
/// The allowlist is the point of this type. Both bearer tokens reach genuinely destructive
/// endpoints: on Eight Sleep, running the pump and moving the bed frame while somebody may be in
/// it; on Whoop, the account lifecycle surface. A blocklist would need to anticipate every one of
/// them. An allowlist means an unlisted path cannot be called even by mistake, and adding one is a
/// deliberate edit to a short list rather than an accident.
struct HTTPClient {

    /// Requests this client is permitted to make, as regular expressions matched against
    /// `"METHOD https://host/path"`.
    ///
    /// The method is part of the pattern deliberately. Matching on the URL alone leaves the verb
    /// free, which means a path allowlisted for `GET` is also open to `DELETE`. On these two APIs
    /// that is the difference between reading an alarm and destroying it, so the verb is not
    /// something the caller gets to choose after the check has passed.
    let allowedPatterns: [String]
    let session: URLSession

    private static let log = Logger(subsystem: "de.trucora.OneAlarm", category: "http")

    init(allowedPatterns: [String], session: URLSession = .shared) {
        self.allowedPatterns = allowedPatterns
        self.session = session
    }

    struct Response {
        let status: Int
        let data: Data

        var isSuccess: Bool { (200..<300).contains(status) }
    }

    func isAllowed(_ method: String, _ url: URL) -> Bool {
        // A pattern edit must never be able to authorise cleartext.
        guard url.scheme == "https" else { return false }

        let candidate = "\(method.uppercased()) \(url.absoluteString)"
        return allowedPatterns.contains { pattern in
            candidate.range(of: pattern, options: [.regularExpression]) != nil
        }
    }

    func send(
        _ method: String,
        _ url: URL,
        headers: [String: String],
        body: Data? = nil
    ) async throws -> Response {
        guard isAllowed(method, url) else {
            // Deliberately loud. Reaching here means a code change tried to make a request the
            // allowlist does not cover, which is exactly the mistake this type exists to stop.
            throw AdapterError.unexpectedResponse("Blocked by allowlist: \(method) \(Self.safePath(url))")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Never the headers, which carry the bearer token, and never the body, which on the auth
        // calls carries the password. The path is hashed rather than printed because these paths
        // embed the account id, and the unified log survives in a sysdiagnose.
        Self.log.debug("\(method, privacy: .public) \(url.path, privacy: .private(mask: .hash))")

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Self.log.debug("-> \(status, privacy: .public)")
            return Response(status: status, data: data)
        } catch {
            throw AdapterError.transport(error.localizedDescription)
        }
    }

    /// A path with the account id dropped, safe to put in an error the user might screenshot.
    static func safePath(_ url: URL) -> String {
        let components = url.pathComponents.filter { $0 != "/" }
        return "/" + components.prefix(2).joined(separator: "/")
    }

    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AdapterError.unexpectedResponse("Response was not a JSON object.")
        }
        return object
    }

    /// Pretty printed for the preview gate, showing only keys that were explicitly named as safe.
    ///
    /// Deliberately an allowlist rather than a list of credential shaped names to strip. A denylist
    /// maintained by hand against a private API always lags: it would have to know that Cognito
    /// spells it `REFRESH_TOKEN` in one place and `RefreshToken` in another, and that `Session` is
    /// bearer equivalent. With an allowlist a field added to a payload later is invisible by
    /// default rather than exposed by default, which is the correct way round.
    static func redactedPreview(_ object: Any, showing allowed: Set<String>) -> String {
        func scrub(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                var copy: [String: Any] = [:]
                for (key, inner) in dict {
                    copy[key] = allowed.contains(key) ? scrub(inner) : "<redacted>"
                }
                return copy
            }
            if let array = value as? [Any] {
                return array.map(scrub)
            }
            return value
        }

        let scrubbed = scrub(object)
        guard
            let data = try? JSONSerialization.data(withJSONObject: scrubbed, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "<unserialisable>"
        }
        return text
    }
}

extension ISO8601DateFormatter {
    /// Eight Sleep returns `"2026-08-16T05:50:00Z"`, sometimes with fractional seconds.
    static func parseFlexible(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
