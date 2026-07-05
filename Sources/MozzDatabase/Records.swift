import Foundation
import GRDB
import MozzCore

// MARK: - Server

/// A configured server connection row. Mirrors ``ServerConnection`` (the token
/// lives in the keychain, never here).
public struct ServerRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "server"

    public var id: String
    public var kind: String
    public var name: String
    public var baseURL: String
    public var userID: String?
    public var clientIdentifier: String
    public var musicSectionID: String?

    public init(_ connection: ServerConnection) {
        self.id = connection.id
        self.kind = connection.kind.rawValue
        self.name = connection.name
        self.baseURL = connection.baseURL.absoluteString
        self.userID = connection.userID
        self.clientIdentifier = connection.clientIdentifier
        self.musicSectionID = connection.musicSectionID
    }

    /// Reconstitute the domain value. Returns `nil` only if persisted data is
    /// corrupt (bad URL/kind).
    public var connection: ServerConnection? {
        guard let kind = BackendKind(rawValue: kind), let url = URL(string: baseURL) else {
            return nil
        }
        return ServerConnection(
            id: id, kind: kind, name: name, baseURL: url,
            userID: userID, clientIdentifier: clientIdentifier, musicSectionID: musicSectionID
        )
    }
}

// MARK: - Capabilities

/// Per-server detected capabilities. One row per server.
public struct CapabilitiesRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "serverCapabilities"

    public var serverId: String
    public var backend: String
    public var serverVersion: String?
    public var supportsTranscoding: Bool
    public var supportsOriginalFileDownload: Bool
    public var supportsFavorites: Bool
    public var supportsLyrics: Bool
    public var supportsSyncedLyrics: Bool
    public var supportsNormalizationGain: Bool
    public var supportsProgressReporting: Bool
    public var hasPlexPass: Bool?
    public var detectedAt: Double

    public init(serverId: String, capabilities: ServerCapabilities) {
        self.serverId = serverId
        self.backend = capabilities.backend.rawValue
        self.serverVersion = capabilities.serverVersion
        self.supportsTranscoding = capabilities.supportsTranscoding
        self.supportsOriginalFileDownload = capabilities.supportsOriginalFileDownload
        self.supportsFavorites = capabilities.supportsFavorites
        self.supportsLyrics = capabilities.supportsLyrics
        self.supportsSyncedLyrics = capabilities.supportsSyncedLyrics
        self.supportsNormalizationGain = capabilities.supportsNormalizationGain
        self.supportsProgressReporting = capabilities.supportsProgressReporting
        self.hasPlexPass = capabilities.hasPlexPass
        self.detectedAt = capabilities.detectedAt.timeIntervalSince1970
    }

    public var capabilities: ServerCapabilities? {
        guard let backend = BackendKind(rawValue: backend) else { return nil }
        return ServerCapabilities(
            backend: backend,
            serverVersion: serverVersion,
            supportsTranscoding: supportsTranscoding,
            supportsOriginalFileDownload: supportsOriginalFileDownload,
            supportsFavorites: supportsFavorites,
            supportsLyrics: supportsLyrics,
            supportsSyncedLyrics: supportsSyncedLyrics,
            supportsNormalizationGain: supportsNormalizationGain,
            supportsProgressReporting: supportsProgressReporting,
            hasPlexPass: hasPlexPass,
            detectedAt: Date(timeIntervalSince1970: detectedAt)
        )
    }
}

// MARK: - Catalog entities

/// An artist row. `id` is the internal integer key (also the FTS rowid);
/// (`serverId`, `remoteId`) is the stable identity used for upserts.
public struct ArtistRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "artist"

    public var id: Int64?
    public var serverId: String
    public var remoteId: String
    public var name: String
    public var sortName: String?
    public var artworkKey: String?
    public var albumCount: Int?
    public var isFavorite: Bool
    public var genres: [String]

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// An album row.
public struct AlbumRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "album"

    public var id: Int64?
    public var serverId: String
    public var remoteId: String
    public var title: String
    public var sortTitle: String?
    public var artistName: String
    public var artistRemoteId: String?
    public var year: Int?
    public var artworkKey: String?
    public var trackCount: Int?
    public var isFavorite: Bool
    public var addedAt: Double?
    public var genres: [String]
    /// Consolidation key (see `AlbumGrouping`) — the read layer groups album
    /// fragments by this so a split album shows as one. Defaulted so any
    /// memberwise construction (tests) stays source-compatible.
    public var albumGroupKey: String = ""

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A track row. Denormalized (album/artist names) for join-free list reads.
public struct TrackRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "track"

    public var id: Int64?
    public var serverId: String
    public var remoteId: String
    public var title: String
    public var sortTitle: String?
    public var albumTitle: String?
    public var albumRemoteId: String?
    public var artistName: String
    public var artistRemoteId: String?
    public var albumArtistName: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: Double
    public var container: String?
    public var codec: String?
    public var bitrateKbps: Int?
    public var sampleRateHz: Int?
    public var channels: Int?
    public var bitDepth: Int?
    public var fileSizeBytes: Int64?
    public var mediaKey: String?
    public var artworkKey: String?
    public var isFavorite: Bool
    public var normalizationGainDB: Double?
    public var addedAt: Double?
    public var genres: [String]

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A playlist header row.
public struct PlaylistRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "playlist"

    public var id: Int64?
    public var serverId: String
    public var remoteId: String
    public var title: String
    public var trackCount: Int?
    public var durationSeconds: Double?
    public var artworkKey: String?
    public var isSmart: Bool

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// An ordered playlist membership row. References a track by its stable remote
/// id (resolved to a local track on read) so playlist sync doesn't depend on
/// track sync ordering.
public struct PlaylistItemRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "playlistItem"

    public var id: Int64?
    public var playlistId: Int64
    public var trackRemoteId: String
    public var position: Int

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Listening history

/// An append-only listening-history event. Keyed on the stable `trackRef`
/// ("{serverId}:{remoteId}") — NOT the catalog `Int64 id` and NOT a cascading
/// foreign key — so history survives a catalog prune and re-add. Never mutated.
public struct PlayEventRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "play_event"

    public var id: Int64?
    public var trackRef: String
    public var kind: String
    public var positionSec: Double?
    public var durationSec: Double?
    public var context: String?
    public var contextId: String?
    public var device: String?
    public var createdAt: Double

    /// The table uses snake_case columns (per the shared data-model spec); map
    /// the camelCase Swift properties onto them.
    public enum CodingKeys: String, CodingKey {
        case id
        case trackRef = "track_ref"
        case kind
        case positionSec = "position_sec"
        case durationSec = "duration_sec"
        case context
        case contextId = "context_id"
        case device
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Downloads

/// The offline-download state for a track. Keyed by the track's internal id,
/// which upserts preserve across re-syncs so a completed download is never
/// orphaned by a catalog refresh.
public struct DownloadRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "download"

    /// The owning track's internal id.
    public var trackId: Int64
    public var state: String
    /// File location relative to the downloads root directory.
    public var localPath: String?
    /// Bytes received so far / final size for completed downloads.
    public var sizeBytes: Int64
    /// Expected total bytes, when known.
    public var totalBytes: Int64?
    public var requestedAt: Double
    public var completedAt: Double?
    public var errorMessage: String?

    public var id: Int64 { trackId }

    public var downloadState: DownloadState? { DownloadState(rawValue: state) }

    public init(
        trackId: Int64,
        state: DownloadState,
        localPath: String? = nil,
        sizeBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        requestedAt: Double = Date().timeIntervalSince1970,
        completedAt: Double? = nil,
        errorMessage: String? = nil
    ) {
        self.trackId = trackId
        self.state = state.rawValue
        self.localPath = localPath
        self.sizeBytes = sizeBytes
        self.totalBytes = totalBytes
        self.requestedAt = requestedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
    }
}

// MARK: - Recommendations & features

/// Per-track enrichment + a vector-ready sonic embedding (DATA_MODEL §2).
///
/// Keyed by the durable, opaque `track_ref` (NOT the catalog `Int64 id`) so a
/// computed embedding survives a catalog prune / re-add. `embedding` is a
/// packed little-endian `Float32` vector (L2-normalized), nil until an analyzer
/// runs; the schema reserves it now so on-device sonic slots in with no later
/// migration.
public struct TrackFeaturesRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "track_features"

    public var trackRef: String
    public var mbid: String?
    public var artistMbid: String?
    /// JSON array of folksonomy genres.
    public var genres: String?
    /// JSON array of moods/styles.
    public var tags: String?
    public var bpm: Double?
    public var replaygainDb: Double?
    /// Packed little-endian Float32 vector (L2-normalized), nil until analyzed.
    public var embedding: Data?
    public var embeddingDim: Int?
    /// Which sonic source produced `embedding`: ondevice|audiomuse|plex.
    public var featureSource: String?
    public var updatedAt: Double

    public var id: String { trackRef }

    public enum CodingKeys: String, CodingKey {
        case trackRef = "track_ref"
        case mbid
        case artistMbid = "artist_mbid"
        case genres
        case tags
        case bpm
        case replaygainDb = "replaygain_db"
        case embedding
        case embeddingDim = "embedding_dim"
        case featureSource = "feature_source"
        case updatedAt = "updated_at"
    }

    public init(
        trackRef: String,
        mbid: String? = nil,
        artistMbid: String? = nil,
        genres: String? = nil,
        tags: String? = nil,
        bpm: Double? = nil,
        replaygainDb: Double? = nil,
        embedding: Data? = nil,
        embeddingDim: Int? = nil,
        featureSource: String? = nil,
        updatedAt: Double = Date().timeIntervalSince1970
    ) {
        self.trackRef = trackRef
        self.mbid = mbid
        self.artistMbid = artistMbid
        self.genres = genres
        self.tags = tags
        self.bpm = bpm
        self.replaygainDb = replaygainDb
        self.embedding = embedding
        self.embeddingDim = embeddingDim
        self.featureSource = featureSource
        self.updatedAt = updatedAt
    }
}

/// A precomputed, ranked recommendation set (DATA_MODEL §3), persisted so the UI
/// is instant + offline and never computes on the main thread / on view load.
public struct RecommendationSetRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "recommendation_set"

    public var id: String
    public var title: String
    /// daily_mix|discover|artist_radio|forgotten
    public var kind: String
    public var generatedAt: Double
    /// JSON: seed, weights, filters.
    public var params: String?

    public enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind
        case generatedAt = "generated_at"
        case params
    }

    public init(id: String, title: String, kind: String,
                generatedAt: Double = Date().timeIntervalSince1970, params: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.generatedAt = generatedAt
        self.params = params
    }
}

/// One ranked entry in a ``RecommendationSetRecord``. Keys on the durable
/// `track_ref`; `inLibrary == false` marks an out-of-library discovery pick.
/// Cascade-deleted with its set (a regenerated set replaces its items).
public struct RecommendationItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "recommendation_item"

    public var setId: String
    public var trackRef: String
    public var rank: Int
    public var score: Double
    public var inLibrary: Bool
    public var reason: String?

    public enum CodingKeys: String, CodingKey {
        case setId = "set_id"
        case trackRef = "track_ref"
        case rank
        case score
        case inLibrary = "in_library"
        case reason
    }

    public init(setId: String, trackRef: String, rank: Int, score: Double,
                inLibrary: Bool, reason: String? = nil) {
        self.setId = setId
        self.trackRef = trackRef
        self.rank = rank
        self.score = score
        self.inLibrary = inLibrary
        self.reason = reason
    }
}
