import Foundation
import XCTest
import MozzCommands
import MozzDatabase
import MozzSchema
import SwiftProtobuf
@testable import MozzFFI

/// The schema-described command surface, driven the way a non-Swift client
/// drives it: bytes in, bytes out, through the exported C entry point.
///
/// `MozzCommandsTests` covers the dispatcher; this covers the boundary it has to
/// cross, which is where the interesting failures live — allocation shape,
/// length handling, and whether the bytes survive at all.
final class MozzSessionInvokeTests: XCTestCase {

    private func makeLibrary() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoke-\(UUID().uuidString).sqlite").path
        return path
    }

    private func seed(_ path: String, albums: Int = 40) async throws {
        let db = try MusicDatabase.open(at: URL(fileURLWithPath: path))
        try await SyntheticCatalog(db).generate(
            serverId: SyntheticCatalog.defaultServerID,
            size: .init(artists: 20, albums: albums, tracks: albums * 10))
    }

    /// Send an encoded request through the C ABI and decode what comes back,
    /// releasing the buffer the way a client must.
    private func invoke(_ handle: Int64, _ request: Mozz_V1_Request) throws -> Mozz_V1_Response {
        let bytes = [UInt8](try request.serializedData())
        var length: Int32 = 0
        let pointer = bytes.withUnsafeBufferPointer { buffer in
            mozz_session_invoke(handle, buffer.baseAddress, Int32(bytes.count), &length)
        }
        guard let pointer else {
            XCTFail("invoke returned nothing")
            return Mozz_V1_Response()
        }
        defer { mozz_session_free_bytes(pointer) }
        let data = Data(UnsafeBufferPointer(start: pointer, count: Int(length)))
        return try Mozz_V1_Response(serializedBytes: data)
    }

    // MARK: The reason this entry point exists

    /// A request carrying a zero byte must survive the crossing.
    ///
    /// This is the whole justification for `mozz_session_invoke` rather than
    /// reusing `mozz_session_call`, and it is not a corner case: `libraries` is
    /// an empty message, so inside the command `oneof` it encodes as a tag plus
    /// a zero length — `08 03 52 00`. As a null-terminated C string that is
    /// `08 03 52`, which is a truncated message that will not parse. The
    /// simplest command in the schema cannot cross as a string.
    func testARequestContainingAZeroByteIsNotTruncated() async throws {
        let path = try makeLibrary()
        try await seed(path)
        let handle = mozz_session_open(path)
        defer { _ = mozz_session_close(handle) }

        var request = Mozz_V1_Request()
        request.id = 3
        request.libraries = Mozz_V1_LibrariesRequest()

        let encoded = try request.serializedData()
        XCTAssertTrue(encoded.contains(0), "this test is pointless if the request has no zero byte")

        let response = try invoke(handle, request)

        XCTAssertEqual(response.id, 3)
        // Reaching a real result at all proves the trailing zero byte survived;
        // a truncated request would have come back as a parse failure.
        guard case .libraries = response.result else {
            XCTFail("expected libraries, got \(String(describing: response.result))")
            return
        }
    }

    // MARK: Ordinary use

    func testAlbumsComeBackThroughTheABI() async throws {
        let path = try makeLibrary()
        try await seed(path)
        let handle = mozz_session_open(path)
        defer { _ = mozz_session_close(handle) }

        var albums = Mozz_V1_AlbumsRequest()
        albums.serverID = SyntheticCatalog.defaultServerID
        albums.limit = 5
        var request = Mozz_V1_Request()
        request.id = 11
        request.albums = albums

        let response = try invoke(handle, request)

        XCTAssertEqual(response.id, 11)
        guard case .albums(let payload) = response.result else {
            XCTFail("expected albums, got \(String(describing: response.result))")
            return
        }
        XCTAssertEqual(payload.albums.count, 5)
        XCTAssertTrue(payload.albums.allSatisfy { !$0.title.isEmpty })
    }

    /// Paging over the ABI, which is where the cursor has to survive being
    /// written down and handed back.
    func testCursorWalkOverTheABIVisitsEachAlbumOnce() async throws {
        let path = try makeLibrary()
        try await seed(path)
        let handle = mozz_session_open(path)
        defer { _ = mozz_session_close(handle) }

        var seen: [String] = []
        var cursor: Mozz_V1_PageCursor?
        var pages = 0

        repeat {
            var albums = Mozz_V1_AlbumsRequest()
            albums.serverID = SyntheticCatalog.defaultServerID
            albums.limit = 7
            if let cursor { albums.after = cursor }
            var request = Mozz_V1_Request()
            request.id = UInt64(pages)
            request.albums = albums

            let response = try invoke(handle, request)
            guard case .albums(let payload) = response.result else {
                XCTFail("page \(pages): \(String(describing: response.result))")
                return
            }
            seen.append(contentsOf: payload.albums.map(\.remoteID))
            cursor = payload.page.hasNext ? payload.page.next : nil
            pages += 1
            XCTAssertLessThan(pages, 50, "the walk did not terminate")
        } while cursor != nil

        XCTAssertGreaterThan(pages, 1, "one page means nothing was paged")
        XCTAssertEqual(Set(seen).count, seen.count, "an album came back twice")
    }

    // MARK: Refusing safely

    /// A bad handle must answer, not crash. There is no exception to catch on
    /// the other side of a C ABI.
    func testAnUnknownHandleFailsRatherThanCrashing() throws {
        var request = Mozz_V1_Request()
        request.id = 5
        request.libraries = Mozz_V1_LibrariesRequest()

        let response = try invoke(-1, request)

        guard case .failure(let failure) = response.result else {
            XCTFail("expected a failure for an unknown handle")
            return
        }
        XCTAssertTrue(failure.message.contains("handle"))
    }

    func testGarbageBytesFailRatherThanCrashing() async throws {
        let path = try makeLibrary()
        try await seed(path)
        let handle = mozz_session_open(path)
        defer { _ = mozz_session_close(handle) }

        let junk: [UInt8] = [0xFF, 0xFE, 0xFD, 0xFC]
        var length: Int32 = 0
        let pointer = junk.withUnsafeBufferPointer { buffer in
            mozz_session_invoke(handle, buffer.baseAddress, Int32(junk.count), &length)
        }
        let unwrapped = try XCTUnwrap(pointer)
        defer { mozz_session_free_bytes(unwrapped) }

        let response = try Mozz_V1_Response(
            serializedBytes: Data(UnsafeBufferPointer(start: unwrapped, count: Int(length))))
        guard case .failure = response.result else {
            XCTFail("malformed bytes must come back as a failure")
            return
        }
    }

    /// A null request pointer, or a zero length, is a client bug rather than a
    /// reason to take the process down with it.
    func testAnEmptyRequestIsRefused() async throws {
        let path = try makeLibrary()
        try await seed(path)
        let handle = mozz_session_open(path)
        defer { _ = mozz_session_close(handle) }

        var length: Int32 = 0
        let pointer = mozz_session_invoke(handle, nil, 0, &length)
        let unwrapped = try XCTUnwrap(pointer)
        defer { mozz_session_free_bytes(unwrapped) }

        let response = try Mozz_V1_Response(
            serializedBytes: Data(UnsafeBufferPointer(start: unwrapped, count: Int(length))))
        guard case .failure = response.result else {
            XCTFail("an empty request must come back as a failure")
            return
        }
    }

    /// The length is the only way a caller knows how much to read, so a caller
    /// that ignores the return value and trusts a stale length must not be led
    /// into reading a buffer that was never written.
    func testTheLengthIsZeroedBeforeAnythingElse() {
        var length: Int32 = 9_999
        let pointer = mozz_session_invoke(-1, nil, 0, &length)
        defer { if let pointer { mozz_session_free_bytes(pointer) } }

        XCTAssertNotEqual(length, 9_999, "the out-length was left at its previous value")
    }
}
