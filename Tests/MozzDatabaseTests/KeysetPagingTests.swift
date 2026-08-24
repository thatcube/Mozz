import XCTest
import GRDB
@testable import MozzDatabase

/// Paging a library that is being written to at the same time.
///
/// Mozz syncs in the background *while you browse*, so the table underneath a
/// paged listing is not stable. `LIMIT/OFFSET` counts rows skipped, so anything
/// inserted earlier in the sort order shifts every later page by one: rows get
/// shown twice and other rows are never shown at all, with nothing to indicate
/// it happened. The cursor form names the last row seen instead of counting, so
/// it cannot be shifted.
///
/// These use a deliberately small catalog with heavily repeated titles, which is
/// what the real generator produces and what makes the sort order non-unique —
/// the condition under which offset paging is at its worst.
final class KeysetPagingTests: XCTestCase {

    private func makeDatabase(tracks: Int) async throws -> MusicDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyset-\(UUID().uuidString).sqlite")
        let db = try MusicDatabase.open(at: url)
        try await SyntheticCatalog(db).generate(
            serverId: SyntheticCatalog.defaultServerID,
            size: .init(artists: tracks / 25, albums: tracks / 8, tracks: tracks)
        )
        return db
    }

    /// Walk the whole listing with no interference: every row exactly once.
    func testCursorWalkVisitsEveryTrackExactlyOnce() async throws {
        let db = try await makeDatabase(tracks: 2_000)
        let repo = LibraryRepository(db)

        var seen: [Int64] = []
        var cursor: LibraryRepository.PageCursor?
        var pages = 0
        repeat {
            let page = try await repo.tracksPage(
                serverId: SyntheticCatalog.defaultServerID, after: cursor, limit: 200)
            seen.append(contentsOf: page.rows.compactMap(\.id))
            cursor = page.next
            pages += 1
            XCTAssertLessThan(pages, 100, "cursor walk did not terminate")
        } while cursor != nil

        XCTAssertEqual(seen.count, 2_000)
        XCTAssertEqual(Set(seen).count, 2_000, "a track was returned twice")
    }

    /// The headline: rows arriving mid-walk must not corrupt the listing.
    ///
    /// The inserted titles begin with "A " so they sort near the front, which is
    /// the worst case — every insert lands *behind* the read position and shifts
    /// every subsequent offset.
    func testInsertsDuringAWalkDoNotDuplicateOrSkipRows() async throws {
        let db = try await makeDatabase(tracks: 2_000)
        let repo = LibraryRepository(db)
        let serverId = SyntheticCatalog.defaultServerID

        var seen: [Int64] = []
        var cursor: LibraryRepository.PageCursor?
        var inserted = 0
        var pages = 0

        repeat {
            let page = try await repo.tracksPage(serverId: serverId, after: cursor, limit: 200)
            seen.append(contentsOf: page.rows.compactMap(\.id))
            cursor = page.next
            pages += 1

            if cursor != nil, inserted < 10 {
                let n = inserted
                try await db.write { db in
                    try db.execute(sql: """
                        INSERT INTO track (serverId, remoteId, title, sortTitle, albumTitle,
                                           artistName, trackNumber, discNumber, duration, albumRemoteId)
                        VALUES (?, ?, ?, ?, 'X', 'Y', 1, 1, 100, 'a')
                        """, arguments: [serverId, "late-\(n)", "A late \(n)", "A late \(n)"])
                }
                inserted += 1
            }
            XCTAssertLessThan(pages, 100, "cursor walk did not terminate")
        } while cursor != nil

        XCTAssertEqual(inserted, 10, "the test did not actually interfere")
        XCTAssertEqual(Set(seen).count, seen.count, "\(seen.count - Set(seen).count) tracks shown twice")

        // Every original track must have been seen. The late arrivals sort before
        // the read position, so they are legitimately missed — that is the
        // correct behaviour for a listing being appended to behind you, and it
        // is quite different from silently losing rows that were always there.
        let original = try await db.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM track WHERE remoteId NOT LIKE 'late-%'")
        }
        XCTAssertEqual(Set(seen), Set(original), "an already-present track was never shown")
    }

    /// The same walk through the offset API, to show the difference is real and
    /// not a property of the test harness.
    func testOffsetPagingIsTheOneThatCorrupts() async throws {
        let db = try await makeDatabase(tracks: 2_000)
        let repo = LibraryRepository(db)
        let serverId = SyntheticCatalog.defaultServerID

        var seen: [Int64] = []
        var offset = 0
        var inserted = 0
        while true {
            let rows = try await repo.tracksPage(serverId: serverId, offset: offset, limit: 200)
            if rows.isEmpty { break }
            seen.append(contentsOf: rows.compactMap(\.id))
            offset += 200
            if inserted < 10 {
                let n = inserted
                try await db.write { db in
                    try db.execute(sql: """
                        INSERT INTO track (serverId, remoteId, title, sortTitle, albumTitle,
                                           artistName, trackNumber, discNumber, duration, albumRemoteId)
                        VALUES (?, ?, ?, ?, 'X', 'Y', 1, 1, 100, 'a')
                        """, arguments: [serverId, "late-\(n)", "A late \(n)", "A late \(n)"])
                }
                inserted += 1
            }
            if offset > 5_000 { break }
        }

        let original = try await db.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM track WHERE remoteId NOT LIKE 'late-%'")
        }
        let duplicates = seen.count - Set(seen).count
        let missed = Set(original).subtracting(seen).count

        // Documenting the defect, not asserting a precise count: how badly OFFSET
        // skews depends on where inserts land. If this ever comes out clean the
        // premise is worth re-examining, so it asserts that it does go wrong.
        XCTAssertGreaterThan(duplicates + missed, 0,
            "offset paging was expected to duplicate or skip rows under concurrent inserts")
    }

    func testCursorSurvivesATokenRoundTrip() throws {
        let cursor = LibraryRepository.PageCursor(keys: ["Analog Harvest", "Analog Harvest"], id: 4242)
        let restored = try XCTUnwrap(LibraryRepository.PageCursor(token: cursor.token))
        XCTAssertEqual(restored, cursor)
    }

    /// A token from somewhere else must not crash or silently behave as "start".
    func testGarbageTokensAreRejected() {
        for token in ["", "not base64!!", "YWJj", Data("no-separator".utf8).base64EncodedString()] {
            XCTAssertNil(LibraryRepository.PageCursor(token: token), "accepted \(token)")
        }
    }

    func testAlbumsAndArtistsPageToCompletionToo() async throws {
        let db = try await makeDatabase(tracks: 2_000)
        let repo = LibraryRepository(db)
        let serverId = SyntheticCatalog.defaultServerID

        var albums: [Int64] = []
        var albumCursor: LibraryRepository.PageCursor?
        repeat {
            let page = try await repo.albumsPage(serverId: serverId, after: albumCursor, limit: 50)
            albums.append(contentsOf: page.rows.compactMap(\.id))
            albumCursor = page.next
        } while albumCursor != nil
        XCTAssertEqual(Set(albums).count, albums.count, "an album was returned twice")
        XCTAssertGreaterThan(albums.count, 0)

        var artists: [Int64] = []
        var artistCursor: LibraryRepository.PageCursor?
        repeat {
            let page = try await repo.artistsPage(serverId: serverId, after: artistCursor, limit: 25)
            artists.append(contentsOf: page.rows.compactMap(\.id))
            artistCursor = page.next
        } while artistCursor != nil
        XCTAssertEqual(Set(artists).count, artists.count, "an artist was returned twice")
        XCTAssertEqual(artists.count, 80, "2,000 tracks generates 80 artists")
    }
}
