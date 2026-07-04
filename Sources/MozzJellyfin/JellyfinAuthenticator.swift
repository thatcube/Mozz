import Foundation
import MozzCore
import MozzNetworking

/// Drives Jellyfin authentication: Quick Connect (the primary, code-based flow)
/// plus username/password as a fallback. Produces an ``AuthenticatedSession``
/// the app persists as a ``ServerConnection`` (with the token stored separately
/// in the keychain).
public struct JellyfinAuthenticator: Sendable {
    private let baseURL: URL
    private let clientInfo: ClientInfo
    private let clientIdentifier: String
    private let client: HTTPClient

    public init(
        baseURL: URL,
        clientInfo: ClientInfo,
        clientIdentifier: String,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.baseURL = baseURL
        self.clientInfo = clientInfo
        self.clientIdentifier = clientIdentifier
        // Pre-auth: identify the device but carry no token yet.
        let auth = JellyfinAuth.authorizationHeader(clientInfo: clientInfo, deviceID: clientIdentifier, token: nil)
        self.client = HTTPClient(
            baseURL: baseURL,
            transport: transport,
            defaultHeaders: ["Authorization": auth, "Accept": "application/json"]
        )
    }

    // MARK: Quick Connect

    public func initiateQuickConnect() async throws -> QuickConnectSession {
        let result = try await client.send(
            Endpoint(method: .post, path: "QuickConnect/Initiate"),
            as: JFQuickConnectResult.self
        )
        guard let secret = result.Secret, let code = result.Code else { throw MozzError.invalidResponse }
        return QuickConnectSession(secret: secret, code: code)
    }

    public func isQuickConnectApproved(secret: String) async throws -> Bool {
        let result = try await client.send(
            Endpoint(path: "QuickConnect/Connect", query: [URLQueryItem(name: "secret", value: secret)]),
            as: JFQuickConnectResult.self
        )
        return result.Authenticated ?? false
    }

    public func completeQuickConnect(secret: String) async throws -> AuthenticatedSession {
        struct Body: Encodable { let Secret: String }
        let result = try await client.send(
            try Endpoint.jsonPost("Users/AuthenticateWithQuickConnect", body: Body(Secret: secret)),
            as: JFAuthenticationResult.self
        )
        return try await finish(result)
    }

    /// Poll Quick Connect until approved (or the deadline passes), then exchange
    /// the secret for a token. The UI can instead call the individual steps to
    /// drive its own polling with cancellation.
    public func awaitQuickConnect(
        _ session: QuickConnectSession,
        pollInterval: TimeInterval = 3,
        timeout: TimeInterval = 300
    ) async throws -> AuthenticatedSession {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if try await isQuickConnectApproved(secret: session.secret) {
                return try await completeQuickConnect(secret: session.secret)
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw MozzError.cancelled
    }

    // MARK: Username / password

    public func authenticate(username: String, password: String) async throws -> AuthenticatedSession {
        struct Body: Encodable { let Username: String; let Pw: String }
        let result = try await client.send(
            try Endpoint.jsonPost("Users/AuthenticateByName", body: Body(Username: username, Pw: password)),
            as: JFAuthenticationResult.self
        )
        return try await finish(result)
    }

    // MARK: Helpers

    public func serverName() async throws -> String {
        let info = try await client.send(Endpoint(path: "System/Info/Public"), as: JFSystemInfoPublic.self)
        return info.ServerName ?? "Jellyfin"
    }

    private func finish(_ result: JFAuthenticationResult) async throws -> AuthenticatedSession {
        guard let token = result.AccessToken, let userID = result.User?.Id else {
            throw MozzError.unauthorized
        }
        let name = (try? await serverName()) ?? "Jellyfin"
        return AuthenticatedSession(
            kind: .jellyfin,
            baseURL: baseURL,
            token: token,
            userID: userID,
            serverName: name,
            clientIdentifier: clientIdentifier
        )
    }
}
