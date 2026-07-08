import Foundation
import CryptoKit
import MozzCore

/// The tri-mode auth credential envelope for a Subsonic connection.
///
/// Persisted as a JSON string inside the *existing* keychain "token" slot
/// (``StoredSession/token``, itself just a `String`) — no `StoredSession`
/// schema change. `username` is always present (even in `apiKey` mode) because
/// Subsonic has no separate numeric/opaque user id the way Jellyfin does: the
/// normalized username IS the user identity, used both for display ("Signed
/// in as demo") and to disambiguate multiple accounts on one server in
/// ``ServerConnection/id`` (see `AppEnvironment.serverId`).
struct SubsonicCredential: Codable, Sendable, Hashable {
    enum Mode: String, Codable, Sendable {
        /// OpenSubsonic `apiKeyAuthentication`: a single opaque key identifies
        /// the account. Preferred when the server/user has one, since it never
        /// requires storing (or even knowing) a password.
        case apiKey
        /// Classic Subsonic token auth (API >= 1.13.0): `t = md5(password +
        /// salt)`. The salt is generated once at sign-in and persisted
        /// alongside `t` — never re-randomized, so re-deriving the SAME
        /// artwork/stream URLs across launches is possible, and so the
        /// plaintext password can be discarded immediately after signing in
        /// (only the derived token + salt are ever stored).
        case md5
        /// Cleartext `p=` password auth. Deferred past v1 (see
        /// ``SubsonicAuth/authQueryItems(for:)``); kept as an enum case so the
        /// envelope's shape doesn't need to change if it's added later.
        case legacy
    }

    var mode: Mode
    var username: String
    /// `apiKey` mode: the raw API key. `md5` mode: the derived token
    /// `t = md5(password + salt)` — the plaintext password itself is NEVER
    /// stored. `legacy`: unused in v1.
    var secret: String
    /// `md5` mode only: the stable salt used to derive `secret`. Persisted
    /// (not regenerated) so the same `t`/`s` pair — and therefore the same
    /// deterministic artwork/stream URLs — survive relaunches.
    var salt: String?

    init(mode: Mode, username: String, secret: String, salt: String? = nil) {
        self.mode = mode
        self.username = username
        self.secret = secret
        self.salt = salt
    }

    /// Encode to the JSON string stored in `StoredSession.token`.
    func encoded() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw MozzError.decodingFailed("SubsonicCredential: could not UTF-8 encode JSON")
        }
        return string
    }

    /// Decode from the JSON string stored in `StoredSession.token`.
    static func decoded(from token: String) throws -> SubsonicCredential {
        guard let data = token.data(using: .utf8) else {
            throw MozzError.decodingFailed("SubsonicCredential: token is not UTF-8")
        }
        do {
            return try JSONDecoder().decode(SubsonicCredential.self, from: data)
        } catch {
            throw MozzError.decodingFailed("SubsonicCredential: \(error)")
        }
    }
}

/// Tri-mode Subsonic request signing — the ONLY place that turns a credential
/// into query items, so every endpoint (JSON API call, artwork URL, stream
/// URL, download URL) is signed identically. Kept pure (no networking) so it's
/// trivially unit-tested.
enum SubsonicAuth {
    /// The classic Subsonic REST protocol version Mozz declares via `v=`.
    /// OpenSubsonic extensions are separately, independently probed via
    /// `getOpenSubsonicExtensions` — this is just the baseline `v=` a client
    /// must send on every request.
    static let apiVersion = "1.16.1"
    static let clientName = "Mozz"

    /// Non-auth query items every request needs: protocol version, client
    /// name, and JSON format (``SubsonicClient`` only ever decodes JSON).
    static var commonQueryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
    }

    /// The auth-specific query items for a credential.
    ///
    /// `apiKey` mode omits `u`, `p`, `t` and `s` entirely: the OpenSubsonic
    /// spec is explicit that "If apiKey is specified, then none of p, t, s,
    /// nor u can be specified" — sending both would earn error code 43
    /// ("multiple conflicting authentication mechanisms provided").
    static func authQueryItems(for credential: SubsonicCredential) throws -> [URLQueryItem] {
        switch credential.mode {
        case .apiKey:
            return [URLQueryItem(name: "apiKey", value: credential.secret)]
        case .md5:
            guard let salt = credential.salt, !salt.isEmpty else {
                throw MozzError.unsupported("Subsonic credential is missing its salt.")
            }
            return [
                URLQueryItem(name: "u", value: credential.username),
                URLQueryItem(name: "t", value: credential.secret),
                URLQueryItem(name: "s", value: salt),
            ]
        case .legacy:
            // Deferred past v1: no login path produces a `.legacy` credential
            // today, so reaching this is a programming error, not a runtime
            // server response — surfaced the same way as any other
            // unsupported-feature request rather than crashing.
            throw MozzError.unsupported("Legacy cleartext Subsonic authentication is not supported.")
        }
    }

    /// The full set of query items to sign a request: auth params + common
    /// params. Computed once per credential (not per request) by
    /// ``SubsonicClient`` and installed as an `HTTPClient` signing hook.
    static func queryItems(for credential: SubsonicCredential) throws -> [URLQueryItem] {
        try authQueryItems(for: credential) + commonQueryItems
    }

    /// A fresh, random hex salt (12 bytes = 24 hex chars — comfortably over
    /// the spec's minimum of 6 characters).
    static func generateSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// `t = md5(password + salt)`, lowercase hex — the Subsonic token-auth
    /// scheme (API >= 1.13.0). The password is concatenated with the salt as
    /// raw UTF-8 bytes (no separator), per spec.
    static func md5Token(password: String, salt: String) -> String {
        let digest = Insecure.MD5.hash(data: Data((password + salt).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
