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

    func testAlbumFragmentsConsolidate() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let repo = LibraryRepository(db)
        let server = makeServer()
        try await writer.saveServer(server)

        // One album ("2001" by Dr. Dre) that the server fragmented into 3 album
        // entities: same album-artist + title, different ids, a subset of tracks
        // each. alb1 has artwork; alb3 has the most tracks. Plus a genuine
        // different edition that must NOT merge.
        try await writer.upsertAlbums([
            Album(id: "alb1", title: "2001", artistName: "Dr. Dre", artistID: "dre", year: 1999, artwork: ArtworkRef(key: "cover"), trackCount: 1),
            Album(id: "alb2", title: "2001", artistName: "Dr. Dre", artistID: "dre", year: 1999, trackCount: 1),
            Album(id: "alb3", title: "2001", artistName: "Dr. Dre", artistID: "dre", year: 1999, trackCount: 2),
            Album(id: "dlx", title: "2001 (Deluxe)", artistName: "Dr. Dre", artistID: "dre", year: 1999, trackCount: 1),
        ], serverId: server.id)
        try await writer.upsertTracks([
            Track(id: "t1", title: "Still D.R.E.", albumID: "alb1", artistName: "Dr. Dre", trackNumber: 4, discNumber: 1),
            Track(id: "t2", title: "Forgot About Dre", albumID: "alb2", artistName: "Dr. Dre", trackNumber: 10, discNumber: 1),
            Track(id: "t3", title: "The Next Episode", albumID: "alb3", artistName: "Dr. Dre", trackNumber: 11, discNumber: 1),
            Track(id: "t4", title: "The Watcher", albumID: "alb3", artistName: "Dr. Dre", trackNumber: 2, discNumber: 1),
            Track(id: "t5", title: "Xxplosive", albumID: "dlx", artistName: "Dr. Dre", trackNumber: 6, discNumber: 1),
        ], serverId: server.id)

        // Album list collapses the 3 fragments into one; deluxe stays separate.
        let page = try await repo.albumsPage(serverId: server.id, offset: 0, limit: 50)
        XCTAssertEqual(page.count, 2)
        let main = try XCTUnwrap(page.first { $0.title == "2001" })
        // Representative prefers the fragment WITH artwork (cover stability) over
        // the one with more tracks.
        XCTAssertEqual(main.remoteId, "alb1")
        XCTAssertEqual(main.artworkKey, "cover")

        // Artist detail consolidates too.
        let artistAlbums = try await repo.albums(forArtistRemoteId: "dre", serverId: server.id)
        XCTAssertEqual(Set(artistAlbums.map(\.title)), ["2001", "2001 (Deluxe)"])

        // Album detail returns ALL tracks across the fragments, disc/track ordered.
        let tracks = try await repo.tracks(forAlbumGroupKey: main.albumGroupKey, serverId: server.id)
        XCTAssertEqual(tracks.map(\.title), ["The Watcher", "Still D.R.E.", "Forgot About Dre", "The Next Episode"])

        // The download path resolves the same set from any fragment's remoteId.
        let viaFragment = try await repo.tracks(forAlbumGroupContaining: "alb1", serverId: server.id)
        XCTAssertEqual(viaFragment.count, 4)

        // The deluxe edition keeps its own single track.
        let deluxe = try XCTUnwrap(page.first { $0.title == "2001 (Deluxe)" })
        let deluxeTracks = try await repo.tracks(forAlbumGroupKey: deluxe.albumGroupKey, serverId: server.id)
        XCTAssertEqual(deluxeTracks.map(\.title), ["Xxplosive"])
    }

    func testAlbumGroupKeyPolicy() {
        // Case/diacritic/whitespace-insensitive; edition markers preserved.
        XCTAssertEqual(
            AlbumGrouping.key(artistRemoteId: "dre", artistName: "Dr. Dre", sortTitle: "2001"),
            AlbumGrouping.key(artistRemoteId: "dre", artistName: "dr. dre", sortTitle: "  2001 "))
        XCTAssertNotEqual(
            AlbumGrouping.key(artistRemoteId: "dre", artistName: "Dr. Dre", sortTitle: "2001"),
            AlbumGrouping.key(artistRemoteId: "dre", artistName: "Dr. Dre", sortTitle: "2001 (Deluxe)"))
        // Album-artist ID wins over display name when present.
        XCTAssertEqual(
            AlbumGrouping.key(artistRemoteId: "dre", artistName: "Dr. Dre", sortTitle: "2001"),
            AlbumGrouping.key(artistRemoteId: "dre", artistName: "Andre Young", sortTitle: "2001"))
        // No id → fall back to name; different names stay separate.
        XCTAssertNotEqual(
            AlbumGrouping.key(artistRemoteId: nil, artistName: "Dr. Dre", sortTitle: "2001"),
            AlbumGrouping.key(artistRemoteId: nil, artistName: "Snoop Dogg", sortTitle: "2001"))
        // Diacritics folded on the name-fallback path.
        XCTAssertEqual(
            AlbumGrouping.key(artistRemoteId: nil, artistName: "Bjork", sortTitle: "Homogenic"),
            AlbumGrouping.key(artistRemoteId: nil, artistName: "Björk", sortTitle: "Homogenic"))
    }

    func testSynthesizeMissingAlbumArtists() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let repo = LibraryRepository(db)
        let server = makeServer()
        try await writer.saveServer(server)

        // A real artist (came back from /Artists) + an album whose album-artist
        // the server omitted from /Artists (only its name/id live on the album).
        try await writer.upsertArtists([Artist(id: "real", name: "Real Artist", sortName: "Real Artist")], serverId: server.id)
        try await writer.upsertAlbums([
            Album(id: "al1", title: "Known", artistName: "Real Artist", artistID: "real", year: 2020),
            Album(id: "al2", title: "Orphaned", artistName: "Steve Aoki", artistID: "aoki", year: 2019),
        ], serverId: server.id)

        // Before: "Steve Aoki" isn't in the artist list.
        let before = try await repo.artistsPage(serverId: server.id, offset: 0, limit: 50)
        XCTAssertFalse(before.contains { $0.remoteId == "aoki" })

        let synthesized = try await writer.synthesizeMissingAlbumArtists(serverId: server.id)
        XCTAssertEqual(synthesized, ["aoki"])

        // After: it appears in the artist list and its album is browsable.
        let after = try await repo.artistsPage(serverId: server.id, offset: 0, limit: 50)
        let aoki = try XCTUnwrap(after.first { $0.remoteId == "aoki" })
        XCTAssertEqual(aoki.name, "Steve Aoki")
        let aokiAlbums = try await repo.albums(forArtistRemoteId: "aoki", serverId: server.id)
        XCTAssertEqual(aokiAlbums.map(\.title), ["Orphaned"])

        // Idempotent: a second run doesn't duplicate.
        _ = try await writer.synthesizeMissingAlbumArtists(serverId: server.id)
        let afterAgain = try await repo.artistsPage(serverId: server.id, offset: 0, limit: 50)
        XCTAssertEqual(afterAgain.filter { $0.remoteId == "aoki" }.count, 1)

        // If the real artist later arrives from /Artists (same id), it takes over
        // the row — synthesis leaves it alone and the real metadata wins.
        try await writer.upsertArtists([
            Artist(id: "aoki", name: "Steve Aoki", sortName: "Aoki, Steve", artwork: ArtworkRef(key: "cover")),
        ], serverId: server.id)
        let synthesized2 = try await writer.synthesizeMissingAlbumArtists(serverId: server.id)
        XCTAssertFalse(synthesized2.contains("aoki"))
        let afterReal = try await repo.artistsPage(serverId: server.id, offset: 0, limit: 50)
        let real = try XCTUnwrap(afterReal.first { $0.remoteId == "aoki" })
        XCTAssertEqual(real.artworkKey, "cover")
    }

    func testPruneKeepsAlbumReferencedArtists() async throws {
        // Regression (HIGH): synthesized album-artists — which the server never
        // lists in /Artists — must SURVIVE a complete-sync prune as long as an
        // album still references them. Otherwise they oscillate browsable/pruned
        // every other sync (synthesized on odd syncs, pruned on even), silently
        // re-orphaning ~468 albums.
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let repo = LibraryRepository(db)
        let server = makeServer()
        try await writer.saveServer(server)

        try await writer.upsertArtists([Artist(id: "real", name: "Real Artist")], serverId: server.id)
        try await writer.upsertAlbums([
            Album(id: "al1", title: "Known", artistName: "Real Artist", artistID: "real"),
            Album(id: "al2", title: "Orphaned", artistName: "Steve Aoki", artistID: "aoki"),
        ], serverId: server.id)
        _ = try await writer.synthesizeMissingAlbumArtists(serverId: server.id)   // creates "aoki"

        // Simulate the NEXT complete sync's prune: the server lists only "real",
        // and "aoki" already exists so synthesis returns nothing for it. It's in
        // neither the keep-set nor a re-synthesis, yet must NOT be pruned because
        // album al2 still references it.
        _ = try await writer.pruneAlbums(serverId: server.id, keeping: ["al1", "al2"])
        _ = try await writer.pruneArtists(serverId: server.id, keeping: ["real"])
        let artists = try await repo.artistsPage(serverId: server.id, offset: 0, limit: 50)
        XCTAssertTrue(artists.contains { $0.remoteId == "aoki" },
                      "album-referenced artist must survive a prune that doesn't list it")
        let aokiAlbums = try await repo.albums(forArtistRemoteId: "aoki", serverId: server.id)
        XCTAssertEqual(aokiAlbums.count, 1)

        // Conversely, once its last album is gone the synthesized artist SHOULD
        // be cleaned up — the guard protects only artists a *surviving* album
        // references, so no orphaned synthesized rows leak.
        _ = try await writer.pruneAlbums(serverId: server.id, keeping: ["al1"])   // al2 removed
        _ = try await writer.pruneArtists(serverId: server.id, keeping: ["real"])
        let after = try await repo.artistsPage(serverId: server.id, offset: 0, limit: 50)
        XCTAssertFalse(after.contains { $0.remoteId == "aoki" },
                       "synthesized artist should be pruned once its last album is gone")
    }

    func testRecommendationSchemaRoundTripAndPruneSurvival() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let store = RecommendationStore(db)
        let server = makeServer()
        try await writer.saveServer(server)
        try await writer.upsertTracks([
            Track(id: "t1", title: "One", artistName: "A", genres: ["Rock"]),
            Track(id: "t2", title: "Two", artistName: "B", genres: ["Jazz"]),
        ], serverId: server.id)
        let ref1 = PlayEventStore.trackRef(serverId: server.id, remoteId: "t1")
        let ref2 = PlayEventStore.trackRef(serverId: server.id, remoteId: "t2")

        // track_features round-trip, including the reserved embedding BLOB.
        let emb = Data([1, 2, 3, 4])
        try await store.upsertTrackFeatures(TrackFeaturesRecord(
            trackRef: ref1, mbid: "mb1", genres: "[\"Rock\"]", bpm: 120,
            embedding: emb, embeddingDim: 1, featureSource: "ondevice"))
        let features = try await store.trackFeatures(forTrackRef: ref1)
        XCTAssertEqual(features?.mbid, "mb1")
        XCTAssertEqual(features?.bpm, 120)
        XCTAssertEqual(features?.embedding, emb)
        XCTAssertEqual(features?.featureSource, "ondevice")

        // recommendation set + items round-trip: rank order + in-library resolve.
        let set = RecommendationSetRecord(id: "mozz-weekly", title: "Mozz Weekly", kind: "forgotten")
        try await store.saveRecommendationSet(set, items: [
            RecommendationItemRecord(setId: "mozz-weekly", trackRef: ref2, rank: 1, score: 0.9, inLibrary: true, reason: "More Jazz"),
            RecommendationItemRecord(setId: "mozz-weekly", trackRef: ref1, rank: 2, score: 0.5, inLibrary: true, reason: "More Rock"),
            RecommendationItemRecord(setId: "mozz-weekly", trackRef: "ghost:x", rank: 3, score: 0.2, inLibrary: false, reason: "Discover"),
        ])
        let items = try await store.items(forSet: "mozz-weekly")
        XCTAssertEqual(items.map(\.rank), [1, 2, 3])
        XCTAssertEqual(items.first?.trackRef, ref2)
        let resolved = try await store.tracks(forSet: "mozz-weekly")
        XCTAssertEqual(resolved.map(\.remoteId), ["t2", "t1"])   // in-library only, in rank order
        let latest = try await store.latestSet(kind: "forgotten")
        XCTAssertEqual(latest?.id, "mozz-weekly")

        // PRUNE SURVIVAL: wipe the whole catalog. features + items key on the
        // opaque track_ref (no cascading FK), so a computed embedding / generated
        // mix must NOT be erased by a flaky sync that drops catalog rows.
        _ = try await writer.pruneTracks(serverId: server.id, keeping: [])
        let survivingFeatures = try await store.trackFeatures(forTrackRef: ref1)
        XCTAssertNotNil(survivingFeatures, "features must survive a track prune")
        let survivingItems = try await store.items(forSet: "mozz-weekly")
        XCTAssertEqual(survivingItems.count, 3, "recommendation items must survive a track prune")
        let resolvedAfterPrune = try await store.tracks(forSet: "mozz-weekly")
        XCTAssertTrue(resolvedAfterPrune.isEmpty, "resolved catalog rows are gone, but the set is intact")

        // A set's items DO cascade-delete with the set (regeneration / cleanup).
        try await db.write { database in
            try database.execute(sql: "DELETE FROM recommendation_set WHERE id = ?", arguments: ["mozz-weekly"])
        }
        let afterSetDelete = try await store.items(forSet: "mozz-weekly")
        XCTAssertTrue(afterSetDelete.isEmpty, "items cascade-delete with their set")
    }

    func testLikedTracksUnifiesFavoritesAndRatings() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let repo = LibraryRepository(db)
        let server = makeServer()
        try await writer.saveServer(server)
        try await writer.upsertTracks([
            Track(id: "fav", title: "Fav", artistName: "A", isFavorite: true),
            Track(id: "r5", title: "Rated5", artistName: "B", rating: 5),
            Track(id: "r4", title: "Rated4", artistName: "C", rating: 4),
            Track(id: "r3", title: "Rated3", artistName: "D", rating: 3),   // below threshold
            Track(id: "none", title: "Plain", artistName: "E"),
        ], serverId: server.id)

        let liked = try await repo.likedTracks(serverId: server.id)
        let ids = liked.map(\.remoteId)
        XCTAssertEqual(Set(ids), ["fav", "r5", "r4"], "favorites + rating>=4 only")
        XCTAssertFalse(ids.contains("r3"), "3★ is below the like threshold")
        XCTAssertFalse(ids.contains("none"))
        // Highest-rated first (favorite has no rating so sorts after rated ones).
        XCTAssertEqual(ids.first, "r5")
    }

    func testFavoritesStoreAppliesLocallyAndQueuesOutbox() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let repo = LibraryRepository(db)
        let store = FavoritesStore(db)
        let server = makeServer()
        try await writer.saveServer(server)
        try await writer.upsertTracks([Track(id: "t1", title: "One", artistName: "A")], serverId: server.id)

        // Jellyfin-style favorite.
        let likedNow = try await store.applyLocally(
            FavoriteChange(serverId: server.id, remoteId: "t1", value: .favorite(true)))
        XCTAssertTrue(likedNow)
        let isLikedAfter = try await store.isLiked(serverId: server.id, remoteId: "t1")
        XCTAssertTrue(isLikedAfter)
        let likedIds = try await repo.likedTracks(serverId: server.id).map(\.remoteId)
        XCTAssertEqual(likedIds, ["t1"])
        // A pending server write was queued.
        var pending = try await store.pending(serverId: server.id)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.kind, "favorite")
        XCTAssertEqual(pending.first?.isLiked, true)

        // Toggling again REPLACES the pending op (newest intent wins), not adds.
        _ = try await store.applyLocally(
            FavoriteChange(serverId: server.id, remoteId: "t1", value: .favorite(false)))
        pending = try await store.pending(serverId: server.id)
        XCTAssertEqual(pending.count, 1, "outbox keeps only the latest intent per track")
        XCTAssertEqual(pending.first?.isLiked, false)
        let isUnliked = try await store.isLiked(serverId: server.id, remoteId: "t1")
        XCTAssertFalse(isUnliked)

        // Flushing removes the pending op.
        let id = try XCTUnwrap(pending.first?.id)
        try await store.removePending(id: id)
        let remaining = try await store.pending(serverId: server.id)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testFavoritesStoreRatingCrossesLikeThreshold() async throws {
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let store = FavoritesStore(db)
        let server = makeServer(kind: .plex)
        try await writer.saveServer(server)
        try await writer.upsertTracks([Track(id: "t1", title: "One", artistName: "A")], serverId: server.id)

        // 3★ is not a like; 5★ is; clearing removes it.
        let liked3 = try await store.applyLocally(
            FavoriteChange(serverId: server.id, remoteId: "t1", value: .rating(3)))
        XCTAssertFalse(liked3)
        let liked5 = try await store.applyLocally(
            FavoriteChange(serverId: server.id, remoteId: "t1", value: .rating(5)))
        XCTAssertTrue(liked5)
        let isLikedAt5 = try await store.isLiked(serverId: server.id, remoteId: "t1")
        XCTAssertTrue(isLikedAt5)
        let likedCleared = try await store.applyLocally(
            FavoriteChange(serverId: server.id, remoteId: "t1", value: .rating(nil)))
        XCTAssertFalse(likedCleared)
        let isLikedCleared = try await store.isLiked(serverId: server.id, remoteId: "t1")
        XCTAssertFalse(isLikedCleared)
        let pending = try await store.pending(serverId: server.id)
        XCTAssertEqual(pending.first?.kind, "rating")
    }

    func testOutboxCompareAndDeletePreservesNewerIntent() async throws {
        // Regression (MEDIUM): a re-toggle while a server write is in flight must
        // not lose the newer intent. The flush deletes by (id, createdAt); if the
        // row was re-toggled mid-flight its createdAt changed, so the stale delete
        // no-ops and the newer intent stays queued.
        let db = try MusicDatabase.inMemory()
        let writer = CatalogWriter(db)
        let store = FavoritesStore(db)
        let server = makeServer()
        try await writer.saveServer(server)
        try await writer.upsertTracks([Track(id: "t1", title: "One", artistName: "A")], serverId: server.id)

        // Op A = like. Snapshot it (what an in-flight flush captured).
        _ = try await store.applyLocally(FavoriteChange(serverId: server.id, remoteId: "t1", value: .favorite(true)))
        let pendingA = try await store.pending(serverId: server.id)
        let opA = try XCTUnwrap(pendingA.first)

        // While "in flight", the user re-toggles to unlike — same row, new createdAt.
        try await Task.sleep(nanoseconds: 2_000_000)   // ensure a distinct timestamp
        _ = try await store.applyLocally(FavoriteChange(serverId: server.id, remoteId: "t1", value: .favorite(false)))

        // The flush's stale compare-and-delete (opA.createdAt) must NOT remove the
        // row that now holds the unlike.
        let opAId = try XCTUnwrap(opA.id)
        let deletedStale = try await store.removePending(id: opAId, ifUnchangedSince: opA.createdAt)
        XCTAssertFalse(deletedStale, "stale delete should no-op after a mid-flight re-toggle")
        let stillPending = try await store.pending(serverId: server.id)
        XCTAssertEqual(stillPending.count, 1)
        XCTAssertEqual(stillPending.first?.isLiked, false, "newer intent (unlike) survives")

        // Flushing the CURRENT op (matching createdAt) removes it.
        let current = try XCTUnwrap(stillPending.first)
        let currentId = try XCTUnwrap(current.id)
        let deleted = try await store.removePending(id: currentId, ifUnchangedSince: current.createdAt)
        XCTAssertTrue(deleted)
        let empty = try await store.pending(serverId: server.id)
        XCTAssertTrue(empty.isEmpty)
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
