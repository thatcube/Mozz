import XCTest
import MozzCore
@testable import MozzDatabase

private func makeServer(_ id: String = "srv1", kind: BackendKind = .jellyfin) -> ServerConnection {
    ServerConnection(
        id: id, kind: kind, name: "Test",
        baseURL: URL(string: "https://example.local")!,
        userID: "u1", clientIdentifier: "client-1"
    )
}

final class SchemaAndWriteTests: XCTestCase {
    func testMigrationCreatesTablesAndFTS() async throws {
        let db = try MusicDatabase.inMemory()
        let tables = try await db.read { database -> Set<String> in
            let names = try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type IN ('table','view')")
            return Set(names)
        }
        for expected in ["server", "artist", "album", "track", "playlist", "playlistItem", "download", "play_event", "track_fts", "album_fts", "artist_fts"] {
            XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
        }
    }

    func testUpsertAndReadBack() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let repo = LibraryRepository(db)
        let server = makeServer()
        try await writer.saveServer(server)

        try await writer.upsertArtists([
            Artist(id: "a1", name: "Zephyr", sortName: "Zephyr"),
            Artist(id: "a2", name: "Aurora", sortName: "Aurora"),
        ], serverId: server.id)

        let artistCount = try await repo.artistCount(serverId: server.id)
        XCTAssertEqual(artistCount, 2)
        let page = try await repo.artistsPage(serverId: server.id, offset: 0, limit: 10)
        // Alphabetical by sortName COLLATE NOCASE → Aurora before Zephyr.
        XCTAssertEqual(page.map(\.name), ["Aurora", "Zephyr"])
    }

    func testAlbumAndTrackRelationships() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let repo = LibraryRepository(db)
        let server = makeServer()
        try await writer.saveServer(server)

        try await writer.upsertAlbums([
            Album(id: "al1", title: "Debut", artistName: "Björk", artistID: "ar1", year: 1993),
        ], serverId: server.id)
        try await writer.upsertTracks([
            Track(id: "t2", title: "Human Behaviour", albumID: "al1", artistName: "Björk", trackNumber: 1, discNumber: 1),
            Track(id: "t1", title: "Crying", albumID: "al1", artistName: "Björk", trackNumber: 2, discNumber: 1),
        ], serverId: server.id)

        let albums = try await repo.albums(forArtistRemoteId: "ar1", serverId: server.id)
        XCTAssertEqual(albums.map(\.title), ["Debut"])

        let tracks = try await repo.tracks(forAlbumRemoteId: "al1", serverId: server.id)
        // Ordered by track number.
        XCTAssertEqual(tracks.map(\.title), ["Human Behaviour", "Crying"])
    }

    func testGenresRoundTripAsJSON() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let repo = LibraryRepository(db)
        let server = makeServer()
        try await writer.saveServer(server)
        try await writer.upsertTracks([
            Track(id: "t1", title: "Song", artistName: "A", genres: ["Rock", "Alt"]),
        ], serverId: server.id)
        let track = try await repo.track(serverId: server.id, remoteId: "t1")
        XCTAssertEqual(track?.genres, ["Rock", "Alt"])
    }

    func testLibraryHomeQueries() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let repo = LibraryRepository(db)
        let server = makeServer()
        try await writer.saveServer(server)

        try await writer.upsertAlbums([
            Album(id: "old", title: "Old One", artistName: "A", artistID: "a1", year: 2001,
                  genres: ["Rock"], addedAt: Date(timeIntervalSince1970: 1_000)),
            Album(id: "new", title: "New One", artistName: "B", artistID: "a2", year: 2020,
                  genres: ["Jazz", "Rock"], addedAt: Date(timeIntervalSince1970: 9_000)),
            Album(id: "nodate", title: "No Date", artistName: "C", artistID: "a3",
                  genres: [], addedAt: nil),
        ], serverId: server.id)
        try await writer.upsertPlaylists([
            Playlist(id: "p2", title: "Road Trip"),
            Playlist(id: "p1", title: "Chill"),
        ], serverId: server.id)

        // Recently added: newest addedAt first, nil sorts last.
        let recent = try await repo.recentlyAddedAlbums(serverId: server.id, limit: 10)
        XCTAssertEqual(recent.map(\.remoteId), ["new", "old", "nodate"])

        // Playlists: alphabetical.
        let playlists = try await repo.allPlaylists(serverId: server.id)
        XCTAssertEqual(playlists.map(\.title), ["Chill", "Road Trip"])

        // Genres: distinct, alphabetical (validates SQLite JSON1 / json_each).
        let genres = try await repo.genres(serverId: server.id)
        XCTAssertEqual(genres, ["Jazz", "Rock"])

        // Albums for a genre.
        let rock = try await repo.albums(forGenre: "Rock", serverId: server.id)
        XCTAssertEqual(Set(rock.map(\.remoteId)), ["old", "new"])
        let jazz = try await repo.albums(forGenre: "Jazz", serverId: server.id)
        XCTAssertEqual(jazz.map(\.remoteId), ["new"])
    }

    func testRecentlyPlayedTracks() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let store = PlayEventStore(db)
        let repo = LibraryRepository(db)
        let server = makeServer()
        try await writer.saveServer(server)
        try await writer.upsertTracks([
            Track(id: "t1", title: "One", artistName: "A"),
            Track(id: "t2", title: "Two", artistName: "B"),
            Track(id: "t3", title: "Three", artistName: "C"),
        ], serverId: server.id)

        func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }
        // t1 played (started + completed, latest at 150); t2 played (started, 300 = newest);
        // t3 only skipped (must be excluded); t4 played but NOT in the catalog (inner join omits it).
        try await store.append(PlayEvent(trackID: "t1", kind: .started, createdAt: at(100)), serverId: server.id)
        try await store.append(PlayEvent(trackID: "t1", kind: .completed, createdAt: at(150)), serverId: server.id)
        try await store.append(PlayEvent(trackID: "t2", kind: .started, createdAt: at(300)), serverId: server.id)
        try await store.append(PlayEvent(trackID: "t3", kind: .skipped, createdAt: at(500)), serverId: server.id)
        try await store.append(PlayEvent(trackID: "t4", kind: .completed, createdAt: at(400)), serverId: server.id)

        let recent = try await repo.recentlyPlayedTracks(serverId: server.id, limit: 10)
        // Ordered by most-recent play: t2 (300) before t1 (150). t3 (skip-only) and
        // t4 (no catalog row) are excluded.
        XCTAssertEqual(recent.map(\.remoteId), ["t2", "t1"])
    }

    func testPlayEventStoreAppendAndRead() async throws {
        let db = try MusicDatabase.inMemory()
        let store = PlayEventStore(db)
        let server = makeServer()
        // History does NOT require catalog rows — the durable ref must work even
        // for a track not currently synced.
        try await store.append(PlayEvent(trackID: "t1", kind: .started, positionSeconds: 0, durationSeconds: 100),
                               serverId: server.id, device: "iphone")
        try await store.append(PlayEvent(trackID: "t1", kind: .completed, positionSeconds: 100, durationSeconds: 100),
                               serverId: server.id, device: "iphone")
        try await store.append(PlayEvent(trackID: "t2", kind: .skipped, positionSeconds: 5, durationSeconds: 100),
                               serverId: server.id)

        let ref = PlayEventStore.trackRef(serverId: server.id, remoteId: "t1")
        XCTAssertEqual(ref, "srv1:t1")

        let t1 = try await store.events(forTrackRef: ref)
        XCTAssertEqual(t1.count, 2)
        XCTAssertEqual(Set(t1.map(\.kind)), ["started", "completed"])
        XCTAssertEqual(t1.first?.trackRef, ref)
        XCTAssertEqual(t1.first?.device, "iphone")

        let completed = try await store.count(kind: .completed)
        XCTAssertEqual(completed, 1)
        let skipped = try await store.count(kind: .skipped)
        XCTAssertEqual(skipped, 1)

        let recent = try await store.recentlyPlayedTrackRefs()
        XCTAssertTrue(recent.contains(ref))
    }
}

final class UpsertIdentityTests: XCTestCase {
    /// The core guarantee of the offline-first design: re-syncing the catalog
    /// updates rows in place, preserving internal ids, so a completed download
    /// is never orphaned by a refresh.
    func testReUpsertPreservesTrackIdAndDownload() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let repo = LibraryRepository(db)
        let downloads = DownloadStore(db)
        let server = makeServer()
        try await writer.saveServer(server)

        try await writer.upsertTracks([
            Track(id: "t1", title: "Original", artistName: "A", duration: 100),
        ], serverId: server.id)
        let firstId = try await XCTUnwrapAsync(await repo.track(serverId: server.id, remoteId: "t1")?.id)

        // Download it.
        try await downloads.enqueue(trackId: firstId)
        try await downloads.markDownloaded(trackId: firstId, localPath: "t1.flac", sizeBytes: 4096)

        // Re-sync the same track with changed metadata.
        try await writer.upsertTracks([
            Track(id: "t1", title: "Updated Title", artistName: "A", duration: 123),
        ], serverId: server.id)

        let refreshed = try await XCTUnwrapAsync(await repo.track(serverId: server.id, remoteId: "t1"))
        XCTAssertEqual(refreshed.id, firstId, "id must be stable across re-sync")
        XCTAssertEqual(refreshed.title, "Updated Title")
        XCTAssertEqual(refreshed.duration, 123)

        let dl = try await downloads.localPath(forTrackId: firstId)
        XCTAssertEqual(dl, "t1.flac", "download must survive re-sync")
        let count = try await repo.trackCount(serverId: server.id)
        XCTAssertEqual(count, 1, "no duplicate row")
    }
}

final class FullTextSearchTests: XCTestCase {
    func testSearchMatchesPrefixAcrossTypes() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let repo = LibraryRepository(db)
        let server = makeServer()
        try await writer.saveServer(server)

        try await writer.upsertArtists([Artist(id: "a1", name: "Radiohead")], serverId: server.id)
        try await writer.upsertAlbums([Album(id: "al1", title: "Radio Ga Ga Collection", artistName: "Queen")], serverId: server.id)
        try await writer.upsertTracks([
            Track(id: "t1", title: "Radio Nowhere", albumTitle: "Magic", artistName: "Bruce"),
            Track(id: "t2", title: "Quiet Song", albumTitle: "Other", artistName: "Nobody"),
        ], serverId: server.id)

        // Prefix "radio" should hit the artist, the album and one track.
        let results = try await repo.search("radio", serverId: server.id)
        XCTAssertEqual(results.artists.map(\.name), ["Radiohead"])
        XCTAssertEqual(results.albums.map(\.title), ["Radio Ga Ga Collection"])
        XCTAssertEqual(results.tracks.map(\.title), ["Radio Nowhere"])
    }

    func testSearchIsDiacriticInsensitive() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let repo = LibraryRepository(db)
        let server = makeServer()
        try await writer.saveServer(server)
        try await writer.upsertArtists([Artist(id: "a1", name: "Björk")], serverId: server.id)
        let results = try await repo.search("bjork", serverId: server.id)
        XCTAssertEqual(results.artists.map(\.name), ["Björk"])
    }

    func testSearchSanitizesFTSOperators() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let repo = LibraryRepository(db)
        let server = makeServer()
        try await writer.saveServer(server)
        try await writer.upsertTracks([Track(id: "t1", title: "Clean", artistName: "A")], serverId: server.id)
        // Must not throw on FTS metacharacters.
        let results = try await repo.search("\"OR ( * :", serverId: server.id)
        XCTAssertTrue(results.isEmpty)
    }
}

final class DownloadStoreTests: XCTestCase {
    func testDownloadLifecycleAndStorageAccounting() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let repo = LibraryRepository(db)
        let downloads = DownloadStore(db)
        let server = makeServer()
        try await writer.saveServer(server)
        try await writer.upsertTracks([
            Track(id: "t1", title: "One", artistName: "A"),
            Track(id: "t2", title: "Two", artistName: "A"),
        ], serverId: server.id)
        let id1 = try await XCTUnwrapAsync(await repo.track(serverId: server.id, remoteId: "t1")?.id)
        let id2 = try await XCTUnwrapAsync(await repo.track(serverId: server.id, remoteId: "t2")?.id)

        try await downloads.enqueue(trackId: id1)
        try await downloads.markDownloading(trackId: id1, totalBytes: 1000)
        try await downloads.updateProgress(trackId: id1, receivedBytes: 500, totalBytes: 1000)
        try await downloads.markDownloaded(trackId: id1, localPath: "one.flac", sizeBytes: 1000)

        try await downloads.enqueue(trackId: id2) // still queued

        var usage = try await repo.storageUsage()
        XCTAssertEqual(usage.downloadedTrackCount, 1)
        XCTAssertEqual(usage.totalBytes, 1000)

        let downloaded = try await repo.downloadedTracks()
        XCTAssertEqual(downloaded.map(\.title), ["One"])

        // Remove and re-check accounting.
        try await downloads.remove(trackId: id1)
        usage = try await repo.storageUsage()
        XCTAssertEqual(usage.downloadedTrackCount, 0)
        XCTAssertEqual(usage.totalBytes, 0)
    }

    func testEnqueueIsIdempotent() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let repo = LibraryRepository(db)
        let downloads = DownloadStore(db)
        let server = makeServer()
        try await writer.saveServer(server)
        try await writer.upsertTracks([Track(id: "t1", title: "One", artistName: "A")], serverId: server.id)
        let id = try await XCTUnwrapAsync(await repo.track(serverId: server.id, remoteId: "t1")?.id)

        try await downloads.markDownloaded(trackId: id, localPath: "one.flac", sizeBytes: 10)
        // Enqueue must not clobber a completed download.
        try await downloads.enqueue(trackId: id)
        let record = try await repo.download(trackId: id)
        XCTAssertEqual(record?.downloadState, .downloaded)
    }
}

final class PlaylistTests: XCTestCase {
    func testPlaylistItemsOrdered() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let repo = LibraryRepository(db)
        let server = makeServer()
        try await writer.saveServer(server)
        try await writer.upsertTracks([
            Track(id: "t1", title: "First", artistName: "A"),
            Track(id: "t2", title: "Second", artistName: "A"),
            Track(id: "t3", title: "Third", artistName: "A"),
        ], serverId: server.id)
        try await writer.upsertPlaylists([Playlist(id: "p1", title: "Mix")], serverId: server.id)
        try await writer.replacePlaylistItems(playlistRemoteId: "p1", trackRemoteIds: ["t3", "t1", "t2"], serverId: server.id)

        let tracks = try await repo.tracks(forPlaylistRemoteId: "p1", serverId: server.id)
        XCTAssertEqual(tracks.map(\.title), ["Third", "First", "Second"])
    }
}

final class SyntheticCatalogTests: XCTestCase {
    func testGeneratesSmallCatalogAndSearches() async throws {
        let db = try MusicDatabase.inMemory()
        let repo = LibraryRepository(db)
        let generator = SyntheticCatalog(db)
        try await generator.generate(size: .small, chunkSize: 500)

        let trackCount = try await repo.trackCount()
        let albumCount = try await repo.albumCount()
        let artistCount = try await repo.artistCount()
        XCTAssertEqual(trackCount, 2_000)
        XCTAssertEqual(albumCount, 200)
        XCTAssertEqual(artistCount, 50)

        // FTS index populated for generated content.
        let results = try await repo.search("horizon", limitPerType: 5)
        XCTAssertFalse(results.isEmpty, "expected FTS hits in synthetic catalog")
    }
}

// MARK: - Async unwrap helper

func XCTUnwrapAsync<T>(_ expression: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, file: file, line: line)
}
