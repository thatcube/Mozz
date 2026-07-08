import XCTest
import Foundation
import MozzCore
import MozzDatabase
@testable import MozzSync

/// A fully in-memory ``MusicBackend`` that pages over fixed arrays, so the sync
/// engine can be tested without any network or provider.
struct MockBackend: MusicBackend {
    let connection: ServerConnection
    var artists: [Artist] = []
    var albums: [Album] = []
    var tracks: [Track] = []
    var playlists: [Playlist] = []
    var playlistItems: [String: [Track]] = [:]
    var capabilities: ServerCapabilities
    /// Test hooks: override the reported total (simulate a server that claims
    /// more than it returns), and force a short-but-non-terminal first track
    /// page (simulate a server that returns fewer than `limit` mid-enumeration).
    var trackTotalOverride: Int?
    var trackShortFirstPage = false

    init(serverId: String = "srv") {
        self.connection = ServerConnection(
            id: serverId, kind: .jellyfin, name: "Mock",
            baseURL: URL(string: "https://mock.example.com")!, clientIdentifier: "cid"
        )
        self.capabilities = ServerCapabilities(backend: .jellyfin, serverVersion: "10.9.0")
    }

    func detectCapabilities() async throws -> ServerCapabilities { capabilities }

    func fetchArtists(offset: Int, limit: Int) async throws -> CatalogPage<Artist> {
        Self.page(artists, offset: offset, limit: limit)
    }
    func fetchAlbums(offset: Int, limit: Int) async throws -> CatalogPage<Album> {
        Self.page(albums, offset: offset, limit: limit)
    }
    func fetchTracks(offset: Int, limit: Int) async throws -> CatalogPage<Track> {
        // Simulate a short (but non-terminal) first page: return 2 items even
        // though more remain, so the engine must not treat "short == done".
        if trackShortFirstPage && offset == 0 && tracks.count > 2 {
            return CatalogPage(items: Array(tracks.prefix(2)), totalCount: trackTotalOverride ?? tracks.count)
        }
        let page = Self.page(tracks, offset: offset, limit: limit)
        if let total = trackTotalOverride {
            return CatalogPage(items: page.items, totalCount: total)
        }
        return page
    }
    func fetchPlaylists(offset: Int, limit: Int) async throws -> CatalogPage<Playlist> {
        Self.page(playlists, offset: offset, limit: limit)
    }
    func fetchPlaylistItems(playlistID: String, offset: Int, limit: Int) async throws -> CatalogPage<Track> {
        Self.page(playlistItems[playlistID] ?? [], offset: offset, limit: limit)
    }

    func streamSource(for track: Track, options: StreamOptions) async throws -> StreamSource {
        StreamSource(url: URL(string: "https://mock.example.com/\(track.id)")!, isTranscoded: false)
    }
    func originalFileURL(for track: Track) throws -> URL {
        URL(string: "https://mock.example.com/\(track.id)/file")!
    }
    func artworkURL(for artwork: ArtworkRef, size: Int) -> URL? { nil }
    func setFavorite(_ isFavorite: Bool, itemID: String, type: CatalogItemType) async throws {}
    func setRating(_ stars: Double?, itemID: String, type: CatalogItemType) async throws {}

    fileprivate static func page<T>(_ all: [T], offset: Int, limit: Int) -> CatalogPage<T> {
        guard offset < all.count else { return CatalogPage(items: [], totalCount: all.count) }
        let end = min(offset + limit, all.count)
        return CatalogPage(items: Array(all[offset..<end]), totalCount: all.count)
    }
}

/// Wraps ``MockBackend`` but advertises a real bulk enumerator, simulating a
/// Subsonic-style backend so ``LibrarySyncEngine``'s bulk dispatch path (and
/// its stricter, unknown-total-never-prunes gating) can be exercised without
/// depending on the MozzSubsonic module.
struct BulkMockBackend: MusicBackend {
    var inner: MockBackend
    /// When `true`, every yielded page omits `totalCount` — simulating a
    /// server that cannot report an expected total (e.g. missing `songCount`
    /// on one or more albums during an album-walk).
    var totalIsUnknown = false
    /// Optional bulk-specific error to throw partway through enumeration,
    /// simulating a network failure mid-walk.
    var failAfterPages: Int?

    var connection: ServerConnection { inner.connection }
    func detectCapabilities() async throws -> ServerCapabilities { try await inner.detectCapabilities() }
    func fetchArtists(offset: Int, limit: Int) async throws -> CatalogPage<Artist> { try await inner.fetchArtists(offset: offset, limit: limit) }
    func fetchAlbums(offset: Int, limit: Int) async throws -> CatalogPage<Album> { try await inner.fetchAlbums(offset: offset, limit: limit) }
    func fetchTracks(offset: Int, limit: Int) async throws -> CatalogPage<Track> { try await inner.fetchTracks(offset: offset, limit: limit) }
    func fetchPlaylists(offset: Int, limit: Int) async throws -> CatalogPage<Playlist> { try await inner.fetchPlaylists(offset: offset, limit: limit) }
    func fetchPlaylistItems(playlistID: String, offset: Int, limit: Int) async throws -> CatalogPage<Track> {
        try await inner.fetchPlaylistItems(playlistID: playlistID, offset: offset, limit: limit)
    }
    func streamSource(for track: Track, options: StreamOptions) async throws -> StreamSource { try await inner.streamSource(for: track, options: options) }
    func originalFileURL(for track: Track) throws -> URL { try inner.originalFileURL(for: track) }
    func artworkURL(for artwork: ArtworkRef, size: Int) -> URL? { inner.artworkURL(for: artwork, size: size) }
    func setFavorite(_ isFavorite: Bool, itemID: String, type: CatalogItemType) async throws { try await inner.setFavorite(isFavorite, itemID: itemID, type: type) }
    func setRating(_ stars: Double?, itemID: String, type: CatalogItemType) async throws { try await inner.setRating(stars, itemID: itemID, type: type) }

    var hasBulkEnumerator: Bool { true }

    func enumerateAllTracks(pageSize: Int) -> AsyncThrowingStream<BulkTrackPage, Error> {
        let tracks = inner.tracks
        let total = totalIsUnknown ? nil : tracks.count
        let failAfterPages = self.failAfterPages
        return AsyncThrowingStream { continuation in
            var offset = 0
            var pageIndex = 0
            while offset < tracks.count {
                if let failAfterPages, pageIndex >= failAfterPages {
                    continuation.finish(throwing: MozzError.transport("simulated bulk-enumeration failure"))
                    return
                }
                let end = min(offset + pageSize, tracks.count)
                continuation.yield(CatalogPage(items: Array(tracks[offset..<end]), totalCount: total))
                offset = end
                pageIndex += 1
            }
            continuation.finish()
        }
    }
}

private final class PhaseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var phases: [SyncProgress.Phase] = []
    func record(_ phase: SyncProgress.Phase) {
        lock.lock(); defer { lock.unlock() }
        if phases.last != phase { phases.append(phase) }
    }
}

private func makeArtists(_ count: Int) -> [Artist] {
    (0..<count).map { Artist(id: "ar\($0)", name: "Artist \($0)") }
}
private func makeAlbums(_ count: Int) -> [Album] {
    (0..<count).map { Album(id: "al\($0)", title: "Album \($0)", artistName: "Artist 0", artistID: "ar0") }
}
private func makeTracks(_ count: Int) -> [Track] {
    (0..<count).map { Track(id: "t\($0)", title: "Track \($0)", albumID: "al0", artistName: "Artist 0") }
}

final class LibrarySyncEngineTests: XCTestCase {
    func testFullSyncPopulatesDatabase() async throws {
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.artists = makeArtists(3)
        backend.albums = makeAlbums(5)
        backend.tracks = makeTracks(20)

        let engine = LibrarySyncEngine(backend: backend, database: database, pageSize: 7)
        let summary = try await engine.sync()

        XCTAssertEqual(summary.artists, 3)
        XCTAssertEqual(summary.albums, 5)
        XCTAssertEqual(summary.tracks, 20)

        let repository = LibraryRepository(database)
        let trackCount = try await repository.trackCount(serverId: "srv")
        XCTAssertEqual(trackCount, 20)
        let capabilities = try await repository.capabilities(serverId: "srv")
        XCTAssertEqual(capabilities?.serverVersion, "10.9.0")
        let servers = try await repository.servers()
        XCTAssertEqual(servers.count, 1)
    }

    func testQuickStartPlanSyncsBoundedSliceAndDoesNotPrune() async throws {
        let database = try MusicDatabase.inMemory()
        let repository = LibraryRepository(database)

        // Pre-seed a stale catalog (as if from a previous full sync) so we can
        // verify the quick-start plan does NOT prune the rows it doesn't re-see.
        var backend = MockBackend()
        backend.artists = makeArtists(3)
        backend.albums = makeAlbums(30)
        backend.tracks = makeTracks(100)
        _ = try await LibrarySyncEngine(backend: backend, database: database, pageSize: 50).sync()
        let seededTracks = try await repository.trackCount(serverId: "srv")
        XCTAssertEqual(seededTracks, 100)

        // Quick start: newest tracks in ONE page (engine pageSize 10), no albums,
        // no artists, no playlists, no prune. (plan.pageSize is applied by
        // AppEnvironment when it builds the engine; here the engine's own
        // pageSize governs, so 1 track page = 10 tracks.)
        let engine = LibrarySyncEngine(backend: backend, database: database, pageSize: 10)
        let summary = try await engine.sync(plan: .quickStart(tracks: 300))

        // Only the bounded slice was enumerated this run…
        XCTAssertEqual(summary.albums, 0)    // albums skipped entirely
        XCTAssertEqual(summary.tracks, 10)   // 1 page × 10
        XCTAssertEqual(summary.deleted, 0)   // MUST NOT prune on a bounded plan

        // …and the pre-existing catalog is fully intact (nothing pruned).
        let tracksAfter = try await repository.trackCount(serverId: "srv")
        XCTAssertEqual(tracksAfter, 100, "quick start must not delete previously-synced rows")
        let albumsAfter = try await repository.albumCount(serverId: "srv")
        XCTAssertEqual(albumsAfter, 30)
    }

    func testProgressPhasesAreReportedInOrder() async throws {
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.artists = makeArtists(2)
        backend.tracks = makeTracks(2)

        let collector = PhaseCollector()
        let engine = LibrarySyncEngine(backend: backend, database: database)
        _ = try await engine.sync { collector.record($0.phase) }

        // Setup still brackets the run with capabilities → … → pruning → done.
        XCTAssertEqual(collector.phases.first, .capabilities)
        XCTAssertEqual(collector.phases.last, .done)
        XCTAssertTrue(collector.phases.contains(.pruning))
        // The entity phases now run concurrently and report a single combined
        // `.syncing` phase (not per-type artists/albums/tracks progress).
        XCTAssertTrue(collector.phases.contains(.syncing))
        // capabilities must come before any bulk syncing, and pruning after it.
        let firstSyncing = collector.phases.firstIndex(of: .syncing)
        let capabilitiesIdx = collector.phases.firstIndex(of: .capabilities)
        let pruningIdx = collector.phases.firstIndex(of: .pruning)
        if let firstSyncing, let capabilitiesIdx { XCTAssertLessThan(capabilitiesIdx, firstSyncing) }
        if let firstSyncing, let pruningIdx { XCTAssertLessThan(firstSyncing, pruningIdx) }
    }

    func testResyncPrunesDeletedItems() async throws {
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.tracks = makeTracks(10)
        let engine = LibrarySyncEngine(backend: backend, database: database, pageSize: 4)
        _ = try await engine.sync()

        let repository = LibraryRepository(database)
        let before = try await repository.trackCount(serverId: "srv")
        XCTAssertEqual(before, 10)

        // Server now reports only the first 3 tracks.
        backend.tracks = Array(makeTracks(10).prefix(3))
        let engine2 = LibrarySyncEngine(backend: backend, database: database, pageSize: 4)
        let summary = try await engine2.sync()

        let after = try await repository.trackCount(serverId: "srv")
        XCTAssertEqual(after, 3)
        XCTAssertEqual(summary.deleted, 7)
    }

    func testShortPageMidEnumerationDoesNotStopEarly() async throws {
        // A server that returns a short (2-item) first page even though 10
        // tracks exist must NOT be treated as "done" after page 1 — all 10
        // must be fetched. (Regression guard for the old `count < pageSize`
        // early-break that could truncate a sync mid-enumeration.)
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.tracks = makeTracks(10)
        backend.trackShortFirstPage = true

        let engine = LibrarySyncEngine(backend: backend, database: database, pageSize: 4)
        let summary = try await engine.sync()

        XCTAssertEqual(summary.tracks, 10, "short mid-enumeration page must not truncate the sync")
        let repository = LibraryRepository(database)
        let count = try await repository.trackCount(serverId: "srv")
        XCTAssertEqual(count, 10)
    }

    func testIncompleteEnumerationDoesNotPruneCatalog() async throws {
        // The catastrophic B2 case: a healthy catalog exists, then a flaky
        // re-sync returns far fewer items than the server's reported total.
        // Pruning must be SKIPPED so the catalog (and its downloads, which
        // cascade-delete from tracks) is never wiped by a truncated sync.
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.tracks = makeTracks(10)
        _ = try await LibrarySyncEngine(backend: backend, database: database, pageSize: 4).sync()

        let repository = LibraryRepository(database)
        let initialCount = try await repository.trackCount(serverId: "srv")
        XCTAssertEqual(initialCount, 10)

        // Flaky re-sync: server still reports 10 total, but only returns 4.
        backend.tracks = Array(makeTracks(10).prefix(4))
        backend.trackTotalOverride = 10
        let summary = try await LibrarySyncEngine(backend: backend, database: database, pageSize: 4).sync()

        let afterCount = try await repository.trackCount(serverId: "srv")
        XCTAssertEqual(afterCount, 10,
                       "incomplete enumeration (seen < reported total) must not prune existing rows")
        XCTAssertEqual(summary.deleted, 0)
    }

    func testAllOrNothingPruneSkipsWhenAnyPhaseIncomplete() async throws {
        // All-or-nothing: a truncated tracks phase must not authorize pruning
        // even the fully-enumerated artists phase.
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.artists = makeArtists(5)
        backend.tracks = makeTracks(10)
        _ = try await LibrarySyncEngine(backend: backend, database: database, pageSize: 4).sync()

        let repository = LibraryRepository(database)
        let artistsBefore = try await repository.artistCount(serverId: "srv")
        XCTAssertEqual(artistsBefore, 5)

        // Re-sync: artists complete (server truly has 3) but tracks truncated.
        backend.artists = makeArtists(3)
        backend.tracks = Array(makeTracks(10).prefix(4))
        backend.trackTotalOverride = 10
        let summary = try await LibrarySyncEngine(backend: backend, database: database, pageSize: 4).sync()

        let artistsAfter = try await repository.artistCount(serverId: "srv")
        XCTAssertEqual(artistsAfter, 5, "a truncated tracks phase must not authorize pruning artists")
        XCTAssertEqual(summary.deleted, 0)
    }

    func testPlaylistItemsSyncedInOrder() async throws {
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        let tracks = makeTracks(4)
        backend.tracks = tracks
        backend.playlists = [Playlist(id: "pl1", title: "Mix")]
        // Reverse order to prove ordering is preserved.
        backend.playlistItems = ["pl1": [tracks[3], tracks[1], tracks[2]]]

        let engine = LibrarySyncEngine(backend: backend, database: database)
        _ = try await engine.sync()

        let repository = LibraryRepository(database)
        let items = try await repository.tracks(forPlaylistRemoteId: "pl1", serverId: "srv")
        XCTAssertEqual(items.map(\.remoteId), ["t3", "t1", "t2"])
    }

    // MARK: - Bulk enumerator dispatch (architecture point 4)

    func testBulkEnumeratorIsPreferredOverFlatPager() async throws {
        let database = try MusicDatabase.inMemory()
        var mock = MockBackend()
        mock.tracks = makeTracks(23)
        let backend = BulkMockBackend(inner: mock)

        let engine = LibrarySyncEngine(backend: backend, database: database, pageSize: 7)
        let summary = try await engine.sync()

        // All 23 tracks arrived via the bulk walk (dispatch didn't silently
        // fall back to the flat fetchTracks pager, which MockBackend backs
        // with the same array — so this alone doesn't prove the bulk path
        // was used, but combined with the prune-safety tests below it does).
        XCTAssertEqual(summary.tracks, 23)
        let repository = LibraryRepository(database)
        let count = try await repository.trackCount(serverId: "srv")
        XCTAssertEqual(count, 23)
    }

    func testBulkEnumeratorUnknownTotalNeverPrunes() async throws {
        // The core B2/prune-safety guarantee for Subsonic-shaped backends:
        // if the bulk enumerator cannot derive an expected total (e.g. one
        // or more albums lacked a `songCount` during the album-walk), the
        // engine must NEVER treat "non-empty walk" as "complete" and must
        // skip pruning — even though every yielded page was non-empty.
        let database = try MusicDatabase.inMemory()
        var mock = MockBackend()
        mock.tracks = makeTracks(10)
        let seedBackend = BulkMockBackend(inner: mock)
        _ = try await LibrarySyncEngine(backend: seedBackend, database: database, pageSize: 4).sync()

        let repository = LibraryRepository(database)
        let seeded = try await repository.trackCount(serverId: "srv")
        XCTAssertEqual(seeded, 10)

        // Re-sync: server now only has 6 tracks AND cannot report a total
        // (simulating a missing songCount during the album walk).
        mock.tracks = Array(makeTracks(10).prefix(6))
        let flakyBackend = BulkMockBackend(inner: mock, totalIsUnknown: true)
        let summary = try await LibrarySyncEngine(backend: flakyBackend, database: database, pageSize: 4).sync()

        let after = try await repository.trackCount(serverId: "srv")
        XCTAssertEqual(after, 10, "unknown-total bulk enumeration must never authorize pruning")
        XCTAssertEqual(summary.deleted, 0)
    }

    func testBulkEnumeratorKnownTotalPrunesWhenComplete() async throws {
        // Contrast case: when the bulk enumerator DOES derive a total and
        // the walk fully matches it, pruning proceeds normally.
        let database = try MusicDatabase.inMemory()
        var mock = MockBackend()
        mock.tracks = makeTracks(10)
        let seedBackend = BulkMockBackend(inner: mock)
        _ = try await LibrarySyncEngine(backend: seedBackend, database: database, pageSize: 4).sync()

        mock.tracks = Array(makeTracks(10).prefix(6))
        let resyncBackend = BulkMockBackend(inner: mock, totalIsUnknown: false)
        let summary = try await LibrarySyncEngine(backend: resyncBackend, database: database, pageSize: 4).sync()

        let repository = LibraryRepository(database)
        let after = try await repository.trackCount(serverId: "srv")
        XCTAssertEqual(after, 6, "a fully-enumerated, correctly-totalled walk should prune deleted tracks")
        XCTAssertEqual(summary.deleted, 4)
    }

    func testBulkEnumeratorMidWalkFailurePropagatesAndDoesNotPrune() async throws {
        // A backend whose bulk stream throws partway through (e.g. a
        // getAlbum(id:) network failure mid album-walk) must surface the
        // error and must not prune the previously-healthy catalog.
        let database = try MusicDatabase.inMemory()
        var mock = MockBackend()
        mock.tracks = makeTracks(10)
        let seedBackend = BulkMockBackend(inner: mock)
        _ = try await LibrarySyncEngine(backend: seedBackend, database: database, pageSize: 4).sync()

        let flakyBackend = BulkMockBackend(inner: mock, failAfterPages: 1)
        do {
            _ = try await LibrarySyncEngine(backend: flakyBackend, database: database, pageSize: 4).sync()
            XCTFail("expected mid-walk failure to propagate")
        } catch {
            // expected
        }

        let repository = LibraryRepository(database)
        let after = try await repository.trackCount(serverId: "srv")
        XCTAssertEqual(after, 10, "a mid-walk failure must not prune the previously-synced catalog")
    }

    func testBulkEnumeratorRespectsQuickStartBoundAndUsesFlatPager() async throws {
        // A bounded quick-start plan must never invoke the (whole-catalog)
        // bulk walk, even when the backend advertises one — quick start
        // relies on the flat pager's offset/limit semantics to fetch just
        // the newest slice, and never prunes regardless.
        let database = try MusicDatabase.inMemory()
        var mock = MockBackend()
        mock.tracks = makeTracks(100)
        let backend = BulkMockBackend(inner: mock, totalIsUnknown: true)

        let engine = LibrarySyncEngine(backend: backend, database: database, pageSize: 10)
        let summary = try await engine.sync(plan: .quickStart(tracks: 300))

        XCTAssertEqual(summary.tracks, 10, "quick start must use the bounded flat pager, not the whole-catalog bulk walk")
        XCTAssertEqual(summary.deleted, 0)
    }
}
