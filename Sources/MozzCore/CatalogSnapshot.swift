import Foundation

/// The exact catalog a relay snapshot belongs to.
///
/// Server ids alone are insufficient: two Plex Home users can see different
/// libraries on the same server, and one account can select only some music
/// sections. A snapshot is reusable only when all four fields match.
public struct CatalogSnapshotScope: Codable, Sendable, Hashable {
    public var backend: BackendKind
    public var serverID: String
    public var accountID: String
    public var libraryIDs: [String]

    public init(
        backend: BackendKind,
        serverID: String,
        accountID: String,
        libraryIDs: [String] = []
    ) {
        self.backend = backend
        self.serverID = serverID
        self.accountID = accountID
        self.libraryIDs = Array(Set(libraryIDs.filter { !$0.isEmpty })).sorted()
    }
}

public extension CatalogSnapshotScope {
    init?(
        connection: ServerConnection,
        libraryIDs: [String]? = nil
    ) {
        let accountID: String
        if let userID = connection.userID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !userID.isEmpty {
            accountID = userID
        } else if connection.kind == .plex {
            // A Plex server has one owner. Managed/home users carry their Plex
            // user id; only the owner login lacks one.
            accountID = "owner"
        } else {
            return nil
        }
        self.init(
            backend: connection.kind,
            serverID: connection.id,
            accountID: accountID,
            libraryIDs: libraryIDs
                ?? connection.musicSectionID.map { [$0] }
                ?? [])
    }
}

public struct CatalogSnapshotCounts: Codable, Sendable, Equatable {
    public var artists: Int
    public var albums: Int
    public var tracks: Int
    public var playlists: Int
    public var playlistItems: Int

    public init(
        artists: Int = 0,
        albums: Int = 0,
        tracks: Int = 0,
        playlists: Int = 0,
        playlistItems: Int = 0
    ) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.playlists = playlists
        self.playlistItems = playlistItems
    }

    public static func + (
        lhs: CatalogSnapshotCounts,
        rhs: CatalogSnapshotCounts
    ) -> CatalogSnapshotCounts {
        CatalogSnapshotCounts(
            artists: lhs.artists + rhs.artists,
            albums: lhs.albums + rhs.albums,
            tracks: lhs.tracks + rhs.tracks,
            playlists: lhs.playlists + rhs.playlists,
            playlistItems: lhs.playlistItems + rhs.playlistItems)
    }
}

public enum CatalogSnapshotChunkKind: String, Codable, Sendable, Equatable {
    case artists
    case albums
    case tracks
    case playlists
    case playlistItems
}

public struct CatalogSnapshotPlaylistItems: Codable, Sendable, Equatable {
    public var playlistRemoteID: String
    public var startPosition: Int
    public var trackRemoteIDs: [String]

    public init(
        playlistRemoteID: String,
        startPosition: Int,
        trackRemoteIDs: [String]
    ) {
        self.playlistRemoteID = playlistRemoteID
        self.startPosition = startPosition
        self.trackRemoteIDs = trackRemoteIDs
    }
}

/// One bounded piece of a catalog snapshot.
///
/// Exactly one entity array is populated, as named by `kind`. Keeping chunks
/// independent lets a 100k-track library move through the relay without ever
/// materializing the entire catalog in memory.
public struct CatalogSnapshotChunk: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var sourceDeviceID: String
    public var scopeID: String
    public var kind: CatalogSnapshotChunkKind
    public var artists: [Artist]
    public var albums: [Album]
    public var tracks: [Track]
    public var playlists: [Playlist]
    public var playlistItems: [CatalogSnapshotPlaylistItems]

    public init(
        version: Int = currentVersion,
        sourceDeviceID: String,
        scopeID: String,
        artists: [Artist] = [],
        albums: [Album] = [],
        tracks: [Track] = [],
        playlists: [Playlist] = [],
        playlistItems: [CatalogSnapshotPlaylistItems] = []
    ) {
        self.version = version
        self.sourceDeviceID = sourceDeviceID
        self.scopeID = scopeID
        if !artists.isEmpty {
            kind = .artists
        } else if !albums.isEmpty {
            kind = .albums
        } else if !tracks.isEmpty {
            kind = .tracks
        } else if !playlists.isEmpty {
            kind = .playlists
        } else {
            kind = .playlistItems
        }
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.playlists = playlists
        self.playlistItems = playlistItems
    }

    public var counts: CatalogSnapshotCounts {
        CatalogSnapshotCounts(
            artists: artists.count,
            albums: albums.count,
            tracks: tracks.count,
            playlists: playlists.count,
            playlistItems: playlistItems.reduce(0) {
                $0 + $1.trackRemoteIDs.count
            })
    }

    public var recordCount: Int {
        artists.count + albums.count + tracks.count + playlists.count
            + playlistItems.count
    }
}
