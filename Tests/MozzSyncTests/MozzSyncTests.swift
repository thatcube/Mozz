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
    /// Report a different `totalCount` from a given offset onwards, to simulate
    /// the library changing while a sync is walking it.
    var trackTotalFromOffset: (offset: Int, total: Int)?
    var trackShortFirstPage = false
    /// Whether this backend can count cheaply and sort songs by date added —
    /// true for Plex/Jellyfin. When false the mock behaves like Subsonic: it can
    /// still list newest-added albums and hand back their songs.
    var supportsRecentlyAdded = true
    /// Album-level catch-up only, the way Subsonic works.
    var supportsAlbumCatchUp = false
    /// Shared by every copy of the struct, so a test can prove how much network
    /// work a catch-up actually did.
    let calls = CallCounts()
    var trackFetchProbe: TrackFetchProbe?

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
        try trackFetchProbe?.record(offset: offset)
        // Simulate a short (but non-terminal) first page: return 2 items even
        // though more remain, so the engine must not treat "short == done".
        if trackShortFirstPage && offset == 0 && tracks.count > 2 {
            return CatalogPage(items: Array(tracks.prefix(2)), totalCount: trackTotalOverride ?? tracks.count)
        }
        let page = Self.page(tracks, offset: offset, limit: limit)
        if let drift = trackTotalFromOffset, offset >= drift.offset {
            return CatalogPage(items: page.items, totalCount: drift.total)
        }
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

    private static func page<T>(_ all: [T], offset: Int, limit: Int) -> CatalogPage<T> {
        guard offset < all.count else { return CatalogPage(items: [], totalCount: all.count) }
        let end = min(offset + limit, all.count)
        return CatalogPage(items: Array(all[offset..<end]), totalCount: all.count)
    }

    // MARK: Incremental catch-up
    //
    // The arrays are treated as newest-first, matching a real server's
    // `addedAt`/`DateCreated` descending order, so prepending simulates an add.

    func libraryTrackCount() async throws -> Int? {
        guard supportsRecentlyAdded else { return nil }
        calls.countProbes += 1
        return tracks.count
    }

    func fetchRecentlyAddedTracks(offset: Int, limit: Int) async throws -> CatalogPage<Track>? {
        guard supportsRecentlyAdded else { return nil }
        calls.trackPages += 1
        return Self.page(tracks, offset: offset, limit: limit)
    }

    func fetchRecentlyAddedAlbums(offset: Int, limit: Int) async throws -> CatalogPage<Album>? {
        guard supportsRecentlyAdded || supportsAlbumCatchUp else { return nil }
        calls.albumPages += 1
        return Self.page(albums, offset: offset, limit: limit)
    }

    func fetchAlbumTracks(albumID: String) async throws -> [Track]? {
        guard supportsAlbumCatchUp else { return nil }
        calls.albumTrackFetches += 1
        return tracks.filter { $0.albumID == albumID }
    }
}

/// Request tally shared across copies of ``MockBackend``.
final class CallCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var _countProbes = 0
    private var _trackPages = 0
    private var _albumPages = 0
    private var _albumTrackFetches = 0

    var countProbes: Int {
        get { lock.lock(); defer { lock.unlock() }; return _countProbes }
        set { lock.lock(); _countProbes = newValue; lock.unlock() }
    }
    var trackPages: Int {
        get { lock.lock(); defer { lock.unlock() }; return _trackPages }
        set { lock.lock(); _trackPages = newValue; lock.unlock() }
    }
    var albumPages: Int {
        get { lock.lock(); defer { lock.unlock() }; return _albumPages }
        set { lock.lock(); _albumPages = newValue; lock.unlock() }
    }
    var albumTrackFetches: Int {
        get { lock.lock(); defer { lock.unlock() }; return _albumTrackFetches }
        set { lock.lock(); _albumTrackFetches = newValue; lock.unlock() }
    }

    func reset() {
        lock.lock()
        _countProbes = 0; _trackPages = 0; _albumPages = 0; _albumTrackFetches = 0
        lock.unlock()
    }
}

final class TrackFetchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var offsets: [Int] = []
    private var failingOffset: Int?

    init(failingOffset: Int? = nil) {
        self.failingOffset = failingOffset
    }

    func record(offset: Int) throws {
        lock.lock()
        offsets.append(offset)
        let shouldFail = offset == failingOffset
        lock.unlock()
        if shouldFail { throw MozzError.serverUnreachable }
    }

    func reset(failingOffset: Int? = nil) {
        lock.lock()
        offsets.removeAll()
        self.failingOffset = failingOffset
        lock.unlock()
    }

    var recordedOffsets: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return offsets
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

    func testInterruptedCursorPersistsAndResumeSkipsCommittedPages() async throws {
        let database = try MusicDatabase.inMemory()
        let probe = TrackFetchProbe(failingOffset: 8)
        var backend = MockBackend()
        backend.tracks = makeTracks(12)
        backend.trackFetchProbe = probe

        do {
            _ = try await LibrarySyncEngine(
                backend: backend,
                database: database,
                pageSize: 4
            ).sync(startMode: .restart)
            XCTFail("expected the injected page failure")
        } catch MozzError.serverUnreachable {
            // Expected: the first two pages committed before offset 8 failed.
        }

        let store = CatalogSyncStore(database)
        let checkpoint = try await store.checkpoint(serverId: "srv", phase: "tracks")
        XCTAssertEqual(checkpoint?.committedOffset, 8)
        XCTAssertEqual(checkpoint?.reportedTotal, 12)
        XCTAssertEqual(checkpoint?.completed, false)
        let interrupted = try await store.hasInterruptedRun(serverId: "srv")
        XCTAssertTrue(interrupted)

        probe.reset()
        let summary = try await LibrarySyncEngine(
            backend: backend,
            database: database,
            pageSize: 4
        ).sync(startMode: .resumeIfPossible)

        XCTAssertEqual(probe.recordedOffsets, [8, 12])
        XCTAssertEqual(summary.tracks, 12)
        let stillInterrupted = try await store.hasInterruptedRun(serverId: "srv")
        let completed = try await store.checkpoint(serverId: "srv", phase: "tracks")?.completed
        XCTAssertFalse(stillInterrupted)
        XCTAssertEqual(completed, true)
    }

    func testChangedTotalDiscardsCursorAndRestartsPhase() async throws {
        let database = try MusicDatabase.inMemory()
        let probe = TrackFetchProbe(failingOffset: 8)
        var backend = MockBackend()
        backend.tracks = makeTracks(10)
        backend.trackFetchProbe = probe

        do {
            _ = try await LibrarySyncEngine(
                backend: backend,
                database: database,
                pageSize: 4
            ).sync(startMode: .restart)
            XCTFail("expected the injected page failure")
        } catch MozzError.serverUnreachable {}

        backend.tracks = makeTracks(12)
        probe.reset()
        let summary = try await LibrarySyncEngine(
            backend: backend,
            database: database,
            pageSize: 4
        ).sync(startMode: .resumeIfPossible)

        XCTAssertEqual(Array(probe.recordedOffsets.prefix(2)), [8, 0],
                       "a changed server total must invalidate the old offset")
        XCTAssertEqual(summary.tracks, 12)
        let checkpoint = try await CatalogSyncStore(database)
            .checkpoint(serverId: "srv", phase: "tracks")
        XCTAssertEqual(checkpoint?.reportedTotal, 12)
        XCTAssertEqual(checkpoint?.completed, true)
    }

    /// The guard that stands between a resumed run and catastrophe.
    ///
    /// A resumed phase only holds the ids AFTER its checkpoint. If that partial
    /// set were ever treated as a complete enumeration, the prune would delete
    /// every row before it — and because `download` rows cascade from `track`,
    /// that takes the user's offline music with it.
    ///
    /// The completeness arithmetic is deliberately rigged here so it would say
    /// "complete": the server reports a total equal to the resumed SUFFIX, so
    /// `Set(seen).count >= total` holds. Only `phaseCompleted`'s
    /// `resumedFromCheckpoint` guard can refuse the prune — remove it and this
    /// test fails, which is the whole point. (It previously passed either way,
    /// because the suffix was smaller than the total and the arithmetic blocked
    /// the prune on its own.)
    func testResumedSyncCannotPruneRowsOutsideItsSuffix() async throws {
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.tracks = makeTracks(8)
        _ = try await LibrarySyncEngine(
            backend: backend,
            database: database,
            pageSize: 4
        ).sync(startMode: .restart)

        // Give the user a download, so a bad prune would take real user data with
        // it — exactly what makes this failure unrecoverable rather than annoying.
        let repository = LibraryRepository(database)
        let downloadedRecord = try await repository.track(serverId: "srv", remoteId: "t0")
        let downloadedTrackId = try XCTUnwrap(downloadedRecord?.id)
        try await DownloadStore(database).markDownloaded(
            trackId: downloadedTrackId, localPath: "t0.m4a", sizeBytes: 1
        )

        // Rig the arithmetic so the resumed SUFFIX alone satisfies the
        // completeness predicate: the server reports a total of four, and the
        // suffix (t4…t7) is four. The total is set BEFORE the interrupted run so
        // the stored checkpoint records it too — otherwise the resumed run sees the
        // total change, discards the checkpoint and walks from zero, and the guard
        // is never consulted at all.
        backend.trackTotalOverride = 4
        let probe = TrackFetchProbe(failingOffset: 4)
        backend.trackFetchProbe = probe
        do {
            _ = try await LibrarySyncEngine(
                backend: backend,
                database: database,
                pageSize: 4
            ).sync(startMode: .restart)
            XCTFail("expected the injected page failure")
        } catch MozzError.serverUnreachable {}

        probe.reset()
        // `Set(seen).count >= reportedTotal` now holds for the suffix, so
        // `phaseCompleted`'s resumedFromCheckpoint guard is the ONLY thing
        // refusing the prune. Remove it and this test fails.
        let summary = try await LibrarySyncEngine(
            backend: backend,
            database: database,
            pageSize: 4
        ).sync(startMode: .resumeIfPossible)

        let count = try await repository.trackCount(serverId: "srv")
        XCTAssertEqual(probe.recordedOffsets.first, 4, "resume must skip the committed page")
        XCTAssertEqual(summary.deleted, 0, "a resumed run must never prune")
        XCTAssertEqual(count, 8, "the unseen prefix must survive a resumed run")
        let download = try await repository.download(trackId: downloadedTrackId)
        XCTAssertNotNil(download, "a resumed run must not cascade-delete downloads")
    }

    /// A total that moves WHILE a run is paging is ordinary — someone added an
    /// album, or the server's own scan finished — and must not disturb the run.
    ///
    /// It briefly did: any drift discarded the pages fetched so far and restarted
    /// the phase at zero, and a second drift threw, aborting the sync. On the case
    /// resume exists for — a multi-hour first Jellyfin sync — that threw away hours
    /// of paging and could end in "Sync failed". Drift is a reason not to PRUNE,
    /// which the completeness check already handles, not a reason to start over.
    func testMidRunTotalDriftNeitherRestartsNorFailsTheSync() async throws {
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.tracks = makeTracks(12)
        // From the third page on, the server claims a bigger library than we will
        // manage to enumerate.
        backend.trackTotalFromOffset = (offset: 8, total: 20)
        let probe = TrackFetchProbe()
        backend.trackFetchProbe = probe

        let summary = try await LibrarySyncEngine(
            backend: backend,
            database: database,
            pageSize: 4
        ).sync(startMode: .restart)

        XCTAssertEqual(probe.recordedOffsets, [0, 4, 8, 12],
                       "a mid-run total change must not restart the phase")
        XCTAssertEqual(summary.tracks, 12)
        XCTAssertEqual(summary.deleted, 0,
                       "an enumeration short of the reported total must not prune")
        let count = try await LibraryRepository(database).trackCount(serverId: "srv")
        XCTAssertEqual(count, 12)
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

    // MARK: - Incremental catch-up

    /// Songs added to the server turn up without a full re-sync.
    func testCatchUpAddsOnlyTheNewTracks() async throws {
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.albums = makeAlbums(2)
        backend.tracks = makeTracks(20)
        _ = try await LibrarySyncEngine(backend: backend, database: database, pageSize: 50).sync()

        // Five songs land on the server. Newest sort first, as a real server does.
        let fresh = (0..<5).map {
            Track(id: "new\($0)", title: "New \($0)", albumID: "al0", artistName: "Artist 0")
        }
        backend.tracks = fresh + backend.tracks

        let summary = try await LibrarySyncEngine(backend: backend, database: database)
            .catchUp(pageSize: 10, maxPages: 8)

        XCTAssertEqual(summary.tracks, 5)
        let repository = LibraryRepository(database)
        let count = try await repository.trackCount(serverId: "srv")
        XCTAssertEqual(count, 25, "the 20 existing tracks must not be duplicated")
    }

    /// The stop condition — and the reason this is cheap enough to run on every
    /// foreground. One new song must not page through the whole library.
    func testCatchUpStopsAtTheFirstFullyKnownPage() async throws {
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.albums = makeAlbums(2)
        backend.tracks = makeTracks(200)
        _ = try await LibrarySyncEngine(backend: backend, database: database, pageSize: 200).sync()

        backend.tracks = [Track(id: "newest", title: "Newest", albumID: "al0", artistName: "Artist 0")]
            + backend.tracks
        backend.calls.reset()

        let summary = try await LibrarySyncEngine(backend: backend, database: database)
            .catchUp(pageSize: 10, maxPages: 8)

        XCTAssertEqual(summary.tracks, 1)
        // Page one holds the new song, page two proves everything older is known.
        XCTAssertEqual(backend.calls.trackPages, 2,
                       "the walk must stop once a page adds nothing, not read all 20 pages")
    }

    /// The common case: nothing was added, so the count probe answers it and not a
    /// single page of songs is fetched.
    func testCatchUpFetchesNothingWhenTheLibraryIsUnchanged() async throws {
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.albums = makeAlbums(2)
        backend.tracks = makeTracks(30)
        _ = try await LibrarySyncEngine(backend: backend, database: database, pageSize: 50).sync()
        backend.calls.reset()

        let summary = try await LibrarySyncEngine(backend: backend, database: database).catchUp()

        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(backend.calls.countProbes, 1)
        XCTAssertEqual(backend.calls.trackPages, 0, "an unchanged library must cost only the count")
        XCTAssertEqual(backend.calls.albumPages, 0)
    }

    /// A catch-up sees only a slice, so it must never delete — a prune here would
    /// cascade through `download` and take the user's offline files with it.
    func testCatchUpNeverRemovesTracks() async throws {
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.albums = makeAlbums(2)
        backend.tracks = makeTracks(20)
        _ = try await LibrarySyncEngine(backend: backend, database: database, pageSize: 50).sync()

        // Six new songs arrive and five old ones are deleted server-side. The count
        // still grew, so the walk runs — but nothing may be removed locally.
        let fresh = (0..<6).map {
            Track(id: "new\($0)", title: "New \($0)", albumID: "al0", artistName: "Artist 0")
        }
        backend.tracks = fresh + Array(makeTracks(20).dropFirst(5))

        let summary = try await LibrarySyncEngine(backend: backend, database: database)
            .catchUp(pageSize: 10, maxPages: 8)

        XCTAssertEqual(summary.tracks, 6)
        let repository = LibraryRepository(database)
        let count = try await repository.trackCount(serverId: "srv")
        XCTAssertEqual(count, 26, "the five server-side deletions must survive until a full sync")
    }

    /// New songs usually mean a new album, which needs a row of its own or it is
    /// unreachable from the Albums tab.
    func testCatchUpAlsoPicksUpTheNewAlbum() async throws {
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.albums = makeAlbums(2)
        backend.tracks = makeTracks(10)
        _ = try await LibrarySyncEngine(backend: backend, database: database, pageSize: 50).sync()

        let newAlbum = Album(id: "alNew", title: "Brand New", artistName: "Artist 0", artistID: "ar0")
        backend.albums = [newAlbum] + backend.albums
        backend.tracks = [Track(id: "nt1", title: "New Track", albumID: "alNew", artistName: "Artist 0")]
            + backend.tracks

        let summary = try await LibrarySyncEngine(backend: backend, database: database)
            .catchUp(pageSize: 10, maxPages: 8)

        XCTAssertEqual(summary.tracks, 1)
        XCTAssertEqual(summary.albums, 1)
        let repository = LibraryRepository(database)
        let album = try await repository.album(serverId: "srv", remoteId: "alNew")
        XCTAssertNotNil(album, "the new album must be browsable, not just its songs")
    }

    /// A backend that can neither count cheaply nor sort by date added sits the
    /// catch-up out rather than falling back to something expensive.
    func testCatchUpIsANoOpForABackendThatCannotSupportIt() async throws {
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.tracks = makeTracks(10)
        _ = try await LibrarySyncEngine(backend: backend, database: database, pageSize: 50).sync()

        backend.supportsRecentlyAdded = false
        backend.tracks = makeTracks(20)
        backend.calls.reset()

        let summary = try await LibrarySyncEngine(backend: backend, database: database).catchUp()

        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(backend.calls.trackPages, 0)
    }

    // MARK: Album-driven catch-up (Subsonic)

    /// Subsonic has no song-level date ordering, but it does list newest-added
    /// albums — so a new album and its songs must still arrive automatically.
    func testCatchUpByAlbumPicksUpANewAlbumAndItsSongs() async throws {
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.supportsRecentlyAdded = false
        backend.supportsAlbumCatchUp = true
        backend.albums = makeAlbums(3)
        backend.tracks = makeTracks(9).enumerated().map { index, track in
            var copy = track
            copy.albumID = "al\(index % 3)"
            return copy
        }
        _ = try await LibrarySyncEngine(backend: backend, database: database, pageSize: 50).sync()

        // A new album lands, newest first, carrying two songs.
        var newAlbum = Album(id: "alNew", title: "Brand New", artistName: "Artist 0", artistID: "ar0")
        newAlbum.trackCount = 2
        backend.albums = [newAlbum] + backend.albums
        backend.tracks = [
            Track(id: "nt1", title: "New One", albumID: "alNew", artistName: "Artist 0"),
            Track(id: "nt2", title: "New Two", albumID: "alNew", artistName: "Artist 0"),
        ] + backend.tracks
        backend.calls.reset()

        let summary = try await LibrarySyncEngine(backend: backend, database: database)
            .catchUp(pageSize: 10, maxPages: 8)

        XCTAssertEqual(summary.albums, 1)
        XCTAssertEqual(summary.tracks, 2)
        let repository = LibraryRepository(database)
        let album = try await repository.album(serverId: "srv", remoteId: "alNew")
        XCTAssertNotNil(album)
        let songs = try await repository.tracks(forAlbumRemoteId: "alNew", serverId: "srv")
        XCTAssertEqual(songs.count, 2)
        // Only the one changed album was read, not all four.
        XCTAssertEqual(backend.calls.albumTrackFetches, 1)
    }

    /// An album that arrived half-imported and later gained its remaining songs
    /// has the same id, so "is it new?" alone would miss it.
    func testCatchUpByAlbumPicksUpSongsAddedToAnExistingAlbum() async throws {
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.supportsRecentlyAdded = false
        backend.supportsAlbumCatchUp = true
        var album = Album(id: "al0", title: "Half Album", artistName: "Artist 0", artistID: "ar0")
        album.trackCount = 2
        backend.albums = [album]
        backend.tracks = [
            Track(id: "t0", title: "One", albumID: "al0", artistName: "Artist 0"),
            Track(id: "t1", title: "Two", albumID: "al0", artistName: "Artist 0"),
        ]
        _ = try await LibrarySyncEngine(backend: backend, database: database, pageSize: 50).sync()

        // The rest of the album finishes importing on the server.
        album.trackCount = 4
        backend.albums = [album]
        backend.tracks += [
            Track(id: "t2", title: "Three", albumID: "al0", artistName: "Artist 0"),
            Track(id: "t3", title: "Four", albumID: "al0", artistName: "Artist 0"),
        ]

        let summary = try await LibrarySyncEngine(backend: backend, database: database)
            .catchUp(pageSize: 10, maxPages: 8)

        XCTAssertEqual(summary.tracks, 2, "the two new songs must arrive even though the album is known")
        let repository = LibraryRepository(database)
        let songs = try await repository.tracks(forAlbumRemoteId: "al0", serverId: "srv")
        XCTAssertEqual(songs.count, 4)
    }

    /// The unchanged case must stay cheap here too: newest album already known,
    /// so no album songs are ever fetched.
    func testCatchUpByAlbumFetchesNoSongsWhenNothingChanged() async throws {
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.supportsRecentlyAdded = false
        backend.supportsAlbumCatchUp = true
        var album = Album(id: "al0", title: "Album", artistName: "Artist 0", artistID: "ar0")
        album.trackCount = 3
        backend.albums = [album]
        backend.tracks = makeTracks(3)
        _ = try await LibrarySyncEngine(backend: backend, database: database, pageSize: 50).sync()
        backend.calls.reset()

        let summary = try await LibrarySyncEngine(backend: backend, database: database)
            .catchUp(pageSize: 10, maxPages: 8)

        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(backend.calls.albumPages, 1, "one small album page answers the question")
        XCTAssertEqual(backend.calls.albumTrackFetches, 0)
    }
}
