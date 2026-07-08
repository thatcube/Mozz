import XCTest
import Foundation
import MozzCore
import MozzNetworking
@testable import MozzSubsonic

/// Covers ``SubsonicBackend/enumerateAllTracks(pageSize:)`` — the authoritative,
/// prune-safe album-walk bulk enumerator (architecture points 2 and 3).
final class SubsonicBulkEnumeratorTests: XCTestCase {
    private let walkTransport = FixtureTransport([
        .init(contains: "getAlbumList2", fixture: "sub_walk_albums"),
        .init(contains: "id=al-w1", fixture: "sub_walk_album_1"),
        .init(contains: "id=al-w2", fixture: "sub_walk_album_2"),
    ])

    private let missingCountTransport = FixtureTransport([
        .init(contains: "getAlbumList2", fixture: "sub_walk_albums_missing_count"),
        .init(contains: "id=al-w1", fixture: "sub_walk_album_1"),
        .init(contains: "id=al-w2", fixture: "sub_walk_album_2"),
    ])

    private func collect(_ backend: SubsonicBackend, pageSize: Int) async throws -> [CatalogPage<Track>] {
        var pages: [CatalogPage<Track>] = []
        for try await page in backend.enumerateAllTracks(pageSize: pageSize) {
            pages.append(page)
        }
        return pages
    }

    func testHasBulkEnumeratorIsAdvertised() throws {
        let backend = try makeSubsonicBackend(transport: walkTransport)
        XCTAssertTrue(backend.hasBulkEnumerator)
    }

    func testEnumerateAllTracksDedupesAcrossAlbumsAndComputesExpectedTotal() async throws {
        let backend = try makeSubsonicBackend(transport: walkTransport)
        let pages = try await collect(backend, pageSize: 10)
        let allTracks = pages.flatMap(\.items)
        // Album 1 has 2 songs (sg-w1, sg-w2); Album 2 re-lists sg-w2 and adds
        // sg-w3 — the duplicate must collapse to a single track (dedup by
        // song id), NOT be double-counted.
        XCTAssertEqual(allTracks.map(\.id).sorted(), ["sg-w1", "sg-w2", "sg-w3"])
        XCTAssertEqual(Set(allTracks.map(\.id)).count, allTracks.count, "no duplicate ids should ever be yielded")

        // expectedTotal is the SUM of every album's songCount (2 + 2 = 4) —
        // it is deliberately NOT the deduped count (3): it's a derived,
        // provable total against which the *sync engine* separately verifies
        // completeness by comparing to actually-synced-and-deduped track
        // count. Every yielded page must carry the identical total.
        for page in pages {
            XCTAssertEqual(page.totalCount, 4)
        }
    }

    func testEnumerateAllTracksPreservesStableAlbumWalkOrder() async throws {
        let backend = try makeSubsonicBackend(transport: walkTransport)
        let pages = try await collect(backend, pageSize: 10)
        let allTracks = pages.flatMap(\.items)
        // Album One's songs first (in getAlbum's own song order), then Album
        // Two's NEW song only (sg-w2 was already emitted for Album One).
        XCTAssertEqual(allTracks.map(\.id), ["sg-w1", "sg-w2", "sg-w3"])
    }

    func testEnumerateAllTracksYieldsBatchesAtRequestedPageSize() async throws {
        let backend = try makeSubsonicBackend(transport: walkTransport)
        // 3 unique tracks total, requested in batches of 2: expect a full
        // page of 2 followed by a final partial page of 1.
        let pages = try await collect(backend, pageSize: 2)
        XCTAssertEqual(pages.map(\.items.count), [2, 1])
    }

    func testEnumerateAllTracksUnknownTotalWhenAnyAlbumSongCountMissing() async throws {
        // Architecture point 3 (protect offline data): if EVEN ONE album is
        // missing songCount, the derived total becomes unknowable — every
        // yielded page must report `nil`, never a partial/best-guess number,
        // so the sync engine can never mistake this for a provably-complete
        // sync and prune.
        let backend = try makeSubsonicBackend(transport: missingCountTransport)
        let pages = try await collect(backend, pageSize: 10)
        XCTAssertFalse(pages.isEmpty)
        for page in pages {
            XCTAssertNil(page.totalCount)
        }
        // The songs themselves are still enumerated correctly regardless —
        // an unprovable total degrades the SYNC's prune decision, not the
        // catalog data itself.
        XCTAssertEqual(pages.flatMap(\.items).map(\.id).sorted(), ["sg-w1", "sg-w2", "sg-w3"])
    }

    func testEnumerateAllTracksMapsFullTrackFields() async throws {
        let backend = try makeSubsonicBackend(transport: walkTransport)
        let pages = try await collect(backend, pageSize: 10)
        let track = try XCTUnwrap(pages.flatMap(\.items).first { $0.id == "sg-w1" })
        XCTAssertEqual(track.title, "Song One")
        XCTAssertEqual(track.albumID, "al-w1")
        XCTAssertEqual(track.artistName, "Test Artist")
        XCTAssertEqual(track.trackNumber, 1)
        XCTAssertEqual(track.duration, 200, accuracy: 0.01)
        XCTAssertEqual(track.format.container, "flac")
    }

    func testEnumerateAllTracksPropagatesErrorsAndTerminatesStream() async throws {
        // getAlbumList2 succeeds (2 albums), but every getAlbum call 404s —
        // the stream must surface the error (not silently truncate/succeed).
        let transport = FixtureTransport([.init(contains: "getAlbumList2", fixture: "sub_walk_albums")])
        let backend = try makeSubsonicBackend(transport: transport)
        do {
            _ = try await collect(backend, pageSize: 10)
            XCTFail("expected an error from the failing getAlbum calls")
        } catch {
            // Any thrown error is acceptable here; the key assertion is that
            // one WAS thrown rather than the stream finishing "successfully"
            // with an incomplete/wrong track set.
        }
    }
}
