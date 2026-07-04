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
