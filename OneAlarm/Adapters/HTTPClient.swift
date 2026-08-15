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

    /// Paths this client is permitted to reach, as regular expressions anchored to the full URL.
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

    func isAllowed(_ url: URL) -> Bool {
        let absolute = url.absoluteString
        return allowedPatterns.contains { pattern in
            absolute.range(of: pattern, options: [.regularExpression]) != nil
        }
    }

    func send(
        _ method: String,
        _ url: URL,
        headers: [String: String],
        body: Data? = nil
    ) async throws -> Response {
        guard isAllowed(url) else {
            // Deliberately loud. Reaching here means a code change tried to call something the
            // allowlist does not cover, which is exactly the mistake this type exists to stop.
            throw AdapterError.unexpectedResponse("Blocked by allowlist: \(method) \(url.path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Path only. Never the headers, which carry the bearer token, and never the body, which on
        // the auth calls carries the password.
        Self.log.debug("\(method, privacy: .public) \(url.path, privacy: .public)")

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Self.log.debug("\(url.path, privacy: .public) -> \(status, privacy: .public)")
            return Response(status: status, data: data)
        } catch {
            throw AdapterError.transport(error.localizedDescription)
        }
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

    /// Pretty printed for the preview gate, with anything credential shaped removed.
    static func redactedPreview(_ object: Any) -> String {
        let sensitive: Set<String> = [
            "password", "client_secret", "access_token", "refresh_token", "RefreshToken",
            "AccessToken", "IdToken", "PASSWORD", "authorization",
        ]

        func scrub(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                var copy: [String: Any] = [:]
                for (key, inner) in dict {
                    copy[key] = sensitive.contains(key) ? "<redacted>" : scrub(inner)
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
