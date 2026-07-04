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
        Self.page(tracks, offset: offset, limit: limit)
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

    private static func page<T>(_ all: [T], offset: Int, limit: Int) -> CatalogPage<T> {
        guard offset < all.count else { return CatalogPage(items: [], totalCount: all.count) }
        let end = min(offset + limit, all.count)
        return CatalogPage(items: Array(all[offset..<end]), totalCount: all.count)
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

    func testProgressPhasesAreReportedInOrder() async throws {
        let database = try MusicDatabase.inMemory()
        var backend = MockBackend()
        backend.artists = makeArtists(2)
        backend.tracks = makeTracks(2)

        let collector = PhaseCollector()
        let engine = LibrarySyncEngine(backend: backend, database: database)
        _ = try await engine.sync { collector.record($0.phase) }

        XCTAssertEqual(collector.phases.first, .capabilities)
        XCTAssertEqual(collector.phases.last, .done)
        XCTAssertTrue(collector.phases.contains(.tracks))
        XCTAssertTrue(collector.phases.contains(.pruning))
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
}
