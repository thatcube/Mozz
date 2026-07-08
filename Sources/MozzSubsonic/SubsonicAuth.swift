import Foundation
import CryptoKit
import MozzCore

/// The three auth modes Subsonic / OpenSubsonic servers accept.
///
/// v1 QA focus is Navidrome, which supports both ``apiKey`` (OpenSubsonic
/// extension `apiKeyAuthentication`) and ``md5``. Older classic Subsonic
/// servers accept only ``md5`` (or ``legacy`` cleartext — deliberately NOT
/// implemented in v1). The chosen mode is captured in ``SubsonicCredentials``
/// so subsequent requests re-sign deterministically without another handshake.
public enum SubsonicAuthMode: String, Codable, Sendable, Hashable {
    /// OpenSubsonic API key. Requests carry `apiKey=…` and MUST NOT include the
    /// `u=` parameter — the spec is explicit that mixing the two rejects the
    /// request. Preferred whenever the server advertises it.
    case apiKey
    /// Salted MD5: `t=MD5(password+salt)`, `s=<salt>`, `u=<username>`. We derive
    /// a stable salt at credential-storage time and DISCARD the plaintext
    /// password afterwards, so what lives in the keychain is a per-account
    /// hashed-only credential (attacker with keychain access can talk to that
    /// server but cannot reuse the password elsewhere) AND the query URL is
    /// deterministic across launches (artwork caches don't thrash).
    case md5
    /// Cleartext `p=<password>` — deliberately NOT implemented in v1 (kept in
    /// the enum only so a future opt-in for legacy servers is a purely additive
    /// change, not a schema migration). Storing it would keep a reusable
    /// password in the keychain, which we opted out of.
    case legacy
}

/// The credential envelope JSON-encoded into ``StoredSession.token``.
///
/// Design: reusing the existing keychain "token" slot as a JSON blob keeps
/// ``StoredSession`` schema-stable across backends — no migration risk, and
/// Plex/Jellyfin `token` remains a plain string. Only the Subsonic conformer
/// knows the token slot may carry an envelope.
public struct SubsonicCredentials: Codable, Sendable, Hashable {
    public var mode: SubsonicAuthMode
    public var username: String
    /// apiKey mode: the raw OpenSubsonic API key.
    /// md5 mode: `t = MD5(password + salt)` in lowercase hex. Deterministic
    /// given the same salt, which is precisely why we bake it in — every
    /// subsequent request URL is byte-identical.
    /// legacy mode: the plaintext password (unused in v1).
    public var secret: String
    /// The stable salt bound to `secret` in md5 mode. `nil` in apiKey / legacy.
    public var salt: String?

    public init(mode: SubsonicAuthMode, username: String, secret: String, salt: String? = nil) {
        self.mode = mode
        self.username = username
        self.secret = secret
        self.salt = salt
    }
}

/// Pure, testable helpers for encoding/decoding the credential envelope and
/// building signed Subsonic query items. No I/O.
public enum SubsonicAuthCoder {
    public static let apiVersion = "1.16.1"

    /// JSON-encode the envelope for storage in the keychain token slot.
    public static func encode(_ credentials: SubsonicCredentials) throws -> String {
        let data = try JSONEncoder().encode(credentials)
        guard let string = String(data: data, encoding: .utf8) else {
            throw MozzError.invalidResponse
        }
        return string
    }

    /// Decode a JSON envelope back out of the keychain token slot.
    public static func decode(_ token: String) throws -> SubsonicCredentials {
        guard let data = token.data(using: .utf8) else {
            throw MozzError.invalidResponse
        }
        return try JSONDecoder().decode(SubsonicCredentials.self, from: data)
    }

    /// Derive an md5 credential from a plaintext password + a stable salt (we
    /// generate one when caller passes `nil`). The plaintext is expected to be
    /// discarded by the caller after this call.
    public static func makeMD5Credentials(
        username: String, password: String, salt: String? = nil
    ) -> SubsonicCredentials {
        let s = salt ?? randomSalt()
        let digest = Insecure.MD5.hash(data: Data((password + s).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return SubsonicCredentials(mode: .md5, username: username, secret: hex, salt: s)
    }

    /// Build the fixed set of Subsonic query items for a signed request.
    ///
    /// - apiKey mode omits `u` (OpenSubsonic spec: sending both `apiKey` and
    ///   `u` MUST be rejected — omitting `u` is not optional).
    /// - md5 mode sends `u`, `t`, `s` — the deterministic triplet.
    /// - legacy mode sends `u`, `p` (not used in v1).
    /// Every mode also carries the protocol trio `v`, `c`, `f=json`.
    public static func queryItems(
        for credentials: SubsonicCredentials,
        clientInfo: ClientInfo,
        apiVersion: String = SubsonicAuthCoder.apiVersion
    ) -> [URLQueryItem] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientInfo.product),
            URLQueryItem(name: "f", value: "json"),
        ]
        switch credentials.mode {
        case .apiKey:
            items.append(URLQueryItem(name: "apiKey", value: credentials.secret))
        case .md5:
            items.append(URLQueryItem(name: "u", value: credentials.username))
            items.append(URLQueryItem(name: "t", value: credentials.secret))
            items.append(URLQueryItem(name: "s", value: credentials.salt ?? ""))
        case .legacy:
            items.append(URLQueryItem(name: "u", value: credentials.username))
            items.append(URLQueryItem(name: "p", value: credentials.secret))
        }
        return items
    }

    /// Cryptographically-random ASCII salt. 16 chars @ ~5.17 bits/char ≈ 82
    /// bits of entropy — plenty for a per-account salt that only needs to be
    /// non-guessable within one server, not across the internet.
    public static func randomSalt(length: Int = 16) -> String {
        let alphabet: [Character] = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var bytes = [UInt8](repeating: 0, count: length)
        for i in 0..<length { bytes[i] = UInt8.random(in: 0...255) }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}
