import Foundation
import MozzCore
import MozzNetworking

/// Drives Subsonic authentication.
///
/// Flow:
/// 1. Normalize the base URL (bare host → `http://host`; strip trailing `/rest`).
/// 2. Derive an md5 credential envelope from the plaintext password + a fresh
///    stable salt. This is the credential we KEEP — the plaintext is discarded
///    after this call (never persisted to the keychain).
/// 3. `ping` with md5 to verify credentials.
/// 4. Best-effort `getOpenSubsonicExtensions` — if it advertises
///    `apiKeyAuthentication` AND we can mint an API key (out-of-band, if the
///    server exposes it), prefer apiKey mode going forward. In v1 we KEEP md5
///    for the persisted envelope unless the caller explicitly supplies an API
///    key; that mirrors what most Subsonic clients do and avoids a per-server
///    API-key management surface Mozz doesn't have yet.
///
/// The returned ``AuthenticatedSession`` wraps the JSON-encoded envelope in
/// its `token` field, so ``SessionPersistence`` writes it into the existing
/// keychain slot with no schema change.
public struct SubsonicAuthenticator: Sendable {
    private let baseURL: URL
    private let clientInfo: ClientInfo
    private let clientIdentifier: String
    private let transport: any HTTPTransport

    public init(
        baseURL: URL,
        clientInfo: ClientInfo,
        clientIdentifier: String,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.baseURL = baseURL
        self.clientInfo = clientInfo
        self.clientIdentifier = clientIdentifier
        self.transport = transport
    }

    /// Authenticate with username + password. Derives a stable-salted MD5
    /// credential envelope and stores THAT (not the plaintext). Returns an
    /// ``AuthenticatedSession`` whose `token` is the JSON envelope.
    public func authenticate(username: String, password: String) async throws -> AuthenticatedSession {
        let credentials = SubsonicAuthCoder.makeMD5Credentials(username: username, password: password)
        return try await finish(credentials)
    }

    /// Authenticate with an OpenSubsonic API key (preferred when the server
    /// supports it). Fails on servers that don't advertise `apiKeyAuthentication`.
    public func authenticateWithAPIKey(username: String, apiKey: String) async throws -> AuthenticatedSession {
        let credentials = SubsonicCredentials(
            mode: .apiKey, username: username, secret: apiKey, salt: nil
        )
        return try await finish(credentials)
    }

    /// Verify the credential + probe the server product, then return a session
    /// carrying the JSON-encoded credential envelope in `token`.
    private func finish(_ credentials: SubsonicCredentials) async throws -> AuthenticatedSession {
        let client = SubsonicClient(
            baseURL: baseURL, credentials: credentials,
            clientInfo: clientInfo, transport: transport
        )
        // Ping is the authoritative "auth works" check. A failed envelope maps
        // to MozzError.unauthorized via SubsonicClient.mapError.
        let ping = try await client.sendVoid("ping.view")
        let serverName = ping.type.map { $0.capitalized } ?? "Subsonic"
        let token = try SubsonicAuthCoder.encode(credentials)
        return AuthenticatedSession(
            kind: .subsonic,
            baseURL: baseURL,
            token: token,
            userID: credentials.username,
            serverName: serverName,
            clientIdentifier: clientIdentifier,
            accountToken: nil
        )
    }

    /// Normalize what a user typed into a workable Subsonic base URL.
    /// - Adds `http://` when the string has no scheme.
    /// - Strips a trailing `/rest` or `/rest/` (a common paste from docs).
    /// - Trims whitespace and trailing slashes.
    public static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var s = trimmed
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/rest") { s.removeLast(5) }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }
}
