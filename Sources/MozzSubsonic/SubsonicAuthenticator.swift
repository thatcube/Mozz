import Foundation
import MozzCore
import MozzNetworking

/// Turns a messy user-typed host string into a canonical base `URL` for a
/// Subsonic/OpenSubsonic server.
///
/// Unlike ``JellyfinURLNormalizer``, this never injects a default port:
/// OpenSubsonic implementations don't share one (Navidrome commonly runs on
/// `4533`, Gonic/Ampache/LMS vary, and most self-hosted instances sit behind a
/// reverse proxy on 80/443) — guessing wrong would silently point at the wrong
/// service. It only supplies a scheme (defaulting to `https`, since most
/// Subsonic servers people connect to over the internet are reverse-proxied
/// behind TLS) when the user typed none.
public enum SubsonicURLNormalizer {
    public static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hadScheme = trimmed.contains("://")
        let withScheme = hadScheme ? trimmed : "https://\(trimmed)"

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

/// Drives Subsonic/OpenSubsonic authentication.
///
/// Two sign-in paths (architecture point 5):
/// - ``authenticate(username:password:)`` — the primary flow. Generates a
///   fresh, stable salt, derives `t = md5(password + salt)`, verifies the
///   result with `ping`, and returns a session whose token is the credential
///   envelope with the PLAINTEXT PASSWORD ALREADY DISCARDED — only the derived
///   `secret` (token) and `salt` are ever persisted.
/// - ``authenticate(username:apiKey:)`` — for OpenSubsonic servers/users that
///   hand out an API key directly, skipping password handling entirely.
///
/// Either path verifies with a live `ping` before anything is persisted:
/// `ping` with the chosen auth is authoritative for "this credential actually
/// works" (architecture point 10) — an auth failure surfaces as the
/// error-code-mapped ``MozzError`` from ``SubsonicClient``, not a generic one.
public struct SubsonicAuthenticator: Sendable {
    private let baseURL: URL
    /// The app's stable per-install device identifier (``AppEnvironment/clientIdentifier``).
    /// The Subsonic wire protocol itself has no per-device identifier concept
    /// (its `c=` parameter is a constant client *name*, not a device id) — this
    /// is threaded through purely so ``ServerConnection/clientIdentifier``
    /// stays a single, stable, app-wide identity across every backend, matching
    /// ``JellyfinAuthenticator``/`PlexAuthenticator` rather than minting a new
    /// random id on every sign-in.
    private let clientIdentifier: String
    private let transport: any HTTPTransport

    public init(
        baseURL: URL,
        clientIdentifier: String,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.baseURL = baseURL
        self.clientIdentifier = clientIdentifier
        self.transport = transport
    }

    public func authenticate(username: String, password: String) async throws -> AuthenticatedSession {
        let salt = SubsonicAuth.generateSalt()
        let token = SubsonicAuth.md5Token(password: password, salt: salt)
        let credential = SubsonicCredential(
            mode: .md5, username: Self.normalizeUsername(username), secret: token, salt: salt
        )
        return try await verify(credential: credential)
    }

    public func authenticate(username: String, apiKey: String) async throws -> AuthenticatedSession {
        let credential = SubsonicCredential(
            mode: .apiKey, username: Self.normalizeUsername(username), secret: apiKey
        )
        return try await verify(credential: credential)
    }

    /// Confirms a credential actually authenticates before it's ever
    /// persisted, then returns an ``AuthenticatedSession`` whose `token` is
    /// the JSON-encoded ``SubsonicCredential`` envelope (see architecture
    /// point 5 — this requires no `StoredSession` schema change; the field is
    /// already an opaque string).
    private func verify(credential: SubsonicCredential) async throws -> AuthenticatedSession {
        let client = try SubsonicClient(baseURL: baseURL, credential: credential, transport: transport)
        let response = try await client.call("ping")
        let encoded = try credential.encoded()
        // Subsonic has no dedicated "friendly server name" field the way Plex
        // (serverName) / Jellyfin (System/Info ServerName) do — `ping`'s own
        // `type` (e.g. "navidrome") is the closest thing, and doubles as the
        // runtime "what did .subsonic actually connect to" display the
        // architecture calls for (point 1). Falls back to the host when a
        // (very old/minimal) server omits `type`.
        let serverName = response.type.map { $0.prefix(1).uppercased() + $0.dropFirst() }
            ?? baseURL.host ?? "Subsonic"
        return AuthenticatedSession(
            kind: .subsonic,
            baseURL: baseURL,
            token: encoded,
            userID: credential.username,
            serverName: serverName,
            clientIdentifier: clientIdentifier
        )
    }

    /// Trims whitespace only — never re-cases. Subsonic usernames are
    /// case-sensitive server-side, so the exact string the user typed is what
    /// gets sent as `u=` on every request; this normalized copy exists solely
    /// for Mozz's own multi-user ``ServerConnection/id`` disambiguation and
    /// display (see `AppEnvironment.serverId`), never for the wire.
    static func normalizeUsername(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
