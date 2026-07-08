import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Redacts secrets from URLs and headers before they are logged.
///
/// Both Plex and Jellyfin put access tokens in *query parameters*
/// (`X-Plex-Token`, `api_key`) — the single most common way a media client
/// leaks credentials into logs. This scrubs those, plus auth headers.
public enum SecretRedactor {
    /// Lowercased query keys whose values must never be logged.
    ///
    /// Subsonic puts its entire auth envelope in query params: `p` (cleartext
    /// password, deferred past v1 but still worth scrubbing defensively), `t`
    /// (the md5 token), `s` (the salt — public but ties directly to `t`), and
    /// `apiKey`. `u` (username) isn't a secret in the credential sense, but is
    /// still account PII, so it is treated the same as the token fields.
    public static let sensitiveQueryKeys: Set<String> = [
        "x-plex-token", "x-plex-client-identifier", "api_key", "apikey",
        "token", "secret", "pw", "password", "x-plex-session-identifier",
        "p", "t", "s", "u",
    ]

    public static let placeholder = "REDACTED"

    /// Return a log-safe absolute string for a URL with secret query values
    /// replaced.
    public static func redacted(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else {
            return url.absoluteString
        }
        components.queryItems = items.map { item in
            if sensitiveQueryKeys.contains(item.name.lowercased()) {
                return URLQueryItem(name: item.name, value: placeholder)
            }
            return item
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    /// Return a log-safe header dictionary with auth values replaced.
    public static func redacted(headers: [String: String]) -> [String: String] {
        var result = headers
        for key in headers.keys where isSensitiveHeader(key) {
            result[key] = placeholder
        }
        return result
    }

    static func isSensitiveHeader(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "authorization" || lower == "x-plex-token" || lower.contains("token")
    }
}

/// Receives network events for diagnostics. Implementations must not receive
/// un-redacted secrets — the ``HTTPClient`` redacts before calling.
public protocol NetworkLogger: Sendable {
    func log(_ message: @autoclosure () -> String)
}

/// Discards all logs (default).
public struct NoopNetworkLogger: NetworkLogger {
    public init() {}
    public func log(_ message: @autoclosure () -> String) {}
}

/// Prints redacted, single-line diagnostics to stdout. For development only.
public struct ConsoleNetworkLogger: NetworkLogger {
    public init() {}
    public func log(_ message: @autoclosure () -> String) {
        print("[MozzNet] \(message())")
    }
}
