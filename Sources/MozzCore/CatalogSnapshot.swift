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
    /// Analyzed sonic vectors. Not part of the catalog itself - a vector is
    /// something a device computed, not something the server told it - but
    /// counted here because it travels through the same chunks.
    public var features: Int

    public init(
        artists: Int = 0,
        albums: Int = 0,
        tracks: Int = 0,
        playlists: Int = 0,
        playlistItems: Int = 0,
        features: Int = 0
    ) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.playlists = playlists
        self.playlistItems = playlistItems
        self.features = features
    }

    /// Hand-written so that `features` may be absent.
    ///
    /// Indexes written before this field existed are still in the relay, and a
    /// synthesized decoder would reject every one of them - which on a phone
    /// looks like the whole catalog disappearing rather than like a schema
    /// change.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artists = try container.decode(Int.self, forKey: .artists)
        albums = try container.decode(Int.self, forKey: .albums)
        tracks = try container.decode(Int.self, forKey: .tracks)
        playlists = try container.decode(Int.self, forKey: .playlists)
        playlistItems = try container.decode(Int.self, forKey: .playlistItems)
        features = try container.decodeIfPresent(Int.self, forKey: .features) ?? 0
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
            playlistItems: lhs.playlistItems + rhs.playlistItems,
            features: lhs.features + rhs.features)
    }
}

public enum CatalogSnapshotChunkKind: String, Codable, Sendable, Equatable {
    case artists
    case albums
    case tracks
    case playlists
    case playlistItems
    /// Analyzed sonic vectors, carried in their own snapshot rather than in the
    /// catalog one - see ``SonicFeatureSnapshotRow``. A device that predates
    /// this never asks for that snapshot, so it never meets this kind.
    case features
}

/// One analyzed track, as it travels between a listener's own devices.
///
/// The point of moving these at all: analysis is hours of a phone's evening,
/// and the answer is identical wherever it runs. The DSP and the learned engine
/// are both deliberately free of platform frameworks so a vector computed on a
/// Pixel lands in the same place as the same track computed on an iPhone - and
/// if that were not true, sharing them would quietly corrupt both libraries
/// rather than save anyone any time.
///
/// Keyed by the durable `track_ref` (`serverId:remoteId`), which is what makes
/// it portable: the local row id is not the same number on two devices.
public struct SonicFeatureSnapshotRow: Codable, Sendable, Equatable {
    public var trackRef: String
    /// The analyzer's `name@version`, as `track_features.feature_source`.
    ///
    /// Carried and checked, never assumed. Two engines are coordinates in two
    /// unrelated spaces, so a vector under the wrong name is worse than a
    /// missing one: it is a wrong answer that looks like a right one.
    public var engine: String
    public var vector: [Float]
    /// The tempo measured alongside the vector, where one was found.
    public var bpm: Double?

    public init(trackRef: String, engine: String, vector: [Float], bpm: Double? = nil) {
        self.trackRef = trackRef
        self.engine = engine
        self.vector = vector
        self.bpm = bpm
    }
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
///
/// `features` decodes as absent-means-empty, because chunks written before it
/// existed are still sitting in relays.
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
    public var features: [SonicFeatureSnapshotRow]

    public init(
        version: Int = currentVersion,
        sourceDeviceID: String,
        scopeID: String,
        artists: [Artist] = [],
        albums: [Album] = [],
        tracks: [Track] = [],
        playlists: [Playlist] = [],
        playlistItems: [CatalogSnapshotPlaylistItems] = [],
        features: [SonicFeatureSnapshotRow] = []
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
        } else if !features.isEmpty {
            kind = .features
        } else {
            kind = .playlistItems
        }
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.playlists = playlists
        self.playlistItems = playlistItems
        self.features = features
    }

    /// Hand-written so `features` may be absent: chunks written before it
    /// existed are still sitting in relays, and a synthesized decoder would
    /// reject every one of them.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        sourceDeviceID = try container.decode(String.self, forKey: .sourceDeviceID)
        scopeID = try container.decode(String.self, forKey: .scopeID)
        kind = try container.decode(CatalogSnapshotChunkKind.self, forKey: .kind)
        artists = try container.decode([Artist].self, forKey: .artists)
        albums = try container.decode([Album].self, forKey: .albums)
        tracks = try container.decode([Track].self, forKey: .tracks)
        playlists = try container.decode([Playlist].self, forKey: .playlists)
        playlistItems = try container.decode(
            [CatalogSnapshotPlaylistItems].self, forKey: .playlistItems)
        features = try container.decodeIfPresent(
            [SonicFeatureSnapshotRow].self, forKey: .features) ?? []
    }

    public var counts: CatalogSnapshotCounts {
        CatalogSnapshotCounts(
            artists: artists.count,
            albums: albums.count,
            tracks: tracks.count,
            playlists: playlists.count,
            playlistItems: playlistItems.reduce(0) {
                $0 + $1.trackRemoteIDs.count
            },
            features: features.count)
    }

    public var recordCount: Int {
        artists.count + albums.count + tracks.count + playlists.count
            + playlistItems.count + features.count
    }
}
