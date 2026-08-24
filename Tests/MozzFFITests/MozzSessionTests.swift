import XCTest
import Foundation
import MozzCore
import MozzDatabase
@testable import MozzFFI

/// Tests for the session facade — the API a Windows or Android client drives.
///
/// These go through the real C entry points rather than the Swift behind them,
/// because the things most likely to break live at the boundary: a handle that
/// outlives its session, a malformed request, a command name that no longer
/// exists. Calling the Swift directly would miss all three.
final class MozzSessionTests: XCTestCase {

    // MARK: Helpers

    private func makeLibrary() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mozz-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.sqlite").path
    }

    private func seed(_ path: String, tracks: Int = 200) async throws {
        let db = try MusicDatabase.open(at: URL(fileURLWithPath: path))
        try await SyntheticCatalog(db).generate(
            serverId: SyntheticCatalog.defaultServerID,
            size: .init(artists: 10, albums: 20, tracks: tracks)
        )
    }

    /// Call through the C ABI and decode, freeing the buffer exactly as a real
    /// client must.
    private func call(_ handle: Int64, _ request: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: request)
        let json = String(data: data, encoding: .utf8)!
        let ptr = json.withCString { mozz_session_call(handle, $0) }
        let responsePtr = try XCTUnwrap(ptr)
        defer { mozz_ffi_free_string(responsePtr) }
        let text = String(cString: responsePtr)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
    }

    private func open(_ path: String) throws -> Int64 {
        let handle = path.withCString { mozz_session_open($0) }
        XCTAssertGreaterThan(handle, 0, "session failed to open")
        return handle
    }

    // MARK: Lifecycle

    func testOpeningAndClosingASession() async throws {
        let path = try makeLibrary()
        try await seed(path)

        let handle = try open(path)
        XCTAssertEqual(mozz_session_close(handle), 1)
        // Closing twice reports "not live" rather than succeeding again.
        XCTAssertEqual(mozz_session_close(handle), 0)
    }

    func testOpeningAnImpossiblePathFails() {
        let bogus = "/dev/null/nope/library.sqlite"
        let handle = bogus.withCString { mozz_session_open($0) }
        XCTAssertEqual(handle, 0)
    }

    func testCallingAClosedHandleIsAnErrorNotACrash() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        _ = mozz_session_close(handle)

        // The whole reason handles are integers into a guarded table rather
        // than raw pointers: use-after-free becomes a message.
        let response = try call(handle, ["cmd": "ping"])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertEqual(response["error"] as? String, "unknown session handle")
    }

    func testMalformedRequestIsRejected() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let ptr = "not json at all".withCString { mozz_session_call(handle, $0) }
        let responsePtr = try XCTUnwrap(ptr)
        defer { mozz_ffi_free_string(responsePtr) }
        XCTAssertTrue(String(cString: responsePtr).contains("malformed request"))
    }

    func testUnknownCommandNamesItself() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, ["cmd": "teleport"])
        XCTAssertEqual(response["ok"] as? Bool, false)
        // Naming the command makes a client typo diagnosable from the response
        // alone, without the server-side logs a desktop app doesn't have.
        XCTAssertTrue((response["error"] as? String ?? "").contains("teleport"))
    }

    func testRequestIdIsEchoedForPipelining() throws {
        let path = try makeLibrary()
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, ["id": 4242, "cmd": "ping"])
        XCTAssertEqual(response["id"] as? Int, 4242)
    }

    // MARK: Reads

    func testCountsMatchTheSeededLibrary() async throws {
        let path = try makeLibrary()
        try await seed(path, tracks: 200)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, ["cmd": "counts"])
        XCTAssertEqual(response["ok"] as? Bool, true)
        let payload = try XCTUnwrap(response["payload"] as? [String: Any])
        XCTAssertEqual(payload["tracks"] as? Int, 200)
        XCTAssertEqual(payload["albums"] as? Int, 20)
    }

    /// Paging is by cursor now, not offset — see the note above the keyset
    /// methods in LibraryRepository for why. `offset` is still accepted on the
    /// request envelope so an older client's message decodes, but it no longer
    /// moves the window, and this asserts the cursor is what does.
    func testPagingWalksTheLibrary() async throws {
        let path = try makeLibrary()
        try await seed(path, tracks: 200)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let first = try call(handle, ["cmd": "tracks", "limit": 50])
        let cursor = try XCTUnwrap(first["nextCursor"] as? String,
                                   "a full page must offer somewhere to resume")
        let second = try call(handle, ["cmd": "tracks", "limit": 50, "cursor": cursor])

        let a = try XCTUnwrap(first["payload"] as? [[String: Any]])
        let b = try XCTUnwrap(second["payload"] as? [[String: Any]])
        XCTAssertEqual(a.count, 50)
        XCTAssertEqual(b.count, 50)

        // Distinct pages, or paging silently repeats the first screen forever.
        let idsA = Set(a.compactMap { $0["id"] as? Int })
        let idsB = Set(b.compactMap { $0["id"] as? Int })
        XCTAssertTrue(idsA.isDisjoint(with: idsB))
    }

    func testAnAbsurdLimitIsCapped() async throws {
        let path = try makeLibrary()
        try await seed(path, tracks: 2_000)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        // A client asking for the whole library in one allocation must not get it.
        let response = try call(handle, ["cmd": "tracks", "limit": 10_000_000])
        let rows = try XCTUnwrap(response["payload"] as? [[String: Any]])
        XCTAssertLessThanOrEqual(rows.count, 1_000)
    }

    func testSearchReturnsAllThreeSections() async throws {
        let path = try makeLibrary()
        try await seed(path, tracks: 500)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        let response = try call(handle, ["cmd": "search", "query": "a", "limit": 5])
        XCTAssertEqual(response["ok"] as? Bool, true)
        let payload = try XCTUnwrap(response["payload"] as? [String: Any])
        XCTAssertNotNil(payload["tracks"])
        XCTAssertNotNil(payload["albums"])
        XCTAssertNotNil(payload["artists"])
    }

    func testCommandsThatNeedAServerSayWhichArgumentIsMissing() async throws {
        let path = try makeLibrary()
        try await seed(path)
        let handle = try open(path)
        defer { _ = mozz_session_close(handle) }

        for cmd in ["playlists", "genres", "recentlyAddedAlbums"] {
            let response = try call(handle, ["cmd": cmd])
            XCTAssertEqual(response["ok"] as? Bool, false, cmd)
            XCTAssertTrue(
                (response["error"] as? String ?? "").contains("serverId"),
                "\(cmd) should name the missing argument"
            )
        }
    }

    func testTwoSessionsAreIndependent() async throws {
        let first = try makeLibrary()
        let second = try makeLibrary()
        try await seed(first, tracks: 100)
        try await seed(second, tracks: 300)

        let a = try open(first)
        let b = try open(second)
        defer { _ = mozz_session_close(b) }

        let countsA = try XCTUnwrap(try call(a, ["cmd": "counts"])["payload"] as? [String: Any])
        let countsB = try XCTUnwrap(try call(b, ["cmd": "counts"])["payload"] as? [String: Any])
        XCTAssertEqual(countsA["tracks"] as? Int, 100)
        XCTAssertEqual(countsB["tracks"] as? Int, 300)

        // Closing one must not disturb the other.
        _ = mozz_session_close(a)
        let stillB = try XCTUnwrap(try call(b, ["cmd": "counts"])["payload"] as? [String: Any])
        XCTAssertEqual(stillB["tracks"] as? Int, 300)
    }
}
