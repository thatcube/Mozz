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
    /// A tight-timeout transport for probing candidate server connections, so an
    /// unreachable address (e.g. a LAN URI when off-network) is abandoned in a
    /// few seconds instead of blocking discovery on the 12s interactive timeout.
    private let probeTransport: any HTTPTransport
    /// Asks the network itself which servers are on it. Nil in tests that must
    /// not touch a socket.
    private let localDiscovery: (any PlexLocallyDiscovering)?
    private let client: HTTPClient

    private static let plexTVBase = URL(string: "https://plex.tv")!

    public init(
        clientInfo: ClientInfo,
        clientIdentifier: String,
        transport: any HTTPTransport = URLSessionTransport(),
        probeTransport: any HTTPTransport = URLSessionTransport(role: .discovery),
        localDiscovery: (any PlexLocallyDiscovering)? = PlexLocalDiscovery()
    ) {
        self.clientInfo = clientInfo
        self.clientIdentifier = clientIdentifier
        self.transport = transport
        self.probeTransport = probeTransport
        self.localDiscovery = localDiscovery
        self.client = HTTPClient(
            baseURL: Self.plexTVBase,
            transport: transport,
            defaultHeaders: PlexHeaders.common(clientInfo: clientInfo, clientIdentifier: clientIdentifier, token: nil)
        )
    }

    // MARK: PIN flow

    /// Request a link PIN for the hosted OAuth flow. `strong=true` yields a long
    /// token code — REQUIRED by `app.plex.tv/auth`, which cannot claim the short
    /// (`strong=false`) codes that are only meant for manual entry at
    /// plex.tv/link. (Verified against Plex's API: strong=false → "BHRR"-style
    /// 4-char code; strong=true → a 25-char token.)
    public func requestPin() async throws -> PlexPinSession {
        let response = try await client.send(
            Endpoint(method: .post, path: "api/v2/pins", query: [URLQueryItem(name: "strong", value: "true")]),
            as: PlexPinResponse.self
        )
        return PlexPinSession(id: response.id, code: response.code, clientIdentifier: clientIdentifier)
    }

    /// Poll a PIN once; returns the account token when the user has claimed it,
    /// otherwise `nil`. The PIN `code` is REQUIRED on the poll (it proves this is
    /// the client that created the PIN) — Plex may return a null token without it
    /// even after the PIN is claimed.
    public func checkPin(id: Int, code: String) async throws -> String? {
        let response = try await client.send(
            Endpoint(path: "api/v2/pins/\(id)", query: [URLQueryItem(name: "code", value: code)]),
            as: PlexPinResponse.self
        )
        if let token = response.authToken, !token.isEmpty { return token }
        return nil
    }

    /// Poll until the PIN is claimed (or the deadline passes), returning the
    /// account token. Transient `checkPin` failures are swallowed and retried —
    /// polling is inherently best-effort, and the app is often suspended mid-poll
    /// while the user authorizes in Safari (which can kill an in-flight request);
    /// aborting on the first blip would drop a sign-in that's about to succeed.
    public func awaitPin(
        _ session: PlexPinSession,
        pollInterval: TimeInterval = 2,
        timeout: TimeInterval = 300
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let token = try? await checkPin(id: session.id, code: session.code), !token.isEmpty { return token }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw MozzError.cancelled
    }

    // MARK: Resource discovery

    /// The account's avatar, as an absolute plex.tv URL, or `nil` when the
    /// account has no photo.
    ///
    /// This is an **account**-level lookup, so it needs the account token from
    /// the PIN flow — the per-server access token stored with a connection is
    /// scoped to that server and is rejected here. The returned URL is served
    /// publicly by plex.tv (no token), so it can be handed straight to an image
    /// loader.
    public func accountAvatarURL(accountToken: String) async throws -> URL? {
        try await accountProfile(accountToken: accountToken).avatarURL
    }

    /// The plex.tv account identity. This is account-level (not server-level), so
    /// it needs the PIN-flow account token; a per-server token is not accepted.
    public func accountProfile(accountToken: String) async throws -> SignedInAccount {
        let authedClient = client.withDefaultHeaders(["X-Plex-Token": accountToken])
        let user = try await authedClient.send(Endpoint(path: "api/v2/user"), as: PlexAccountUser.self)
        let username = user.username.nonEmpty ?? user.email.nonEmpty
        let displayName = user.title.nonEmpty ?? username
        return SignedInAccount(
            displayName: displayName,
            username: username,
            avatarURL: user.thumb.nonEmpty.flatMap(URL.init(string:))
        )
    }

    // MARK: Plex Home profiles

    public func homeUsers(accountToken: String) async throws -> [PlexHomeUser] {
        let authedClient = client.withDefaultHeaders([
            "X-Plex-Token": accountToken,
        ])
        let response = try await authedClient.send(
            Endpoint(path: "api/v2/home/users"),
            as: PlexHomeUsersResponse.self)
        return response.users.compactMap { user in
            guard let id = user.uuid ?? user.id.map(String.init) else {
                return nil
            }
            return PlexHomeUser(
                id: id,
                name: user.title.nonEmpty
                    ?? user.username.nonEmpty
                    ?? "Plex User",
                requiresPIN: user.protected
                    ?? user.hasPassword
                    ?? false,
                isAdmin: user.admin ?? false,
                isRestricted: user.restricted ?? false,
                avatarURL: user.thumb.nonEmpty.flatMap(URL.init(string:)))
        }
    }

    /// Return the token belonging to the selected profile.
    ///
    /// The owner already holds the account token. Every other Home user gets a
    /// switched token, with a PIN supplied only for protected profiles. The PIN
    /// is never returned or stored.
    public func token(
        for user: PlexHomeUser,
        accountToken: String,
        pin: String? = nil
    ) async throws -> String {
        if user.isAdmin { return accountToken }
        let authedClient = client.withDefaultHeaders([
            "X-Plex-Token": accountToken,
        ])
        let response = try await authedClient.send(
            Endpoint(
                method: .post,
                path: "api/v2/home/users/\(user.id)/switch",
                query: pin.flatMap { $0.isEmpty ? nil : [
                    URLQueryItem(name: "pin", value: $0),
                ] } ?? []),
            as: PlexHomeSwitchResponse.self)
        guard let switched = response.authToken.nonEmpty
                ?? response.authenticationToken.nonEmpty else {
            throw MozzError.unauthorized
        }
        return switched
    }

    /// Discover the account's servers. Plex returns resources (servers), each
    /// with several connection addresses; keep one reachable address per machine
    /// id rather than registering every address as a separate server.
    /// Every address the account advertises for every server it owns.
    ///
    /// `askingTheNetwork` adds a local sweep, and defaults to off. It is a
    /// second or two and a few thousand datagrams, and it earns that only when
    /// the advertised addresses have already failed — which is exactly when
    /// ``resolveConnection`` turns it on. A server that advertises a usable
    /// address, which is nearly all of them, should not pay for the ones that
    /// do not.
    public func discoverConnections(
        accountToken: String, askingTheNetwork: Bool = false
    ) async throws -> [PlexResourceConnection] {
        let authedClient = client.withDefaultHeaders(["X-Plex-Token": accountToken])
        // Asked concurrently. The network answers in about two seconds and
        // plex.tv in rather less, and paying for them one after the other would
        // put the slower of the two in front of every sign-in.
        async let discoveredLocally = askingTheNetwork ? localServers() : []
        let resources = try await authedClient.send(
            Endpoint(path: "api/v2/resources", query: [
                URLQueryItem(name: "includeHttps", value: "1"),
                URLQueryItem(name: "includeRelay", value: "1"),
            ]),
            as: [PlexResource].self
        )
        let local = await discoveredLocally
        var connections: [PlexResourceConnection] = []
        for resource in resources where (resource.provides ?? "").contains("server") {
            guard let accessToken = resource.accessToken else { continue }
            let machineIdentifier = resource.clientIdentifier.nonEmpty
            var candidates: [PlexResourceConnection] = []
            for dto in resource.connections ?? [] {
                guard let uriString = dto.uri, let uri = URL(string: uriString) else { continue }
                candidates.append(PlexResourceConnection(
                    serverName: resource.name ?? "Plex",
                    clientIdentifier: machineIdentifier ?? clientIdentifier,
                    serverMachineIdentifier: machineIdentifier,
                    uri: uri,
                    isLocal: dto.local ?? false,
                    isRelay: dto.relay ?? false,
                    accessToken: accessToken
                ))
            }
            // What the network said, ahead of what the account claims.
            //
            // A server only advertises the addresses it believes it has, and
            // one inside a Docker bridge network believes it is at its
            // container address — which nothing outside that host can reach.
            // plex.tv repeats that belief faithfully. The reply to a local
            // probe comes FROM the address that actually works, which is the
            // one piece of information neither the server nor plex.tv has.
            if let machineIdentifier,
               let nearby = local.first(where: { $0.machineIdentifier == machineIdentifier }),
               let uri = PlexGDMParser.localURL(
                host: nearby.host, port: nearby.port,
                borrowingCertificateFrom: candidates.map(\.uri)),
               !candidates.contains(where: { $0.uri == uri }) {
                candidates.append(PlexResourceConnection(
                    serverName: resource.name ?? nearby.name,
                    clientIdentifier: machineIdentifier,
                    serverMachineIdentifier: machineIdentifier,
                    uri: uri,
                    isLocal: true,
                    isRelay: false,
                    accessToken: accessToken
                ))
            }
            connections.append(contentsOf: candidates.sorted(by: Self.preferLocal))
        }

        return connections
    }

    /// Probe candidates in preference order and return the first that answers,
    /// so the app pins the fastest working address (local LAN over relay).
    /// Probes use `probeTransport` (a tight discovery timeout), so an unreachable
    /// candidate is abandoned in a few seconds rather than blocking on the 12s
    /// interactive timeout.
    public func firstReachableConnection(
        _ connections: [PlexResourceConnection]
    ) async -> PlexResourceConnection? {
        await firstAnswering(connections) ?? connections.first
    }

    /// The first candidate that actually answers, or nil when none of them does.
    ///
    /// The difference from ``firstReachableConnection`` is the whole point:
    /// there is no consolation prize. Sign-in wants a best guess when nothing
    /// answers, because a guess is better than refusing to sign in; repair wants
    /// the truth, because a guess would overwrite a stored address with a worse
    /// one.
    private func firstAnswering(
        _ connections: [PlexResourceConnection],
        expecting machineIdentifier: String? = nil
    ) async -> PlexResourceConnection? {
        guard !connections.isEmpty else { return nil }
        // Probed together. Sequentially, a dead LAN address costs its full
        // timeout before the working one is even tried, and a server advertises
        // several.
        var probed: [ProbedConnection] = []
        await withTaskGroup(of: ProbedConnection?.self) { group in
            for connection in connections {
                group.addTask { await self.probe(connection) }
            }
            for await result in group {
                if let result { probed.append(result) }
            }
        }

        // Nil, not `connections.first`. Returning an address this just proved
        // does not answer is how a library gets pinned to one that never works
        // again: `resolveConnection` reads nil as "none of these", and with a
        // fallback here that guard could never fire, so re-resolution kept
        // handing back the dead address and the caller kept believing it.
        let trimmed = machineIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = (trimmed?.isEmpty == false) ? trimmed : nil
        return probed.min { lhs, rhs in
            Self.order(lhs, wanting: wanted) < Self.order(rhs, wanting: wanted)
        }?.connection
    }

    /// How good an answered address is, best first.
    ///
    /// Identity before speed: an address that says it is the server we asked
    /// for beats a fast one that says it is something else, and a mismatch is
    /// only *demoted* rather than rejected — plex.tv's own id for a resource
    /// and the id a server reports for itself are not always the same string,
    /// and refusing on that would lock people out of servers that work.
    ///
    /// Then local before remote before relay, because that is the order of how
    /// much of the listener's bandwidth the audio has to cross — a relay in
    /// particular is throttled by Plex and will not carry a big file.
    ///
    /// Then measured latency, which is the part the old code had no way to
    /// consider: it took the first answer in tier order, so two working local
    /// addresses were decided by whichever plex.tv happened to list first.
    private static func order(
        _ probed: ProbedConnection, wanting machineIdentifier: String?
    ) -> (Int, Int, Double) {
        var identity = 0
        if let machineIdentifier,
           let reported = probed.machineIdentifier, !reported.isEmpty {
            identity = reported == machineIdentifier ? 0 : 1
        }
        return (identity, rank(probed.connection), probed.seconds)
    }

    /// Servers that answered on this network, or none — a device on cellular,
    /// a network that blocks broadcast, or simply no server nearby. Never
    /// throws and never blocks longer than its own timeout: discovery failing
    /// must cost the advertised addresses nothing.
    private func localServers() async -> [PlexLocalServer] {
        guard let localDiscovery else { return [] }
        return await localDiscovery.discover(timeout: 2)
    }

    /// One tight-timeout `identity` request — the cheapest thing a Plex server
    /// will answer, and it needs no library to exist.
    private func answers(_ connection: PlexResourceConnection) async -> Bool {
        await probe(connection) != nil
    }

    /// What one probe learned: that the address answered, how quickly, and
    /// which server was on the other end.
    private struct ProbedConnection {
        let connection: PlexResourceConnection
        let machineIdentifier: String?
        let seconds: Double
    }

    /// Ask an address who it is, and time how long it took to say so.
    ///
    /// The body is read rather than discarded because "something answered" is
    /// weaker than it sounds: a captive portal answers, and so does a different
    /// Plex server that happens to be at an address this account once used.
    private func probe(_ connection: PlexResourceConnection) async -> ProbedConnection? {
        let client = HTTPClient(
            baseURL: connection.uri,
            transport: probeTransport,
            defaultHeaders: PlexHeaders.common(clientInfo: clientInfo, clientIdentifier: clientIdentifier, token: connection.accessToken),
            retryPolicy: .none
        )
        let started = Date()
        guard let response = try? await client.send(
            Endpoint(path: "identity"), as: PlexContainerResponse.self) else { return nil }
        return ProbedConnection(
            connection: connection,
            machineIdentifier: response.MediaContainer.machineIdentifier,
            seconds: Date().timeIntervalSince(started))
    }

    /// Probe candidates in preference order and return the first whose SERVER has
    /// a music (`artist`) library WITH CONTENT. The account may own several
    /// servers (a movies-only box, a music box, a placeholder library with no
    /// tracks…); picking by reachability alone — or by the mere presence of an
    /// artist section — can strand the user on an EMPTY music library while their
    /// real music lives on another server. So we prefer a server whose artist
    /// section reports a non-zero item count, then fall back to any server with a
    /// music section, then the first reachable one, then the first candidate.
    public func firstMusicConnection(
        _ connections: [PlexResourceConnection]
    ) async -> PlexResourceConnection? {
        var firstReachable: PlexResourceConnection?
        var firstWithAnyMusic: PlexResourceConnection?
        for connection in connections {
            let probe = HTTPClient(
                baseURL: connection.uri,
                transport: probeTransport,
                defaultHeaders: PlexHeaders.common(clientInfo: clientInfo, clientIdentifier: clientIdentifier, token: connection.accessToken),
                retryPolicy: .none
            )
            guard let response = try? await probe.send(
                Endpoint(path: "library/sections"), as: PlexContainerResponse.self
            ) else { continue }
            if firstReachable == nil { firstReachable = connection }
            let musicKeys = (response.MediaContainer.Directory ?? [])
                .filter { $0.type == "artist" }
                .compactMap(\.key)
            guard !musicKeys.isEmpty else { continue }
            if firstWithAnyMusic == nil { firstWithAnyMusic = connection }
            // Prefer a music library that actually has artists in it.
            for key in musicKeys {
                let counted = try? await probe.send(
                    Endpoint(path: "library/sections/\(key)/all", query: [
                        URLQueryItem(name: "type", value: "8"),
                        URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
                        URLQueryItem(name: "X-Plex-Container-Size", value: "0"),
                    ]), as: PlexContainerResponse.self)
                if (counted?.MediaContainer.totalSize ?? 0) > 0 { return connection }
            }
        }
        return firstWithAnyMusic ?? firstReachable ?? connections.first
    }

    /// One-call convenience: discover connections, pick one, and produce the
    /// session to persist. The UI can instead call the steps individually.
    public func completeLogin(
        accountToken: String,
        plexUserID: String? = nil
    ) async throws -> AuthenticatedSession {
        let connections = try await discoverConnections(accountToken: accountToken)
        // Prefer a server that has music (the account may have several servers).
        guard let chosen = await firstMusicConnection(connections) else {
            throw MozzError.notFound
        }
        return session(from: chosen, accountToken: accountToken, plexUserID: plexUserID)
    }

    /// Re-resolve the working address of a server the app is ALREADY signed in
    /// to, and return it as a session to persist.
    ///
    /// This is the repair for a pinned address that has stopped answering.
    /// Plex hands out several addresses for one machine — LAN, remote, relay —
    /// and which of them works depends on the network the device is on and on
    /// whether Plex's own relay infrastructure is up. Sign-in picks one and, on
    /// its own, would keep it forever: when that one dies the library looks
    /// broken rather than unreachable.
    ///
    /// The point of `machineIdentifier` is that it, not the address, is the
    /// server. Given one, this stays on the same machine and only changes how
    /// the app gets there. Without one — an account linked before it was
    /// recorded — it falls back to matching the stored name, and only if that
    /// finds nothing does it widen to "any server of this account with music on
    /// it", which is the same choice sign-in makes.
    ///
    /// The caller keeps its existing server id: identity belongs to the account,
    /// and re-deriving it from the new address would orphan the catalogue, the
    /// likes and the play history. See ADR-0017.
    public func resolveConnection(
        accountToken: String,
        machineIdentifier: String? = nil,
        serverName: String? = nil
    ) async throws -> AuthenticatedSession {
        let advertised = try await discoverConnections(accountToken: accountToken)
        guard !advertised.isEmpty else { throw MozzError.notFound }
        if let chosen = await choose(
            from: advertised, machineIdentifier: machineIdentifier, serverName: serverName) {
            return session(from: chosen, accountToken: accountToken)
        }

        // Nothing the account advertises answers. Only now is the local sweep
        // worth its second or two: a server whose advertised local address is
        // one it cannot actually be reached at — a container's own address,
        // say — is invisible to plex.tv and obvious to the network it sits on.
        let withLocal = try await discoverConnections(
            accountToken: accountToken, askingTheNetwork: true)
        guard let chosen = await choose(
            from: withLocal, machineIdentifier: machineIdentifier, serverName: serverName) else {
            throw MozzError.serverUnreachable
        }
        return session(from: chosen, accountToken: accountToken)
    }

    /// The best address for one server among `connections`, or nil if none of
    /// them answers.
    ///
    /// Matched by machine identifier where there is one, because that — not the
    /// address — is the server. Falling back to the stored name covers accounts
    /// linked before the identifier was recorded, and only then does it widen
    /// to "any server of this account with music on it", which is the same
    /// choice sign-in makes.
    private func choose(
        from connections: [PlexResourceConnection],
        machineIdentifier: String?,
        serverName: String?
    ) async -> PlexResourceConnection? {
        var candidates: [PlexResourceConnection] = []
        if let machineIdentifier, !machineIdentifier.isEmpty {
            candidates = connections.filter { $0.clientIdentifier == machineIdentifier }
        }
        if candidates.isEmpty, let serverName, !serverName.isEmpty {
            candidates = connections.filter { $0.serverName == serverName }
        }
        if !candidates.isEmpty {
            return await firstAnswering(candidates, expecting: machineIdentifier)
        }
        guard let chosen = await firstMusicConnection(connections),
              await answers(chosen) else { return nil }
        return chosen
    }

    private func session(from chosen: PlexResourceConnection, accountToken: String,
                         plexUserID: String? = nil) -> AuthenticatedSession {
        AuthenticatedSession(
            kind: .plex,
            baseURL: chosen.uri,
            token: chosen.accessToken,
            userID: plexUserID,
            serverName: chosen.serverName,
            clientIdentifier: clientIdentifier,
            serverMachineIdentifier: chosen.serverMachineIdentifier,
            accountToken: accountToken
        )
    }

    private static func preferLocal(_ lhs: PlexResourceConnection, _ rhs: PlexResourceConnection) -> Bool {
        rank(lhs) < rank(rhs)
    }

    /// Local, then remote, then relay. Plex throttles its relay hard enough
    /// that a lossless file will not stream over it.
    private static func rank(_ connection: PlexResourceConnection) -> Int {
        if connection.isRelay { return 2 }
        return connection.isLocal ? 0 : 1
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}
