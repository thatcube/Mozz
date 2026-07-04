import Foundation

/// Static identity Mozz presents to every backend. Used to build auth headers
/// and device registrations. The `clientIdentifier` is per-install and lives in
/// ``ServerConnection``; these are the constant product fields.
public struct ClientInfo: Sendable, Hashable {
    public var product: String
    public var version: String
    public var deviceName: String
    public var platform: String
    public var platformVersion: String

    public init(
        product: String,
        version: String,
        deviceName: String,
        platform: String,
        platformVersion: String
    ) {
        self.product = product
        self.version = version
        self.deviceName = deviceName
        self.platform = platform
        self.platformVersion = platformVersion
    }
}

/// The successful result of any auth flow: enough to persist a
/// ``ServerConnection`` and store its token.
public struct AuthenticatedSession: Sendable, Hashable {
    public var kind: BackendKind
    public var baseURL: URL
    public var token: String
    public var userID: String?
    public var serverName: String
    public var clientIdentifier: String

    public init(
        kind: BackendKind,
        baseURL: URL,
        token: String,
        userID: String? = nil,
        serverName: String,
        clientIdentifier: String
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.token = token
        self.userID = userID
        self.serverName = serverName
        self.clientIdentifier = clientIdentifier
    }
}

// MARK: - Plex PIN / OAuth flow

/// A pending Plex link code. The UI shows ``code`` (and/or opens the OAuth URL)
/// and the authenticator polls until the PIN is claimed, yielding a token.
public struct PlexPinSession: Sendable, Hashable {
    public var id: Int
    public var code: String
    /// The stable client identifier tied to this PIN request.
    public var clientIdentifier: String

    public init(id: Int, code: String, clientIdentifier: String) {
        self.id = id
        self.code = code
        self.clientIdentifier = clientIdentifier
    }

    /// The hosted OAuth page the user can be sent to instead of typing the PIN.
    public func authAppURL(clientInfo: ClientInfo, forwardURL: String? = nil) -> URL? {
        var components = URLComponents(string: "https://app.plex.tv/auth")
        var items: [URLQueryItem] = [
            .init(name: "clientID", value: clientIdentifier),
            .init(name: "code", value: code),
            .init(name: "context[device][product]", value: clientInfo.product),
            .init(name: "context[device][version]", value: clientInfo.version),
            .init(name: "context[device][platform]", value: clientInfo.platform),
            .init(name: "context[device][platformVersion]", value: clientInfo.platformVersion),
            .init(name: "context[device][device]", value: clientInfo.deviceName),
        ]
        if let forwardURL {
            items.append(.init(name: "forwardUrl", value: forwardURL))
        }
        components?.fragment = "?" + (items.compactMap { item -> String? in
            guard let value = item.value,
                  let name = item.name.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed),
                  let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed)
            else { return nil }
            return "\(name)=\(encoded)"
        }.joined(separator: "&"))
        return components?.url
    }
}

/// A candidate connection to a Plex server discovered via `resources`.
/// Multiple may exist per server (local, remote, relay); the authenticator
/// races them and keeps the fastest reachable one.
public struct PlexResourceConnection: Sendable, Hashable {
    public var serverName: String
    public var clientIdentifier: String
    public var uri: URL
    public var isLocal: Bool
    public var isRelay: Bool
    public var accessToken: String

    public init(
        serverName: String,
        clientIdentifier: String,
        uri: URL,
        isLocal: Bool,
        isRelay: Bool,
        accessToken: String
    ) {
        self.serverName = serverName
        self.clientIdentifier = clientIdentifier
        self.uri = uri
        self.isLocal = isLocal
        self.isRelay = isRelay
        self.accessToken = accessToken
    }
}

// MARK: - Jellyfin Quick Connect flow

/// A pending Jellyfin Quick Connect session. The UI shows ``code``; the
/// authenticator polls with ``secret`` until the user approves it in their
/// Jellyfin web session, then exchanges the secret for an access token.
public struct QuickConnectSession: Sendable, Hashable {
    public var secret: String
    public var code: String

    public init(secret: String, code: String) {
        self.secret = secret
        self.code = code
    }
}

extension CharacterSet {
    /// Query-value-safe set: alphanumerics plus a few unreserved marks, but not
    /// `&`, `=`, `+`, `/`, etc., so values encode unambiguously.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
