import XCTest
import Foundation
import MozzCore
import MozzDatabase
import MozzSubsonic
@testable import MozzFFI

/// Tests for the server half of the session facade — sign-in, attach, sync and
/// stream/artwork URL resolution.
///
/// These deliberately drive **Subsonic**, because Subsonic resolves both a
/// stream URL and an artwork URL by pure construction: no network, no server,
/// fully deterministic. That makes it possible to assert the interesting thing —
/// that a URL crossing the FFI boundary is correctly formed and correctly
/// authenticated — without a live server or a mock HTTP stack.
///
/// The network-dependent paths (`connect`, `sync`) are tested for their failure
/// contracts only: a command that needs an attached server must say so rather
/// than crash, which is the property a foreign-language client actually depends
/// on when its user has not signed in yet.
final class MozzSessionServerTests: XCTestCase {

    // MARK: Helpers

    private func makeLibrary() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mozz-server-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.sqlite").path
    }

    private func call(_ handle: Int64, _ request: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: request)
        let json = String(data: data, encoding: .utf8)!
        let ptr = json.withCString { mozz_session_call(handle, $0) }
        let responsePtr = try XCTUnwrap(ptr)
        defer { mozz_ffi_free_string(responsePtr) }
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(String(cString: responsePtr).utf8)) as? [String: Any]
        )
    }

    private func open(_ path: String) throws -> Int64 {
        let handle = path.withCString { mozz_session_open($0) }
        XCTAssertGreaterThan(handle, 0)
        return handle
    }

    private var subsonicToken: String {
        SubsonicCredential.md5(username: "brandon", password: "hunter2").encoded()
    }

    private func attachSubsonic(_ handle: Int64, baseURL: String = "https://music.example.com") throws -> String {
        let response = try call(handle, [
            "cmd": "attach",
            "kind": "subsonic",
            "baseURL": baseURL,
            "token": subsonicToken,
            "username": "brandon",
            "serverName": "Test Navidrome",
            "clientIdentifier": "test-client",
        ])
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let payload = try XCTUnwrap(response["payload"] as? [String: Any])
        return try XCTUnwrap(payload["serverId"] as? String)
    }

    // MARK: Attach

    func testAttachRegistersServerAndPersistsIt() async throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let serverId = try attachSubsonic(handle)
        // Subsonic scopes by username as well as URL, because one server can hold
        // several accounts with genuinely different libraries.
        XCTAssertEqual(serverId, "subsonic-brandon-https://music.example.com")

        // `attach` must also write the server row, or a client that attaches and
        // then browses sees an empty server list despite being connected.
        let servers = try call(handle, ["cmd": "servers"])
        let rows = try XCTUnwrap(servers["payload"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["id"] as? String, serverId)
        XCTAssertEqual(rows[0]["kind"] as? String, "subsonic")
        XCTAssertEqual(rows[0]["name"] as? String, "Test Navidrome")
    }

    func testAttachRejectsAnUnknownKind() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, [
            "cmd": "attach", "kind": "spotify",
            "baseURL": "https://example.com", "token": "x",
        ])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertNotNil(response["error"])
    }

    func testAttachRejectsASubsonicTokenThatIsNotACredential() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        // A raw password is the mistake a client is most likely to make, since
        // that is what the other two backends take.
        let response = try call(handle, [
            "cmd": "attach", "kind": "subsonic",
            "baseURL": "https://music.example.com", "token": "hunter2",
        ])
        XCTAssertEqual(response["ok"] as? Bool, false)
    }

    // MARK: Stream URLs

    func testStreamURLResolvesForASyncedTrack() async throws {
        let path = try makeLibrary()
        let serverId = "subsonic-brandon-https://music.example.com"

        // Seed under the same id the attach will produce, so the track lookup
        // and the backend agree about which server owns the row.
        let db = try MusicDatabase.open(at: URL(fileURLWithPath: path))
        try await SyntheticCatalog(db).generate(
            serverId: serverId, size: .init(artists: 2, albums: 4, tracks: 20))

        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }
        _ = try attachSubsonic(handle)

        let tracks = try call(handle, ["cmd": "tracks", "serverId": serverId, "limit": 1])
        let first = try XCTUnwrap((tracks["payload"] as? [[String: Any]])?.first)
        let remoteId = try XCTUnwrap(first["remoteId"] as? String)

        let response = try call(handle, [
            "cmd": "streamURL", "serverId": serverId, "remoteId": remoteId,
        ])
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let payload = try XCTUnwrap(response["payload"] as? [String: Any])
        let urlString = try XCTUnwrap(payload["url"] as? String)
        let url = try XCTUnwrap(URL(string: urlString))

        XCTAssertEqual(url.host, "music.example.com")
        // Subsonic's REST endpoints are `/rest/<method>.view`.
        XCTAssertEqual(url.path, "/rest/stream.view", "unexpected path \(url.path)")

        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let named = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(named["id"], remoteId)
        // The signed credential must be on the URL: the audio engine fetches this
        // with a plain HTTP client that knows nothing about Subsonic auth.
        XCTAssertNotNil(named["t"], "missing MD5 token")
        XCTAssertNotNil(named["s"], "missing salt")
        // The password itself must never appear.
        XCTAssertNil(named["p"])
        XCTAssertFalse(urlString.contains("hunter2"))
    }

    func testStreamURLWithoutAttachIsAClearError() async throws {
        let path = try makeLibrary()
        let db = try MusicDatabase.open(at: URL(fileURLWithPath: path))
        try await SyntheticCatalog(db).generate(
            serverId: SyntheticCatalog.defaultServerID,
            size: .init(artists: 1, albums: 1, tracks: 5))

        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, [
            "cmd": "streamURL",
            "serverId": SyntheticCatalog.defaultServerID,
            "remoteId": "anything",
        ])
        XCTAssertEqual(response["ok"] as? Bool, false)
        let error = try XCTUnwrap(response["error"] as? String)
        XCTAssertTrue(error.contains("attached"), "unhelpful error: \(error)")
    }

    func testStreamURLForAMissingTrackNamesTheTrack() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }
        let serverId = try attachSubsonic(handle)

        let response = try call(handle, [
            "cmd": "streamURL", "serverId": serverId, "remoteId": "does-not-exist",
        ])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertTrue(try XCTUnwrap(response["error"] as? String).contains("does-not-exist"))
    }

    // MARK: Artwork

    func testArtworkURLIsSignedAndSized() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }
        let serverId = try attachSubsonic(handle)

        let response = try call(handle, [
            "cmd": "artworkURL", "serverId": serverId, "artworkKey": "al-42", "size": 256,
        ])
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let payload = try XCTUnwrap(response["payload"] as? [String: Any])
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(payload["url"] as? String)))
        let named = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(named["id"], "al-42")
        XCTAssertEqual(named["size"], "256")
        XCTAssertNotNil(named["t"])
    }

    // MARK: Account

    func testAccountReturnsSignedInIdentityAndExplicitNullAvatar() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }
        let serverId = try attachSubsonic(handle)

        let response = try call(handle, [
            "cmd": "account", "serverId": serverId, "size": 120,
        ])
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        XCTAssertEqual(response["cmd"] as? String, "account")
        let payload = try XCTUnwrap(response["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["avatarURL", "displayName", "username"])
        XCTAssertEqual(payload["displayName"] as? String, "brandon")
        XCTAssertEqual(payload["username"] as? String, "brandon")
        XCTAssertTrue(payload["avatarURL"] is NSNull, "Subsonic has no real account photo")
    }

    func testAccountWithoutAttachIsAClearError() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, ["cmd": "account", "serverId": "missing"])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertTrue(try XCTUnwrap(response["error"] as? String).contains("attached"))
    }

    func testAccountCommandIsAdvertised() {
        XCTAssertTrue(mozzSessionCommands.contains("account"))
    }

    // MARK: Sync lifecycle

    func testSyncWithoutAttachIsAClearError() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, ["cmd": "sync", "serverId": "nope"])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertTrue(try XCTUnwrap(response["error"] as? String).contains("attached"))
    }

    func testSyncStatusStartsIdleForAnAttachedServer() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }
        let serverId = try attachSubsonic(handle)

        let response = try call(handle, ["cmd": "syncStatus", "serverId": serverId])
        XCTAssertEqual(response["ok"] as? Bool, true)
        let payload = try XCTUnwrap(response["payload"] as? [String: Any])
        XCTAssertEqual(payload["running"] as? Bool, false)
        XCTAssertEqual(payload["finished"] as? Bool, false)
        XCTAssertEqual(payload["itemsSynced"] as? Int, 0)
    }

    /// A sync against an unreachable host must land in `finished` + `error`
    /// rather than running forever — a client polls this, and a status that
    /// never resolves is a spinner that never stops.
    func testFailedSyncReportsFinishedWithAnError() async throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }
        // Reserved TEST-NET-1 address: guaranteed not to route anywhere.
        let serverId = try attachSubsonic(handle, baseURL: "http://192.0.2.1:4533")

        let started = try call(handle, ["cmd": "sync", "serverId": serverId])
        XCTAssertEqual(
            try XCTUnwrap(started["payload"] as? [String: Any])["started"] as? Bool, true)

        // Poll exactly as a client would.
        var status: [String: Any] = [:]
        for _ in 0..<120 {
            let response = try call(handle, ["cmd": "syncStatus", "serverId": serverId])
            status = try XCTUnwrap(response["payload"] as? [String: Any])
            if status["finished"] as? Bool == true { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertEqual(status["finished"] as? Bool, true, "sync never finished: \(status)")
        XCTAssertEqual(status["running"] as? Bool, false)
        XCTAssertNotNil(status["error"], "a failed sync must report why")
    }

    func testSecondSyncWhileRunningIsRefusedNotQueued() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }
        let serverId = try attachSubsonic(handle, baseURL: "http://192.0.2.1:4533")

        let first = try call(handle, ["cmd": "sync", "serverId": serverId])
        XCTAssertEqual(
            try XCTUnwrap(first["payload"] as? [String: Any])["started"] as? Bool, true)

        // Immediately again: the first is still connecting to a black-hole
        // address, so this must be refused rather than starting a second mirror.
        let second = try call(handle, ["cmd": "sync", "serverId": serverId])
        let payload = try XCTUnwrap(second["payload"] as? [String: Any])
        XCTAssertEqual(payload["started"] as? Bool, false)
        XCTAssertEqual(payload["reason"] as? String, "already running")
    }

    // MARK: Sign-in contracts

    func testConnectValidatesItsArgumentsBeforeTouchingTheNetwork() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        for request in [
            ["cmd": "connect"],
            ["cmd": "connect", "kind": "jellyfin"],
            ["cmd": "connect", "kind": "jellyfin", "baseURL": "https://jf.example.com"],
            ["cmd": "connect", "kind": "subsonic", "baseURL": "https://ss.example.com"],
            // Subsonic with a username but neither password nor apiKey.
            ["cmd": "connect", "kind": "subsonic",
             "baseURL": "https://ss.example.com", "username": "brandon"],
        ] {
            let response = try call(handle, request)
            XCTAssertEqual(response["ok"] as? Bool, false, "\(request) should have failed")
        }
    }

    /// Plex has no third-party password endpoint. Saying so explicitly is worth
    /// a test: a client author who guesses will otherwise get a network error
    /// and conclude the server is down.
    func testPlexConnectPointsAtThePinFlow() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, [
            "cmd": "connect", "kind": "plex", "baseURL": "https://plex.example.com",
            "username": "brandon", "password": "hunter2",
        ])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertTrue(try XCTUnwrap(response["error"] as? String).lowercased().contains("pin"))
    }

    // MARK: Identity
    //
    // `connect` and `attach` derive the server id independently, and a client
    // persists the one `connect` returned and passes it to every later call. If
    // the two disagree the backend is registered under one id and looked up
    // under another: sync, streaming and artwork all fail with "needs an
    // attached serverId" while plain browsing still works, because that queries
    // across every backend. That is a maddening bug to diagnose from the
    // symptoms, so it gets a test rather than a comment.

    func testConnectAndAttachAgreeOnTheSubsonicServerId() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let attachId = try attachSubsonic(handle)
        let connectId = wire(AuthenticatedSession(
            kind: .subsonic,
            baseURL: URL(string: "https://music.example.com")!,
            token: subsonicToken,
            // Subsonic's authenticator puts the username here.
            userID: "brandon",
            serverName: "Test Navidrome",
            clientIdentifier: "test-client"
        )).serverId

        XCTAssertEqual(connectId, attachId)
    }

    /// Only Subsonic scopes by username. Plex scopes by machine id when the
    /// resources API supplies it; folding a Jellyfin or Plex user id into
    /// the id would silently orphan every catalog row the iOS app has written,
    /// because iOS derives those without one.
    func testOnlySubsonicScopesTheServerIdByUser() {
        let jellyfin = wire(AuthenticatedSession(
            kind: .jellyfin,
            baseURL: URL(string: "https://jf.example.com")!,
            token: "t", userID: "user-guid-1234",
            serverName: "JF", clientIdentifier: "c"))
        XCTAssertEqual(jellyfin.serverId, "jellyfin-https://jf.example.com")

        let plex = wire(AuthenticatedSession(
            kind: .plex,
            baseURL: URL(string: "https://plex.example.com")!,
            token: "t", userID: "12345",
            serverName: "Plex", clientIdentifier: "c",
            serverMachineIdentifier: "machine-1"))
        XCTAssertEqual(plex.serverId, "plex-machine-1")

        let legacyPlex = wire(AuthenticatedSession(
            kind: .plex,
            baseURL: URL(string: "https://plex.example.com")!,
            token: "t", userID: "12345",
            serverName: "Plex", clientIdentifier: "c"))
        XCTAssertEqual(legacyPlex.serverId, "plex-https://plex.example.com")
    }

    /// A Subsonic server with two accounts is two libraries, and they must not
    /// be mirrored on top of each other.
    func testTwoSubsonicAccountsOnOneServerGetDistinctIds() {
        func identity(_ user: String) -> String {
            wire(AuthenticatedSession(
                kind: .subsonic,
                baseURL: URL(string: "https://music.example.com")!,
                token: "t", userID: user,
                serverName: "N", clientIdentifier: "c")).serverId
        }
        XCTAssertNotEqual(identity("brandon"), identity("guest"))
        // Case-insensitive, matching the iOS derivation.
        XCTAssertEqual(identity("Brandon"), identity("brandon"))
    }

    // MARK: Paging across the boundary

    /// A client walks a listing by echoing `nextCursor` back. This asserts the
    /// whole loop through the C ABI: every row exactly once, and a terminating
    /// end signal rather than a page that repeats forever.
    func testCursorPagingWalksTheWholeListingThroughTheABI() async throws {
        let path = try makeLibrary()
        let serverId = SyntheticCatalog.defaultServerID
        let db = try MusicDatabase.open(at: URL(fileURLWithPath: path))
        try await SyntheticCatalog(db).generate(
            serverId: serverId, size: .init(artists: 20, albums: 40, tracks: 500))

        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        var ids: [Int] = []
        var cursor: String?
        var pages = 0
        repeat {
            var request: [String: Any] = ["cmd": "tracks", "serverId": serverId, "limit": 50]
            if let cursor { request["cursor"] = cursor }
            let response = try call(handle, request)
            XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
            let rows = try XCTUnwrap(response["payload"] as? [[String: Any]])
            ids.append(contentsOf: rows.compactMap { $0["id"] as? Int })
            cursor = response["nextCursor"] as? String
            pages += 1
            XCTAssertLessThan(pages, 50, "paging did not terminate")
        } while cursor != nil

        XCTAssertEqual(ids.count, 500)
        XCTAssertEqual(Set(ids).count, 500, "a track came back on two pages")
    }

    /// A mangled cursor restarts the listing rather than failing. It can only
    /// come from a client that damaged a token we issued, and showing the first
    /// page beats showing an error.
    func testAGarbageCursorRestartsRatherThanFailing() async throws {
        let path = try makeLibrary()
        let serverId = SyntheticCatalog.defaultServerID
        let db = try MusicDatabase.open(at: URL(fileURLWithPath: path))
        try await SyntheticCatalog(db).generate(
            serverId: serverId, size: .init(artists: 2, albums: 4, tracks: 30))

        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, [
            "cmd": "tracks", "serverId": serverId, "limit": 10, "cursor": "not-a-real-cursor",
        ])
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual((response["payload"] as? [[String: Any]])?.count, 10)
    }

    /// The last page must omit the cursor, or a client loops forever.
    func testTheFinalPageReportsNoCursor() async throws {
        let path = try makeLibrary()
        let serverId = SyntheticCatalog.defaultServerID
        let db = try MusicDatabase.open(at: URL(fileURLWithPath: path))
        try await SyntheticCatalog(db).generate(
            serverId: serverId, size: .init(artists: 2, albums: 4, tracks: 30))

        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, ["cmd": "tracks", "serverId": serverId, "limit": 100])
        XCTAssertEqual((response["payload"] as? [[String: Any]])?.count, 30)
        XCTAssertNil(response["nextCursor"], "a short page must not offer a cursor")
    }

    /// ReplayGain has to survive the boundary or a non-Apple client cannot level
    /// a library at all. It did not: the column was populated by sync and read
    /// by iOS, and simply absent from the wire type, so the desktop engine —
    /// which accepts a gain and applies it correctly — was never given one.
    func testTrackGainSurvivesTheBoundary() async throws {
        let path = try makeLibrary()
        let serverId = SyntheticCatalog.defaultServerID
        let db = try MusicDatabase.open(at: URL(fileURLWithPath: path))
        try await SyntheticCatalog(db).generate(
            serverId: serverId, size: .init(artists: 1, albums: 1, tracks: 4))

        // Set an unmistakable value rather than trusting the generator's, so a
        // pass proves the number travelled rather than that two defaults agreed.
        try await db.write { db in
            try db.execute(sql: "UPDATE track SET normalizationGainDB = -7.5 WHERE serverId = ?",
                           arguments: [serverId])
        }

        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, ["cmd": "tracks", "serverId": serverId, "limit": 4])
        let rows = try XCTUnwrap(response["payload"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 4)
        for row in rows {
            XCTAssertEqual(row["normalizationGainDB"] as? Double, -7.5)
        }
    }

    /// A track without a gain must come back with the key absent rather than a
    /// zero, because 0 dB is a real value meaning "already at reference" and a
    /// client cannot tell the two apart afterwards.
    func testAMissingGainIsAbsentRatherThanZero() async throws {
        let path = try makeLibrary()
        let serverId = SyntheticCatalog.defaultServerID
        let db = try MusicDatabase.open(at: URL(fileURLWithPath: path))
        try await SyntheticCatalog(db).generate(
            serverId: serverId, size: .init(artists: 1, albums: 1, tracks: 2))

        // The generator gives lossless tracks a gain, so clear it — Plex reports
        // none at all and that is the case being checked.
        try await db.write { db in
            try db.execute(sql: "UPDATE track SET normalizationGainDB = NULL WHERE serverId = ?",
                           arguments: [serverId])
        }

        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, ["cmd": "tracks", "serverId": serverId, "limit": 2])
        let rows = try XCTUnwrap(response["payload"] as? [[String: Any]])
        for row in rows {
            XCTAssertNil(row["normalizationGainDB"], "an absent gain must not encode as 0 dB")
        }
    }

    // MARK: Envelope
    func testUnknownCommandStillReportsUnknownAfterTheServerTable() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, ["cmd": "definitelyNotACommand"])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertTrue(
            try XCTUnwrap(response["error"] as? String).contains("unknown command"),
            "the server table must fall through, not swallow"
        )
    }

    /// A wrong command name is a mistake only makeable across the FFI boundary,
    /// and it is invisible: `streamUrl` for `streamURL` is one capital letter
    /// and produces nothing but "unknown command". It cost real time once.
    func testACaseMistakeNamesTheCommandItMeant() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, ["cmd": "streamUrl"])
        let error = try XCTUnwrap(response["error"] as? String)
        XCTAssertTrue(error.contains("streamURL"), "unhelpful: \(error)")
        XCTAssertTrue(error.contains("case"), "should say case matters: \(error)")
    }

    /// The command list backing that message is hand-maintained, because Swift
    /// cannot enumerate a switch. This keeps it honest: every listed command must
    /// actually dispatch, so a renamed or deleted case cannot leave the list
    /// advertising something that no longer exists.
    func testEveryAdvertisedCommandActuallyDispatches() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        for cmd in mozzSessionCommands {
            let response = try call(handle, ["cmd": cmd])
            // Most will fail for want of arguments — that is fine and expected.
            // What must never happen is the dispatcher not recognising the name.
            if let error = response["error"] as? String {
                XCTAssertFalse(
                    error.contains("unknown command"),
                    "'\(cmd)' is advertised but does not dispatch"
                )
            }
        }
    }

    func testHostIdentityIsPopulatedOnEveryPlatform() {
        XCTAssertFalse(mozzHostPlatform.isEmpty)
        XCTAssertNotEqual(mozzHostPlatform, "Unknown")
        XCTAssertFalse(mozzHostPlatformVersion.isEmpty)
        // Servers list this in the user's device list; a bare "0.0.0" means
        // ProcessInfo failed and the entry would be useless.
        XCTAssertNotEqual(mozzHostPlatformVersion, "0.0.0")
    }
}
