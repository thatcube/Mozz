import Foundation
import Testing
@testable import MozzDatabase

/// A page cursor has to survive being written down.
///
/// It crosses the FFI as a string, so every non-Swift client hands one back
/// having only ever seen the text. The repository's other paging tests pass the
/// `PageCursor` value straight through and never serialise it, which is exactly
/// how this went unnoticed: paging worked in Swift and failed on the second page
/// of albums everywhere else.
@Suite struct PageCursorTokenTests {

    private typealias Cursor = LibraryRepository.PageCursor

    @Test func anOrdinaryKeyRoundTrips() throws {
        let cursor = Cursor(keys: ["blue lines"], id: 42)
        let restored = try #require(Cursor(token: cursor.token))
        #expect(restored == cursor)
    }

    /// The regression.
    ///
    /// `albumGroupKey` is a composite that `AlbumGrouping` builds by joining
    /// with U+001F — the same character the token format used as its own
    /// separator. So one key came back as two, the seek clause was built for one
    /// while the arguments were bound for two, and SQLite rejected the statement
    /// with "wrong number of statement arguments".
    @Test func aKeyContainingTheSeparatorStillRoundTrips() throws {
        let key = "crimson garden\u{1F}id:art-12"
        let cursor = Cursor(keys: [key], id: 37)

        let restored = try #require(Cursor(token: cursor.token))

        #expect(restored.keys.count == 1, "the key was split into \(restored.keys.count) parts")
        #expect(restored.keys.first == key)
        #expect(restored.id == 37)
        #expect(restored == cursor)
    }

    @Test func severalKeysKeepTheirOrderAndBoundaries() throws {
        let cursor = Cursor(keys: ["a\u{1F}b", "", "c:d", "é🎧"], id: -9)
        let restored = try #require(Cursor(token: cursor.token))
        #expect(restored == cursor)
    }

    /// A token that cannot be read must be refused rather than guessed at.
    /// Quietly returning the first page would look, to someone scrolling, like
    /// the list jumping back to the top — repeatedly, since the bad cursor keeps
    /// coming back.
    @Test func unreadableTokensAreRefused() {
        #expect(Cursor(token: "not base64 at all!!") == nil)
        #expect(Cursor(token: "") == nil)
        // Valid base64, but not a cursor.
        #expect(Cursor(token: Data("hello".utf8).base64EncodedString()) == nil)
        // Well-formed parts, but the last one is not an id.
        let bogus = ["a", "b"].map { Data($0.utf8).base64EncodedString() }
            .joined(separator: "\u{1F}")
        #expect(Cursor(token: Data(bogus.utf8).base64EncodedString()) == nil)
    }

    /// End to end against real rows: the cursor the repository hands out must
    /// still work after a trip through its own text form.
    @Test func albumPagingSurvivesTheTokenItHandsOut() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-\(UUID().uuidString).sqlite")
        let db = try MusicDatabase.open(at: url)
        try await SyntheticCatalog(db).generate(
            serverId: SyntheticCatalog.defaultServerID,
            size: .init(artists: 16, albums: 50, tracks: 400))
        let repo = LibraryRepository(db)

        let first = try await repo.albumsPage(
            serverId: SyntheticCatalog.defaultServerID, after: nil, limit: 7)
        let handedOut = try #require(first.next)

        // The round trip a non-Swift client is forced to make.
        let asAClientWouldSendItBack = try #require(Cursor(token: handedOut.token))

        let second = try await repo.albumsPage(
            serverId: SyntheticCatalog.defaultServerID,
            after: asAClientWouldSendItBack,
            limit: 7)

        #expect(!second.rows.isEmpty)
        let firstIds = Set(first.rows.map(\.remoteId))
        #expect(second.rows.allSatisfy { !firstIds.contains($0.remoteId) },
                "the second page repeated rows from the first")
    }
}
