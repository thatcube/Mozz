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
        var items: [(name: String, value: String)] = [
            ("clientID", clientIdentifier),
            ("code", code),
            ("context[device][product]", clientInfo.product),
            ("context[device][version]", clientInfo.version),
            ("context[device][platform]", clientInfo.platform),
            ("context[device][platformVersion]", clientInfo.platformVersion),
            ("context[device][device]", clientInfo.deviceName),
        ]
        if let forwardURL {
            items.append(("forwardUrl", forwardURL))
        }
        // Encode each name/value EXACTLY once, then place the query in the
        // fragment ourselves. Assigning to `URLComponents.fragment` would
        // percent-encode a SECOND time (turning "%5B" into "%255B"), mangling the
        // `context[device][...]` param names so Plex rejects the link with
        // "We were unable to complete this request." `clientID`/`code` are clean
        // and survived that, but the malformed context still broke the handshake.
        let query = items.compactMap { item -> String? in
            guard let name = item.name.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed),
                  let value = item.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed)
            else { return nil }
            return "\(name)=\(value)"
        }.joined(separator: "&")
        return URL(string: "https://app.plex.tv/auth#?\(query)")
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
