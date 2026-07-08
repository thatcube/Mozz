import Foundation
import CryptoKit
import MozzCore

/// How a ``SubsonicCredential`` authenticates each request.
public enum SubsonicAuthMode: String, Codable, Sendable, Hashable {
    /// OpenSubsonic `apiKeyAuthentication`: a server-issued API key sent as
    /// `apiKey`. The `u` (username) param MUST be omitted in this mode.
    case apiKey
    /// Classic Subsonic token auth: `t = MD5(password + salt)` sent with the
    /// stable `s` (salt). The plaintext password is discarded at login, so only
    /// a per-server, non-reusable token+salt pair is ever stored, and the signed
    /// URL is deterministic across launches (stable artwork cache keys).
    case md5
    /// Legacy cleartext `p` password. Deferred past v1 (not produced by login);
    /// the case exists so the envelope is forward-compatible.
    case legacy
}

/// The credential Mozz persists for a Subsonic server, JSON-encoded into the
/// existing keychain "token" slot (``AuthenticatedSession/token`` /
/// ``StoredSession/token``) — NO storage-schema change.
///
/// Design (spec item 5):
/// - Prefer ``SubsonicAuthMode/apiKey`` when the server supports OpenSubsonic
///   `apiKeyAuthentication` — the strongest option, and the key is revocable
///   server-side.
/// - Otherwise use ``SubsonicAuthMode/md5``: generate a STABLE random salt once
///   at login, compute `t = MD5(password + salt)`, and DISCARD the plaintext
///   password. This avoids storing a reusable password AND yields deterministic
///   request URLs (a fresh random salt per request would thrash the artwork
///   cache, which keys on the resolved URL — spec item 8).
public struct SubsonicCredential: Codable, Sendable, Hashable {
    public var mode: SubsonicAuthMode
    public var username: String
    /// The secret for `mode`: the API key (apiKey), the MD5 token (md5), or the
    /// cleartext password (legacy).
    public var secret: String
    /// The stable salt for `md5` mode; nil otherwise.
    public var salt: String?

    public init(mode: SubsonicAuthMode, username: String, secret: String, salt: String? = nil) {
        self.mode = mode
        self.username = username
        self.secret = secret
        self.salt = salt
    }

    // MARK: Factories

    /// Build an MD5-token credential from a plaintext password, generating a
    /// stable salt and discarding the password.
    public static func md5(
        username: String,
        password: String,
        salt: String = SubsonicCredential.makeSalt()
    ) -> SubsonicCredential {
        SubsonicCredential(
            mode: .md5,
            username: username,
            secret: SubsonicCredential.md5Hex(password + salt),
            salt: salt
        )
    }

    /// Build an API-key credential (OpenSubsonic `apiKeyAuthentication`).
    public static func apiKey(username: String, apiKey: String) -> SubsonicCredential {
        SubsonicCredential(mode: .apiKey, username: username, secret: apiKey)
    }

    // MARK: JSON envelope (stored in the keychain token slot)

    /// Encode to the JSON string persisted as the session token.
    public func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    /// Decode from the JSON string persisted as the session token.
    public static func decode(_ token: String) -> SubsonicCredential? {
        guard let data = token.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SubsonicCredential.self, from: data)
    }

    // MARK: Crypto helpers

    /// Lowercase hex MD5, per the Subsonic token spec (`t = MD5(password+salt)`).
    public static func md5Hex(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A random lowercase-hex salt. Subsonic requires the salt be ≥ 6 chars; 16
    /// hex chars (8 bytes) is comfortably unique per server without being large.
    public static func makeSalt(byteCount: Int = 8) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The signing query items this credential contributes to EVERY request.
    /// - apiKey: `apiKey=…` and NO `u` (per OpenSubsonic apiKeyAuthentication).
    /// - md5: `u=…`, `t=…`, `s=…`.
    /// - legacy: `u=…`, `p=…` (cleartext; deferred but supported for completeness).
    public func signingQueryItems() -> [URLQueryItem] {
        switch mode {
        case .apiKey:
            return [URLQueryItem(name: "apiKey", value: secret)]
        case .md5:
            var items = [URLQueryItem(name: "u", value: username)]
            items.append(URLQueryItem(name: "t", value: secret))
            if let salt { items.append(URLQueryItem(name: "s", value: salt)) }
            return items
        case .legacy:
            return [
                URLQueryItem(name: "u", value: username),
                URLQueryItem(name: "p", value: secret),
            ]
        }
    }
}

/// Turns messy user-supplied host strings into a canonical Subsonic base `URL`.
/// Mirrors ``JellyfinURLNormalizer`` but does NOT inject a default port —
/// Subsonic servers are commonly reverse-proxied on 80/443 with no well-known
/// port (Navidrome's own default 4533 is dev-only), so guessing one would break
/// the common deployment. Adds `http://` when no scheme is present and strips a
/// trailing slash.
public enum SubsonicURLNormalizer {
    public static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hadScheme = trimmed.contains("://")
        let withScheme = hadScheme ? trimmed : "http://\(trimmed)"

        guard var components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty else {
            return nil
        }
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.url
    }
}
