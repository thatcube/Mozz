import Foundation
import MozzCore
import MozzNetworking

/// Drives Subsonic authentication. Two entry points map to the credential
/// envelope's two v1 modes (spec item 5):
/// - ``authenticate(username:password:)`` derives an MD5 token + stable salt and
///   discards the plaintext password.
/// - ``authenticate(username:apiKey:)`` uses an OpenSubsonic API key.
///
/// Both verify the credential with a `ping` (the authoritative check) and, on
/// success, produce an ``AuthenticatedSession`` whose `token` is the JSON
/// credential envelope the app persists into the keychain "token" slot — no
/// storage-schema change.
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

    /// Username + password → MD5-token credential (password is discarded).
    /// `onWaitingForLocalNetwork` fires if the first attempt is refused while iOS
    /// shows its local-network permission prompt (the call is auto-retried).
    public func authenticate(
        username: String,
        password: String,
        onWaitingForLocalNetwork: (@Sendable () -> Void)? = nil
    ) async throws -> AuthenticatedSession {
        let credential = SubsonicCredential.md5(username: username, password: password)
        return try await verify(credential, username: username, onWaiting: onWaitingForLocalNetwork)
    }

    /// Username + OpenSubsonic API key → apiKey credential (omits `u` in signing).
    public func authenticate(
        username: String,
        apiKey: String,
        onWaitingForLocalNetwork: (@Sendable () -> Void)? = nil
    ) async throws -> AuthenticatedSession {
        let credential = SubsonicCredential.apiKey(username: username, apiKey: apiKey)
        return try await verify(credential, username: username, onWaiting: onWaitingForLocalNetwork)
    }

    // MARK: Helpers

    private func verify(
        _ credential: SubsonicCredential,
        username: String,
        onWaiting: (@Sendable () -> Void)?
    ) async throws -> AuthenticatedSession {
        let client = SubsonicClient(
            baseURL: baseURL,
            credential: credential,
            clientInfo: clientInfo,
            transport: transport
        )
        // ping validates the chosen auth (a bad credential returns status=failed
        // code 40/44 → SubsonicClient maps it to `.unauthorized`). Wrapped so a
        // local server whose first connection is refused by the iOS local-network
        // permission prompt is retried once the user taps Allow, instead of
        // failing and forcing them to hit Sign In again.
        let ping = try await LocalNetworkPermission.retrying(for: baseURL, onWaiting: onWaiting) {
            try await client.send("ping", as: SubsonicEmpty.self)
        }
        return AuthenticatedSession(
            kind: .subsonic,
            baseURL: baseURL,
            token: credential.encoded(),
            userID: username,
            serverName: displayName(product: ping.type),
            clientIdentifier: clientIdentifier
        )
    }

    /// A friendly server name: the detected product (e.g. "navidrome" →
    /// "Navidrome"), else the host, else "Subsonic".
    private func displayName(product: String?) -> String {
        if let product, !product.isEmpty {
            return product.prefix(1).uppercased() + product.dropFirst()
        }
        return baseURL.host ?? "Subsonic"
    }
}
