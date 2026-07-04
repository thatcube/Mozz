import Foundation
import MozzCore
import MozzNetworking

/// Drives Plex authentication: request a link PIN, let the user claim it (by
/// typing the short code at plex.tv/link or via the hosted OAuth page from
/// ``PlexPinSession/authAppURL(clientInfo:forwardURL:)``), poll until it yields
/// an account token, then discover the user's servers and pick the fastest
/// reachable connection.
///
/// Talks to `plex.tv`; the resulting per-server ``PlexResourceConnection``
/// carries the server-scoped access token used to build a ``PlexBackend``.
public struct PlexAuthenticator: Sendable {
    private let clientInfo: ClientInfo
    private let clientIdentifier: String
    private let transport: any HTTPTransport
    private let client: HTTPClient

    private static let plexTVBase = URL(string: "https://plex.tv")!

    public init(
        clientInfo: ClientInfo,
        clientIdentifier: String,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.clientInfo = clientInfo
        self.clientIdentifier = clientIdentifier
        self.transport = transport
        self.client = HTTPClient(
            baseURL: Self.plexTVBase,
            transport: transport,
            defaultHeaders: PlexHeaders.common(clientInfo: clientInfo, clientIdentifier: clientIdentifier, token: nil)
        )
    }

    // MARK: PIN flow

    /// Request a short link code. `strong` is omitted so the code stays short
    /// (4 chars), which is friendlier to type at plex.tv/link.
    public func requestPin() async throws -> PlexPinSession {
        let response = try await client.send(
            Endpoint(method: .post, path: "api/v2/pins", query: [URLQueryItem(name: "strong", value: "false")]),
            as: PlexPinResponse.self
        )
        return PlexPinSession(id: response.id, code: response.code, clientIdentifier: clientIdentifier)
    }

    /// Poll a PIN once; returns the account token when the user has claimed it,
    /// otherwise `nil`.
    public func checkPin(id: Int) async throws -> String? {
        let response = try await client.send(
            Endpoint(path: "api/v2/pins/\(id)"),
            as: PlexPinResponse.self
        )
        if let token = response.authToken, !token.isEmpty { return token }
        return nil
    }

    /// Poll until the PIN is claimed (or the deadline passes), returning the
    /// account token.
    public func awaitPin(
        _ session: PlexPinSession,
        pollInterval: TimeInterval = 2,
        timeout: TimeInterval = 300
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let token = try await checkPin(id: session.id) { return token }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw MozzError.cancelled
    }

    // MARK: Resource discovery

    /// Discover the account's servers and flatten them into candidate
    /// connections (local first, relay last). Each carries its own
    /// server-scoped access token.
    public func discoverConnections(accountToken: String) async throws -> [PlexResourceConnection] {
        let authedClient = client.withDefaultHeaders(["X-Plex-Token": accountToken])
        let resources = try await authedClient.send(
            Endpoint(path: "api/v2/resources", query: [
                URLQueryItem(name: "includeHttps", value: "1"),
                URLQueryItem(name: "includeRelay", value: "1"),
            ]),
            as: [PlexResource].self
        )
        var connections: [PlexResourceConnection] = []
        for resource in resources where (resource.provides ?? "").contains("server") {
            guard let accessToken = resource.accessToken else { continue }
            for dto in resource.connections ?? [] {
                guard let uriString = dto.uri, let uri = URL(string: uriString) else { continue }
                connections.append(PlexResourceConnection(
                    serverName: resource.name ?? "Plex",
                    clientIdentifier: resource.clientIdentifier ?? "",
                    uri: uri,
                    isLocal: dto.local ?? false,
                    isRelay: dto.relay ?? false,
                    accessToken: accessToken
                ))
            }
        }
        return connections.sorted(by: Self.preferLocal)
    }

    /// Probe candidates in preference order and return the first that answers,
    /// so the app pins the fastest working address (local LAN over relay).
    public func firstReachableConnection(
        _ connections: [PlexResourceConnection],
        perProbeTimeout: TimeInterval = 3
    ) async -> PlexResourceConnection? {
        for connection in connections {
            let probe = HTTPClient(
                baseURL: connection.uri,
                transport: transport,
                defaultHeaders: PlexHeaders.common(clientInfo: clientInfo, clientIdentifier: clientIdentifier, token: connection.accessToken),
                retryPolicy: .none
            )
            if (try? await probe.send(Endpoint(path: "identity"))) != nil {
                return connection
            }
        }
        return connections.first
    }

    /// One-call convenience: discover connections, pick one, and produce the
    /// session to persist. The UI can instead call the steps individually.
    public func completeLogin(accountToken: String) async throws -> AuthenticatedSession {
        let connections = try await discoverConnections(accountToken: accountToken)
        guard let chosen = await firstReachableConnection(connections) else {
            throw MozzError.notFound
        }
        return AuthenticatedSession(
            kind: .plex,
            baseURL: chosen.uri,
            token: chosen.accessToken,
            userID: nil,
            serverName: chosen.serverName,
            clientIdentifier: clientIdentifier
        )
    }

    private static func preferLocal(_ lhs: PlexResourceConnection, _ rhs: PlexResourceConnection) -> Bool {
        func rank(_ connection: PlexResourceConnection) -> Int {
            if connection.isRelay { return 2 }
            return connection.isLocal ? 0 : 1
        }
        return rank(lhs) < rank(rhs)
    }
}
