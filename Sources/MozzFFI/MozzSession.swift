import Foundation
#if canImport(FoundationNetworking)
// Off Apple the URL loading system is its own module. The artwork fetch below
// uses URLSession directly, and this facade is what the Windows and Linux
// shells link, so it has to import it where it actually lives.
import FoundationNetworking
#endif
import MozzCommands
import MozzContinuity
import MozzCore
import MozzDatabase
import MozzEnrichment
import MozzJellyfin
import MozzRecommend
import MozzSubsonic

// MARK: - The session facade
//
// The probes in `MozzFFI.swift` answer "does this platform work at all". This
// file is the API a real client actually drives — a Windows or Android UI
// browsing a library.
//
// SHAPE, AND WHY
//
// One entry point, not fifty:
//
//     mozz_session_open(dbPath)          -> handle
//     mozz_session_call(handle, request) -> response
//     mozz_session_close(handle)
//
// Every operation is a JSON request naming a command. Adding a capability means
// adding a case, not exporting another C symbol and re-declaring it in every
// consumer — which matters a great deal when the consumers are written in
// different languages by different toolchains.
//
// STATEFUL, unlike the spike. The probe reopened the database on every call,
// which was fine for measuring but would be absurd for a UI: `MusicDatabase`
// holds a connection pool, and paging a list means hundreds of reads a second.
// The handle owns that pool for the life of the session.
//
// Requests carry an `id` that is echoed in the response, so a client is free to
// pipeline calls across threads without correlating by arrival order.

// MARK: - Envelope

struct SessionRequest: Decodable {
    var id: Int?
    var cmd: String
    var serverId: String?
    var offset: Int?
    var limit: Int?
    var query: String?
    var remoteId: String?
    var artistRemoteId: String?
    var groupKey: String?
    var genre: String?
    /// Opaque resume position for a paged listing; see LibraryRepository.PageCursor.
    var cursor: String?
    /// Spec-name alias for cursor-paged detail shelves.
    var after: String?
    var trackCount: Int?
    var year: Int?

    // Server connection / sync / streaming. See `MozzSessionServer.swift`.
    var kind: String?
    var baseURL: String?
    var username: String?
    var password: String?
    var apiKey: String?
    var token: String?
    var accountToken: String?
    var userID: String?
    var serverName: String?
    var clientIdentifier: String?
    var serverMachineIdentifier: String?
    var musicSectionID: String?
    var pinId: Int?
    var code: String?
    var artworkKey: String?
    var size: Int?
    var maxBitrateKbps: Int?
    var forceTranscode: Bool?
    var itemType: String?

    // Listening history.
    var eventKind: String?
    var state: String?
    var positionSeconds: Double?
    var durationSeconds: Double?
    var positionMS: Int64?
    var durationMS: Int64?
    var createdAtMS: Int64?
    var context: String?
    var contextId: String?
    var contextID: String?
    var deviceId: String?
    var deviceID: String?
    var deviceName: String?
    var sinceMS: Int64?
    var windowDays: Int?
    var maxBytes: Int?
    var batch: HistoryExchangeBatch?
    var batches: [HistoryExchangeBatch]?

    // Lyrics.
    var useLRCLIB: Bool?
    var userInitiated: Bool?
    var leadSeconds: Double?

    // Favorites / ratings.
    var liked: Bool?
    var isFavorite: Bool?
    var rating: Double?
    var flush: Bool?

    // Continuity.
    var playbackRunID: String?
    var cursorSequence: UInt64?
    var capturedAtMS: Int64?
    var currentRemoteID: String?
    var currentAbsoluteIndex: Int?
    var queue: WireContinuityQueueInput?
    var descriptor: WireQueueDescriptor?
    var items: [WireContinuityItemInput]?
    var repeatMode: String?
    var isShuffled: Bool?
    var totalCount: Int?
    var startAbsoluteIndex: Int?
    var windowStartAbsoluteIndex: Int?

    // Recommendations.
    var setId: String?
    var seed: UInt64?
    var seedTitle: String?
    var seedGenres: [String]?
    var seedArtistIds: [String]?
    var seedTrackRef: String?
    var excluding: [String]?
}

/// The server commands take the same envelope; the alias only keeps the two
/// files readable about which half of it they are using.
typealias ServerRequest = SessionRequest

private struct SessionResponse<Payload: Encodable>: Encodable {
    var id: Int?
    var ok: Bool
    var cmd: String
    var payload: Payload?
    var error: String?
    /// Where to resume a paged listing, or absent on the last page. Sits on the
    /// envelope rather than inside the payload so the payload stays a plain
    /// array — a client that ignores paging is unaffected.
    var nextCursor: String?
}

// MARK: - Wire models
//
// Deliberately NOT the database records. A record is a storage row; these are a
// view contract. Keeping them apart means a schema change does not silently
// reshape a UI written in another language, and it keeps columns the client has
// no business seeing out of the payload.

private struct WireServer: Encodable {
    var id: String
    var kind: String
    var name: String
    var baseURL: String
}

struct WireAccount: Encodable {
    var displayName: String?
    var username: String?
    var avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case displayName, username, avatarURL
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(username, forKey: .username)
        try container.encode(avatarURL, forKey: .avatarURL)
    }
}

private struct WireArtist: Encodable {
    var id: Int64
    var remoteId: String
    var serverId: String
    var name: String
    var artworkKey: String?
}

private struct WireAlbum: Encodable {
    var id: Int64
    var remoteId: String
    var serverId: String
    var title: String
    var artistName: String
    var artistRemoteId: String?
    var year: Int?
    var trackCount: Int?
    var artworkKey: String?
    var groupKey: String
}

private struct WireArtistHeader: Encodable {
    var remoteId: String
    var serverId: String
    var name: String
    var sortName: String?
    var artworkKey: String?
    var heroArtworkKey: String?
    var albumCount: Int?
    var genres: [String]
    var isFavorite: Bool

    enum CodingKeys: String, CodingKey {
        case remoteId, serverId, name, sortName, artworkKey, heroArtworkKey, albumCount, genres, isFavorite
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(remoteId, forKey: .remoteId)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(name, forKey: .name)
        try container.encode(sortName, forKey: .sortName)
        try container.encode(artworkKey, forKey: .artworkKey)
        try container.encode(heroArtworkKey, forKey: .heroArtworkKey)
        try container.encode(albumCount, forKey: .albumCount)
        try container.encode(genres, forKey: .genres)
        try container.encode(isFavorite, forKey: .isFavorite)
    }
}

private struct WireAlbumHeader: Encodable {
    var remoteId: String
    var serverId: String
    var title: String
    var sortTitle: String?
    var artistName: String
    var artistRemoteId: String?
    var year: Int?
    var artworkKey: String?
    var trackCount: Int?
    var genres: [String]
    var isFavorite: Bool
    var addedAt: Double?

    enum CodingKeys: String, CodingKey {
        case remoteId, serverId, title, sortTitle, artistName, artistRemoteId, year, artworkKey
        case trackCount, genres, isFavorite, addedAt
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(remoteId, forKey: .remoteId)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(title, forKey: .title)
        try container.encode(sortTitle, forKey: .sortTitle)
        try container.encode(artistName, forKey: .artistName)
        try container.encode(artistRemoteId, forKey: .artistRemoteId)
        try container.encode(year, forKey: .year)
        try container.encode(artworkKey, forKey: .artworkKey)
        try container.encode(trackCount, forKey: .trackCount)
        try container.encode(genres, forKey: .genres)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(addedAt, forKey: .addedAt)
    }
}

private struct WireAlbumPage: Encodable {
    var items: [WireAlbumHeader]
    var nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items, nextCursor
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encode(nextCursor, forKey: .nextCursor)
    }
}

private struct WireTrack: Encodable {
    var id: Int64
    var remoteId: String
    var serverId: String
    var title: String
    var artistName: String
    var albumTitle: String?
    var albumRemoteId: String?
    var trackNumber: Int?
    var discNumber: Int?
    var durationSeconds: Double
    var artworkKey: String?
    var isFavorite: Bool
    var rating: Double?
    var addedAt: Double?
    /// ReplayGain in dB, when the server supplied one. Carried across the
    /// boundary because without it a client has no way to level a library, and
    /// the loudness difference between two albums is the most audible thing a
    /// music player can get wrong.
    var normalizationGainDB: Double?

    enum CodingKeys: String, CodingKey {
        case id, remoteId, serverId, title, artistName, albumTitle, albumRemoteId
        case trackNumber, discNumber, durationSeconds, artworkKey, isFavorite
        case rating, addedAt, normalizationGainDB
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(remoteId, forKey: .remoteId)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(title, forKey: .title)
        try container.encode(artistName, forKey: .artistName)
        try container.encodeIfPresent(albumTitle, forKey: .albumTitle)
        try container.encodeIfPresent(albumRemoteId, forKey: .albumRemoteId)
        try container.encodeIfPresent(trackNumber, forKey: .trackNumber)
        try container.encodeIfPresent(discNumber, forKey: .discNumber)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encodeIfPresent(artworkKey, forKey: .artworkKey)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encodeIfPresent(rating, forKey: .rating)
        try container.encodeIfPresent(addedAt, forKey: .addedAt)
        try container.encodeIfPresent(normalizationGainDB, forKey: .normalizationGainDB)
    }
}

private struct WirePlaylist: Encodable {
    var id: Int64
    var remoteId: String
    var serverId: String
    var title: String
    var trackCount: Int?
}

private struct WireCounts: Encodable {
    var artists: Int
    var albums: Int
    var tracks: Int
}

private struct WireSearchResults: Encodable {
    var artists: [WireArtist]
    var albums: [WireAlbum]
    var tracks: [WireTrack]
}

private struct WireHomeMix: Encodable {
    var id: String
    var title: String
    var subtitle: String?
    var kind: String
    var artworkKey: String?
    var generatedAt: Double
}

private struct WireRecommendationSet: Encodable {
    var id: String
    var title: String
    var kind: String
    var generatedAt: Double
}

private struct WireRecommendationItem: Encodable {
    var setId: String
    var trackRef: String
    var rank: Int
    var score: Double
    var inLibrary: Bool
    var reason: String?
}

private struct WireRadioBatch: Encodable {
    var remoteIds: [String]
    var tracks: [WireTrack]
}

private struct WireAlbumReleaseKind: Encodable {
    var kind: String
    var isSingleOrEP: Bool
}

private struct WireSuppression: Encodable {
    var scope: String
    var ref: String
    var createdAt: Double
}

private struct WireAction: Encodable {
    var ok: Bool
}

private struct WireHistoryImport: Encodable {
    var imported: Int
}

private struct WireFavoriteMutation: Encodable {
    var serverId: String
    var remoteId: String
    var itemType: String
    var kind: String
    var value: Double?
    var liked: Bool
    var queued: Bool
    var synced: Bool

    enum CodingKeys: String, CodingKey {
        case serverId, remoteId, itemType, kind, value, liked, queued, synced
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(remoteId, forKey: .remoteId)
        try container.encode(itemType, forKey: .itemType)
        try container.encode(kind, forKey: .kind)
        try container.encode(value, forKey: .value)
        try container.encode(liked, forKey: .liked)
        try container.encode(queued, forKey: .queued)
        try container.encode(synced, forKey: .synced)
    }
}

private struct WirePlaybackReportResult: Encodable {
    var reported: Bool
}

private struct WireLyricsLine: Encodable {
    var text: String
    var startSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case text, startSeconds
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(startSeconds, forKey: .startSeconds)
    }
}

private struct WireLyrics: Encodable {
    var source: String?
    var sourceDisplayName: String?
    var isSynced: Bool
    var lines: [WireLyricsLine]

    enum CodingKeys: String, CodingKey {
        case source, sourceDisplayName, isSynced, lines
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(sourceDisplayName, forKey: .sourceDisplayName)
        try container.encode(isSynced, forKey: .isSynced)
        try container.encode(lines, forKey: .lines)
    }
}

private struct WireLyricsResolution: Encodable {
    var status: String
    var staySilent: Bool
    var activeLineIndex: Int?
    var lyrics: WireLyrics?

    enum CodingKeys: String, CodingKey {
        case status, staySilent, activeLineIndex, lyrics
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(staySilent, forKey: .staySilent)
        try container.encode(activeLineIndex, forKey: .activeLineIndex)
        try container.encode(lyrics, forKey: .lyrics)
    }
}

struct WireServerAccountFingerprint: Codable, Sendable, Hashable {
    var backend: String
    var serverID: String
    var accountID: String
}

struct WireTrackLocator: Codable, Sendable, Hashable {
    var server: WireServerAccountFingerprint
    var remoteID: String
}

struct WireQueueDescriptor: Codable, Sendable, Hashable {
    var kind: String
    var sourceID: String?
    var sourceRevision: String?
}

struct WireContinuityItemInput: Codable, Sendable, Hashable {
    var remoteID: String
    var backend: String?
    var serverID: String?
    var accountID: String?
    var baseOrdinal: Int
    var title: String
    var artist: String
    var durationMS: Int64
    var artworkKey: String?
}

struct WireContinuityQueueInput: Codable, Sendable, Hashable {
    var descriptor: WireQueueDescriptor
    var items: [WireContinuityItemInput]
    var repeatMode: String
    var isShuffled: Bool
    var totalCount: Int
    var startAbsoluteIndex: Int?
    var windowStartAbsoluteIndex: Int?
    var isTruncated: Bool?
}

private struct WireContinuityItem: Encodable {
    var locator: WireTrackLocator
    var baseOrdinal: Int
    var title: String
    var artist: String
    var durationMS: Int64
    var artworkKey: String?

    enum CodingKeys: String, CodingKey {
        case locator, baseOrdinal, title, artist, durationMS, artworkKey
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(locator, forKey: .locator)
        try container.encode(baseOrdinal, forKey: .baseOrdinal)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(durationMS, forKey: .durationMS)
        try container.encode(artworkKey, forKey: .artworkKey)
    }
}

private struct WireContinuityQueue: Encodable {
    var queueHash: String
    var descriptor: WireQueueDescriptor
    var items: [WireContinuityItem]
    var startAbsoluteIndex: Int
    var totalCount: Int
    var isTruncated: Bool
    var repeatMode: String
    var isShuffled: Bool
}

private struct WireContinuityCursor: Encodable {
    var playbackRunID: String
    var deviceID: String
    var deviceName: String
    var deviceKind: String?
    var cursorSequence: UInt64
    var capturedAtMS: Int64
    var state: String
    var current: WireTrackLocator
    var currentAbsoluteIndex: Int
    var positionMS: Int64
    var queueHash: String?

    enum CodingKeys: String, CodingKey {
        case playbackRunID, deviceID, deviceName, deviceKind, cursorSequence, capturedAtMS
        case state, current, currentAbsoluteIndex, positionMS, queueHash
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(playbackRunID, forKey: .playbackRunID)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(deviceKind, forKey: .deviceKind)
        try container.encode(cursorSequence, forKey: .cursorSequence)
        try container.encode(capturedAtMS, forKey: .capturedAtMS)
        try container.encode(state, forKey: .state)
        try container.encode(current, forKey: .current)
        try container.encode(currentAbsoluteIndex, forKey: .currentAbsoluteIndex)
        try container.encode(positionMS, forKey: .positionMS)
        try container.encode(queueHash, forKey: .queueHash)
    }
}

private struct WireContinuitySnapshot: Encodable {
    var cursor: WireContinuityCursor
    var queue: WireContinuityQueue?
    var isQueueMissing: Bool
    var hydratedTracks: [WireTrack]

    enum CodingKeys: String, CodingKey {
        case cursor, queue, isQueueMissing, hydratedTracks
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cursor, forKey: .cursor)
        try container.encode(queue, forKey: .queue)
        try container.encode(isQueueMissing, forKey: .isQueueMissing)
        try container.encode(hydratedTracks, forKey: .hydratedTracks)
    }
}

private struct WireContinuityHash: Encodable {
    var queueHash: String
    var canonicalByteCount: Int
    var canonicalBytesHex: String
}

private struct WireContinuitySave: Encodable {
    var saved: Bool
    var queueHash: String?
}

// MARK: - Mapping

private func wire(_ r: ArtistRecord) -> WireArtist {
    WireArtist(
        id: r.id ?? 0, remoteId: r.remoteId, serverId: r.serverId,
        name: r.name, artworkKey: r.artworkKey
    )
}

private func wire(_ r: AlbumRecord) -> WireAlbum {
    WireAlbum(
        id: r.id ?? 0, remoteId: r.remoteId, serverId: r.serverId,
        title: r.title, artistName: r.artistName, artistRemoteId: r.artistRemoteId,
        year: r.year, trackCount: r.trackCount, artworkKey: r.artworkKey,
        groupKey: r.albumGroupKey
    )
}

private func wireHeader(_ r: ArtistRecord, heroArtworkKey: String? = nil) -> WireArtistHeader {
    WireArtistHeader(
        remoteId: r.remoteId, serverId: r.serverId, name: r.name,
        sortName: r.sortName, artworkKey: r.artworkKey,
        heroArtworkKey: heroArtworkKey ?? r.artworkKey,
        albumCount: r.albumCount, genres: r.genres, isFavorite: r.isFavorite
    )
}

private func wireHeader(_ r: AlbumRecord) -> WireAlbumHeader {
    WireAlbumHeader(
        remoteId: r.remoteId, serverId: r.serverId, title: r.title,
        sortTitle: r.sortTitle, artistName: r.artistName,
        artistRemoteId: r.artistRemoteId, year: r.year, artworkKey: r.artworkKey,
        trackCount: r.trackCount, genres: r.genres, isFavorite: r.isFavorite,
        addedAt: r.addedAt
    )
}

private func wire(_ r: TrackRecord) -> WireTrack {
    WireTrack(
        id: r.id ?? 0, remoteId: r.remoteId, serverId: r.serverId,
        title: r.title, artistName: r.artistName, albumTitle: r.albumTitle,
        albumRemoteId: r.albumRemoteId, trackNumber: r.trackNumber,
        discNumber: r.discNumber, durationSeconds: r.duration,
        artworkKey: r.artworkKey, isFavorite: r.isFavorite,
        rating: r.rating,
        addedAt: r.addedAt,
        normalizationGainDB: r.normalizationGainDB
    )
}

private func wire(_ r: PlaylistRecord) -> WirePlaylist {
    WirePlaylist(
        id: r.id ?? 0, remoteId: r.remoteId, serverId: r.serverId,
        title: r.title, trackCount: r.trackCount
    )
}

private func wire(_ m: RecommendationService.HomeMix) -> WireHomeMix {
    WireHomeMix(id: m.id, title: m.title, subtitle: m.subtitle, kind: m.kind,
                artworkKey: m.artworkKey, generatedAt: m.generatedAt)
}

private func wire(_ r: RecommendationSetRecord) -> WireRecommendationSet {
    WireRecommendationSet(id: r.id, title: r.title, kind: r.kind, generatedAt: r.generatedAt)
}

private func wire(_ r: RecommendationItemRecord) -> WireRecommendationItem {
    WireRecommendationItem(setId: r.setId, trackRef: r.trackRef, rank: r.rank,
                           score: r.score, inLibrary: r.inLibrary, reason: r.reason)
}

private func wire(_ lyrics: Lyrics) -> WireLyrics {
    WireLyrics(
        source: lyrics.source?.rawValue,
        sourceDisplayName: lyrics.source?.displayName,
        isSynced: lyrics.isSynced,
        lines: lyrics.lines.map { WireLyricsLine(text: $0.text, startSeconds: $0.start) }
    )
}

private func wire(_ fingerprint: ServerAccountFingerprint) -> WireServerAccountFingerprint {
    WireServerAccountFingerprint(
        backend: fingerprint.backend.rawValue,
        serverID: fingerprint.serverID,
        accountID: fingerprint.accountID
    )
}

private func wire(_ locator: TrackLocator) -> WireTrackLocator {
    WireTrackLocator(server: wire(locator.server), remoteID: locator.remoteID)
}

private func wire(_ descriptor: QueueDescriptor) -> WireQueueDescriptor {
    WireQueueDescriptor(
        kind: descriptor.kind.rawValue,
        sourceID: descriptor.sourceID,
        sourceRevision: descriptor.sourceRevision
    )
}

private func wire(_ item: ContinuityItem) -> WireContinuityItem {
    WireContinuityItem(
        locator: wire(item.locator),
        baseOrdinal: item.baseOrdinal,
        title: item.title,
        artist: item.artist,
        durationMS: item.durationMS,
        artworkKey: item.artwork?.key
    )
}

private func wire(_ queue: ContinuityQueue) -> WireContinuityQueue {
    WireContinuityQueue(
        queueHash: queue.queueHash,
        descriptor: wire(queue.descriptor),
        items: queue.items.map(wire),
        startAbsoluteIndex: queue.startAbsoluteIndex,
        totalCount: queue.totalCount,
        isTruncated: queue.isTruncated,
        repeatMode: queue.repeatMode.rawValue,
        isShuffled: queue.isShuffled
    )
}

private func wire(_ cursor: ContinuityCursor) -> WireContinuityCursor {
    WireContinuityCursor(
        playbackRunID: cursor.playbackRunID.uuidString,
        deviceID: cursor.deviceID,
        deviceName: cursor.deviceName,
        deviceKind: cursor.deviceKind?.rawValue,
        cursorSequence: cursor.cursorSequence,
        capturedAtMS: cursor.capturedAtMS,
        state: cursor.state.rawValue,
        current: wire(cursor.current),
        currentAbsoluteIndex: cursor.currentAbsoluteIndex,
        positionMS: cursor.positionMS,
        queueHash: cursor.queueHash
    )
}

private func wire(_ snapshot: ContinuitySnapshot, hydrated: [TrackRecord]) -> WireContinuitySnapshot {
    WireContinuitySnapshot(
        cursor: wire(snapshot.cursor),
        queue: snapshot.queue.map(wire),
        isQueueMissing: snapshot.isQueueMissing,
        hydratedTracks: hydrated.map(wire)
    )
}

// MARK: - Session

/// One open library, owning the database pool for its lifetime.
final class MozzSession: @unchecked Sendable {
    let database: MusicDatabase
    let repository: LibraryRepository
    let recommendations: RecommendationService
    let lyrics: LyricsService
    let favorites: FavoritesStore
    /// Servers this session has been given credentials for. Empty until the
    /// host calls `attach`; browsing a previously-synced library needs none.
    let backends = BackendTable()
    /// The core's artwork cache. Resolves a reference through whichever backend
    /// is attached, downloads it, and keeps it on disk under a byte budget so
    /// every shell stops solving that separately. `var` only so a test can swap
    /// in a store pointed at a temp directory with a scripted fetch.
    var artworkStore: ArtworkStore
    /// The session's audio engine, behind the Facade.
    ///
    /// One per session rather than one per request, because an engine that did
    /// not outlive a single command could not play anything: the next command
    /// would find a different engine with nothing loaded. Building it per
    /// request is what made every playback command answer "not available".
    ///
    /// The engine itself is still constructed lazily inside the service, on the
    /// first play — it opens the output device the moment it exists, and on iOS
    /// a device opened before the audio session is active emits silence while
    /// reporting itself healthy.
    let playback: PlaybackCommandService

    init(path: String) throws {
        self.database = try MusicDatabase.open(at: URL(fileURLWithPath: path))
        self.repository = LibraryRepository(database)
        self.recommendations = RecommendationService(store: RecommendationStore(database))
        self.lyrics = LyricsService()
        self.favorites = FavoritesStore(database)
        // Capture the backend table, not `self`: the fetch closure resolves the
        // reference against whichever server is attached when the cover is asked
        // for, which is the point of resolving lazily rather than at attach time.
        let backends = self.backends
        self.artworkStore = ArtworkStore(
            directory: ArtworkStore.defaultDirectory(),
            byteLimit: MozzSession.artworkByteLimit,
            fetch: { query in await MozzSession.fetchArtwork(query, backends: backends) }
        )
        // Resolve per server, at play time. Capturing the table rather than a
        // backend is the same reasoning as artwork: which server a track comes
        // from is known when it is asked for, not when the session opens.
        self.playback = PlaybackCommandService(
            resolverFor: { serverId in
                guard let backend = backends.backend(serverId) else { return nil }
                return StreamingTrackURLResolver(backend: backend)
            }
        )
    }

    /// The disk budget for cached covers, matching iOS's 256 MB so all three
    /// platforms keep about the same amount and behave alike under pressure.
    static let artworkByteLimit = 256 * 1024 * 1024

    /// Resolve a reference to a URL through the attached backend and download it,
    /// mapping every outcome onto the absent/unavailable distinction the store
    /// remembers differently. This is the same resolution the `artworkURL` JSON
    /// handler does — `backend.artworkURL(for:size:)` — with the fetch added.
    ///
    ///  - no backend yet (still attaching) → unavailable; asking again later is
    ///    right, and remembering it as absent is the bug the desktop's
    ///    ArtworkUnavailableException exists to prevent.
    ///  - backend resolves the reference to nothing → absent; the server has no
    ///    such cover.
    ///  - HTTP 404 → absent; a non-404 error status or a thrown network error →
    ///    unavailable; an empty body → absent; otherwise the bytes.
    static func fetchArtwork(
        _ query: ArtworkQuery, backends: BackendTable
    ) async -> ArtworkOutcome {
        guard let backend = backends.backend(query.serverId) else { return .unavailable }
        guard let url = backend.artworkURL(
            for: ArtworkRef(key: query.artworkKey), size: query.size) else {
            return .absent
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 404 { return .absent }
                guard (200..<300).contains(http.statusCode) else { return .unavailable }
            }
            return data.isEmpty ? .absent : .bytes(data)
        } catch {
            return .unavailable
        }
    }
}

/// What a command handler is allowed to touch. Response encoding lives here so
/// the two dispatch files cannot disagree about the envelope.
protocol SessionContext: AnyObject {
    var database: MusicDatabase { get }
    var repository: LibraryRepository { get }
    var recommendations: RecommendationService { get }
    var lyrics: LyricsService { get }
    var favorites: FavoritesStore { get }
    var backends: BackendTable { get }
}

extension MozzSession: SessionContext {}

extension SessionContext {
    func success<P: Encodable>(_ request: SessionRequest, _ payload: P) -> String {
        sessionSuccess(request, payload)
    }

    func failure(_ request: SessionRequest, _ message: String) -> String {
        sessionFailure(request.id, request.cmd, message)
    }
}

/// Handles are integers rather than pointers: a C# `IntPtr` round-tripping a
/// Swift object pointer is easy to get subtly wrong, and an integer that indexes
/// a guarded table turns a use-after-free into a clean "unknown handle" error
/// instead of a crash.
final class SessionRegistry: @unchecked Sendable {
    static let shared = SessionRegistry()
    private let lock = NSLock()
    private var sessions: [Int64: MozzSession] = [:]
    private var nextHandle: Int64 = 1

    func open(path: String) throws -> Int64 {
        let session = try MozzSession(path: path)
        lock.lock(); defer { lock.unlock() }
        let handle = nextHandle
        nextHandle += 1
        sessions[handle] = session
        return handle
    }

    func session(_ handle: Int64) -> MozzSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions[handle]
    }

    func close(_ handle: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions.removeValue(forKey: handle) != nil
    }
}

// MARK: - Entry points

/// Open a library. Returns a positive handle, or 0 on failure.
@_cdecl("mozz_session_open")
public func mozz_session_open(_ dbPath: UnsafePointer<CChar>?) -> Int64 {
    guard let path = dbPath.map({ String(cString: $0) }), !path.isEmpty else { return 0 }
    return (try? SessionRegistry.shared.open(path: path)) ?? 0
}

/// Close a library. Returns 1 if the handle was live, 0 otherwise.
@_cdecl("mozz_session_close")
public func mozz_session_close(_ handle: Int64) -> Int32 {
    SessionRegistry.shared.close(handle) ? 1 : 0
}

/// Execute one command. The returned string is caller-owned; release it with
/// `mozz_ffi_free_string`.
@_cdecl("mozz_session_call")
public func mozz_session_call(
    _ handle: Int64,
    _ requestJSON: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let json = requestJSON.map({ String(cString: $0) }) else {
        return copySessionString(sessionFailure(nil, "", "no request"))
    }
    guard let request = try? JSONDecoder().decode(SessionRequest.self, from: Data(json.utf8)) else {
        return copySessionString(sessionFailure(nil, "", "malformed request"))
    }
    guard let session = SessionRegistry.shared.session(handle) else {
        return copySessionString(sessionFailure(request.id, request.cmd, "unknown session handle"))
    }

    // The dispatch layer deals only in `String`; the single C allocation happens
    // here, at the ABI edge. That also keeps the value crossing `runBlockingSession`
    // Sendable — an `UnsafeMutablePointer` is not, and hoisting it through the
    // task boundary is an error under the Swift 6 language mode.
    do {
        return copySessionString(try runBlockingSession { try await dispatch(request, session) })
    } catch {
        return copySessionString(sessionFailure(request.id, request.cmd, String(describing: error)))
    }
}

/// A malformed cursor is treated as "from the start" rather than an error: it
/// can only come from a client that mangled a token we gave it, and restarting
/// the listing is a better answer than refusing to show anything.
private func pageCursor(_ request: SessionRequest) -> LibraryRepository.PageCursor? {
    (request.after ?? request.cursor).flatMap(LibraryRepository.PageCursor.init(token:))
}

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func queueDescriptor(_ wire: WireQueueDescriptor) throws -> QueueDescriptor {
    guard let kind = QueueDescriptor.Kind(rawValue: wire.kind) else {
        throw MozzError.unsupported("unknown continuity descriptor kind: \(wire.kind)")
    }
    return QueueDescriptor(kind: kind, sourceID: wire.sourceID, sourceRevision: wire.sourceRevision)
}

private func continuityFingerprint(
    _ item: WireContinuityItemInput,
    fallback: ServerAccountFingerprint?
) throws -> ServerAccountFingerprint {
    let backendRaw = item.backend ?? fallback?.backend.rawValue
    guard let backendRaw, let backend = BackendKind(rawValue: backendRaw) else {
        throw MozzError.unsupported("continuity item needs backend")
    }
    return ServerAccountFingerprint(
        backend: backend,
        serverID: item.serverID ?? fallback?.serverID ?? "",
        accountID: item.accountID ?? fallback?.accountID ?? ""
    )
}

private func continuityQueue(
    _ input: WireContinuityQueueInput,
    fallbackFingerprint: ServerAccountFingerprint? = nil
) throws -> ContinuityQueue {
    let descriptor = try queueDescriptor(input.descriptor)
    let items = try input.items.map { item -> ContinuityItem in
        let fingerprint = try continuityFingerprint(item, fallback: fallbackFingerprint)
        return ContinuityItem(
            locator: TrackLocator(server: fingerprint, remoteID: item.remoteID),
            baseOrdinal: item.baseOrdinal,
            title: item.title,
            artist: item.artist,
            durationMS: item.durationMS,
            artwork: item.artworkKey.map(ArtworkRef.init(key:))
        )
    }
    guard let repeatMode = RepeatMode(rawValue: input.repeatMode) else {
        throw MozzError.unsupported("unknown continuity repeatMode: \(input.repeatMode)")
    }
    return ContinuityQueueBuilder.make(
        items: items,
        descriptor: descriptor,
        repeatMode: repeatMode,
        isShuffled: input.isShuffled,
        totalCount: input.totalCount,
        startAbsoluteIndex: input.startAbsoluteIndex ?? input.windowStartAbsoluteIndex ?? 0,
        isTruncated: input.isTruncated ?? false
    )
}

private func continuityQueueInput(_ request: SessionRequest) throws -> WireContinuityQueueInput {
    if let queue = request.queue { return queue }
    guard let descriptor = request.descriptor,
          let items = request.items,
          let repeatMode = request.repeatMode,
          let isShuffled = request.isShuffled,
          let totalCount = request.totalCount else {
        throw MozzError.unsupported("continuity queue needs descriptor, items, repeatMode, isShuffled and totalCount")
    }
    return WireContinuityQueueInput(
        descriptor: descriptor,
        items: items,
        repeatMode: repeatMode,
        isShuffled: isShuffled,
        totalCount: totalCount,
        startAbsoluteIndex: request.startAbsoluteIndex,
        windowStartAbsoluteIndex: request.windowStartAbsoluteIndex,
        isTruncated: nil
    )
}

// MARK: - Dispatch

private func dispatch(
    _ request: SessionRequest,
    _ session: MozzSession
) async throws -> String {
    let repo = session.repository
    let serverId = request.serverId
    // `offset` is gone from the big listings — they page by cursor now. It stays
    // on the request envelope only so an older client's message still decodes.
    // Capped so a malformed request cannot ask for the whole library in one
    // allocation; a UI pages, and 1,000 rows is already far more than a screen.
    let limit = min(max(1, request.limit ?? 100), 1_000)

    switch request.cmd {
    case "ping":
        return sessionSuccess(request, ["ok": true])

    case "servers":
        let servers = try await repo.servers().map {
            WireServer(id: $0.id, kind: $0.kind.rawValue, name: $0.name,
                       baseURL: $0.baseURL.absoluteString)
        }
        return sessionSuccess(request, servers)

    case "counts":
        let counts = WireCounts(
            artists: try await repo.artistCount(serverId: serverId),
            albums: try await repo.albumCount(serverId: serverId),
            tracks: try await repo.trackCount(serverId: serverId)
        )
        return sessionSuccess(request, counts)

    // The three big listings page by cursor, not offset. OFFSET is O(offset) and
    // is wrong whenever the table changes mid-walk, which is exactly what a
    // background sync does — see the note above the keyset methods in
    // LibraryRepository. An absent cursor means "from the start".
    case "artists":
        let page = try await repo.artistsPage(serverId: serverId, after: pageCursor(request), limit: limit)
        return sessionSuccess(request, page.rows.map(wire), nextCursor: page.next?.token)

    case "albums":
        let page = try await repo.albumsPage(serverId: serverId, after: pageCursor(request), limit: limit)
        return sessionSuccess(request, page.rows.map(wire), nextCursor: page.next?.token)

    case "tracks":
        let page = try await repo.tracksPage(serverId: serverId, after: pageCursor(request), limit: limit)
        return sessionSuccess(request, page.rows.map(wire), nextCursor: page.next?.token)

    case "artist":
        guard let remoteId = request.remoteId, let serverId else {
            return sessionFailure(request.id, request.cmd, "artist needs remoteId and serverId")
        }
        guard let artist = try await repo.artist(serverId: serverId, remoteId: remoteId) else {
            return sessionFailure(request.id, request.cmd, "artist not found: \(remoteId)")
        }
        let albums = try await repo.albums(forArtistRemoteId: remoteId, serverId: serverId)
        let heroArtworkKey = ArtistDetailPresentation.heroArtworkKey(artist: artist, albums: albums)
        return sessionSuccess(request, wireHeader(artist, heroArtworkKey: heroArtworkKey))

    case "album":
        guard let remoteId = request.remoteId, let serverId else {
            return sessionFailure(request.id, request.cmd, "album needs remoteId and serverId")
        }
        guard let album = try await repo.album(serverId: serverId, remoteId: remoteId) else {
            return sessionFailure(request.id, request.cmd, "album not found: \(remoteId)")
        }
        return sessionSuccess(request, wireHeader(album))

    case "artistAlbums":
        guard let remoteId = request.remoteId, let serverId else {
            return sessionFailure(request.id, request.cmd, "artistAlbums needs remoteId and serverId")
        }
        let rows = try await repo.albums(forArtistRemoteId: remoteId, serverId: serverId)
        return sessionSuccess(request, rows.map(wire))

    case "artistTopTracks":
        guard let artistRemoteId = request.artistRemoteId, let serverId else {
            return sessionFailure(request.id, request.cmd, "artistTopTracks needs artistRemoteId and serverId")
        }
        let rows = try await repo.topTracks(forArtistRemoteId: artistRemoteId, serverId: serverId, limit: limit)
        return sessionSuccess(request, rows.map(wire))

    case "artistAppearsOn":
        guard let artistRemoteId = request.artistRemoteId, let serverId else {
            return sessionFailure(request.id, request.cmd, "artistAppearsOn needs artistRemoteId and serverId")
        }
        let page = try await repo.appearsOnAlbums(
            forArtistRemoteId: artistRemoteId,
            serverId: serverId,
            after: pageCursor(request),
            limit: limit
        )
        return sessionSuccess(
            request,
            WireAlbumPage(items: page.rows.map(wireHeader), nextCursor: page.next?.token)
        )

    case "albumTracks":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "albumTracks needs serverId")
        }
        // Prefer the group key: servers (Jellyfin especially) split one album
        // into several entities, and asking by remote id alone returns a slice.
        if let groupKey = request.groupKey {
            let rows = try await repo.tracks(forAlbumGroupKey: groupKey, serverId: serverId)
            return sessionSuccess(request, rows.map(wire))
        }
        guard let remoteId = request.remoteId else {
            return sessionFailure(request.id, request.cmd, "albumTracks needs remoteId or groupKey")
        }
        let rows = try await repo.tracks(forAlbumGroupContaining: remoteId, serverId: serverId)
        return sessionSuccess(request, rows.map(wire))

    case "playlists":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "playlists needs serverId")
        }
        let rows = try await repo.allPlaylists(serverId: serverId)
        return sessionSuccess(request, rows.map(wire))

    case "playlistTracks":
        guard let remoteId = request.remoteId, let serverId else {
            return sessionFailure(request.id, request.cmd, "playlistTracks needs remoteId and serverId")
        }
        let rows = try await repo.tracks(forPlaylistRemoteId: remoteId, serverId: serverId)
        return sessionSuccess(request, rows.map(wire))

    case "albumReleaseKind":
        let kind = AlbumReleaseClassifier.kind(trackCount: request.trackCount)
        return sessionSuccess(
            request,
            WireAlbumReleaseKind(kind: kind.rawValue, isSingleOrEP: kind.isSingleOrEP)
        )

    case "recentlyAddedAlbums":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "recentlyAddedAlbums needs serverId")
        }
        let rows = try await repo.recentlyAddedAlbums(serverId: serverId, limit: limit)
        return sessionSuccess(request, rows.map(wire))

    case "recentlyAddedTracks":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "recentlyAddedTracks needs serverId")
        }
        let rows = try await repo.recentlyAddedTracks(serverId: serverId, limit: limit)
        return sessionSuccess(request, rows.map(wire))

    case "recentlyPlayedTracks":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "recentlyPlayedTracks needs serverId")
        }
        let rows = try await repo.recentlyPlayedTracks(serverId: serverId, limit: limit)
        return sessionSuccess(request, rows.map(wire))

    case "recordPlayEvent":
        guard let serverId, let remoteId = request.remoteId else {
            return sessionFailure(request.id, request.cmd, "recordPlayEvent needs serverId and remoteId")
        }
        let kindRaw = request.eventKind ?? request.kind
        guard let kindRaw, let eventKind = PlayEventKind(rawValue: kindRaw) else {
            return sessionFailure(request.id, request.cmd, "recordPlayEvent needs kind")
        }
        guard let deviceID = request.deviceID ?? request.deviceId, !deviceID.isEmpty else {
            return sessionFailure(request.id, request.cmd, "recordPlayEvent needs deviceID")
        }
        let createdAt = request.createdAtMS
            .map { Date(timeIntervalSince1970: Double($0) / 1000) }
            ?? Date()
        let positionSeconds = request.positionSeconds
            ?? request.positionMS.map { Double($0) / 1000 }
        let durationSeconds = request.durationSeconds
            ?? request.durationMS.map { Double($0) / 1000 }
        let recorded = try await HistoryExchangeStore(session.database).recordLocalPlayEvent(
            PlayEvent(
                trackID: remoteId,
                kind: eventKind,
                positionSeconds: positionSeconds,
                durationSeconds: durationSeconds,
                context: request.context,
                contextID: request.contextID ?? request.contextId,
                createdAt: createdAt
            ),
            serverId: serverId,
            deviceID: deviceID
        )
        return sessionSuccess(request, recorded)

    case "playHistory":
        let page = try await HistoryExchangeStore(session.database).recentEventsPage(
            serverId: serverId,
            after: (request.after ?? request.cursor).flatMap(HistoryEventPageCursor.init(token:)),
            limit: limit
        )
        return sessionSuccess(request, page.rows, nextCursor: page.next?.token)

    case "historyExportBatch":
        guard let deviceID = request.deviceID ?? request.deviceId, !deviceID.isEmpty else {
            return sessionFailure(request.id, request.cmd, "historyExportBatch needs deviceID")
        }
        let batch = try await HistoryExchangeStore(session.database).exportBatch(
            localDeviceID: deviceID,
            deviceName: request.deviceName ?? "",
            sinceMS: request.sinceMS,
            windowDays: request.windowDays ?? 180,
            maximumBytes: min(max(1, request.maxBytes ?? HistoryExchangeStore.defaultMaximumBatchBytes), 1_048_576)
        )
        return sessionSuccess(request, batch)

    case "historyImportBatches":
        guard let deviceID = request.deviceID ?? request.deviceId, !deviceID.isEmpty else {
            return sessionFailure(request.id, request.cmd, "historyImportBatches needs deviceID")
        }
        let batches = request.batches ?? request.batch.map { [$0] }
        guard let batches else {
            return sessionFailure(request.id, request.cmd, "historyImportBatches needs batches")
        }
        let imported = try await HistoryExchangeStore(session.database).importBatches(
            batches,
            localDeviceID: deviceID
        )
        return sessionSuccess(request, WireHistoryImport(imported: imported))

    case "historyYearRollup":
        guard let deviceID = request.deviceID ?? request.deviceId, !deviceID.isEmpty else {
            return sessionFailure(request.id, request.cmd, "historyYearRollup needs deviceID")
        }
        let calendar = HistoryRollupBuilder.utcCalendar
        let year = request.year ?? calendar.component(.year, from: Date())
        let rollup = try await HistoryExchangeStore(session.database).yearRollup(
            year: year,
            localDeviceID: deviceID
        )
        return sessionSuccess(request, rollup)

    case "likedTracks":
        let rows = try await repo.likedTracks(serverId: serverId, limit: limit)
        return sessionSuccess(request, rows.map(wire))

    case "likedTracksCount":
        let count = try await repo.likedTracksCount(serverId: serverId)
        return sessionSuccess(request, ["count": count])

    case "setFavorite":
        guard let serverId, let remoteId = request.remoteId else {
            return sessionFailure(request.id, request.cmd, "setFavorite needs serverId and remoteId")
        }
        guard let liked = request.liked ?? request.isFavorite else {
            return sessionFailure(request.id, request.cmd, "setFavorite needs liked")
        }
        return try await applyFavoriteMutation(
            request,
            session: session,
            serverId: serverId,
            remoteId: remoteId,
            value: .favorite(liked),
            flush: request.flush ?? true
        )

    case "setRating":
        guard let serverId, let remoteId = request.remoteId else {
            return sessionFailure(request.id, request.cmd, "setRating needs serverId and remoteId")
        }
        return try await applyFavoriteMutation(
            request,
            session: session,
            serverId: serverId,
            remoteId: remoteId,
            value: .rating(request.rating),
            flush: request.flush ?? true
        )

    case "flushFavoriteOutbox":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "flushFavoriteOutbox needs serverId")
        }
        let flushed = try await flushFavoriteOutbox(session: session, serverId: serverId)
        return sessionSuccess(request, ["flushed": flushed])

    case "genres":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "genres needs serverId")
        }
        return sessionSuccess(request, try await repo.genres(serverId: serverId))

    case "genreAlbums":
        guard let genre = request.genre, let serverId else {
            return sessionFailure(request.id, request.cmd, "genreAlbums needs genre and serverId")
        }
        let rows = try await repo.albums(forGenre: genre, serverId: serverId)
        return sessionSuccess(request, rows.map(wire))

    case "search":
        guard let query = request.query else {
            return sessionFailure(request.id, request.cmd, "search needs query")
        }
        let results = try await repo.search(query, serverId: serverId, limitPerType: limit)
        return sessionSuccess(request, WireSearchResults(
            artists: results.artists.map(wire),
            albums: results.albums.map(wire),
            tracks: results.tracks.map(wire)
        ))

    case "homeMixes":
        let mixes = try await session.recommendations.homeMixes().map(wire)
        return sessionSuccess(request, mixes)

    case "generateHomeMixes":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "generateHomeMixes needs serverId")
        }
        try await session.recommendations.generateHomeMixes(serverId: serverId, seed: request.seed)
        return sessionSuccess(request, WireAction(ok: true))

    case "mix":
        guard let setId = request.setId else {
            return sessionFailure(request.id, request.cmd, "mix needs setId")
        }
        guard let set = try await session.recommendations.set(id: setId) else {
            return sessionFailure(request.id, request.cmd, "mix not found: \(setId)")
        }
        return sessionSuccess(request, wire(set))

    case "mixTracks":
        guard let setId = request.setId else {
            return sessionFailure(request.id, request.cmd, "mixTracks needs setId")
        }
        let rows = try await session.recommendations.tracks(forSetId: setId)
        return sessionSuccess(request, rows.map(wire))

    case "generateMozzWeekly":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "generateMozzWeekly needs serverId")
        }
        let set = try await session.recommendations.generateMozzWeekly(serverId: serverId, limit: limit, seed: request.seed)
        return sessionSuccess(request, wire(set))

    case "mozzWeeklyTracks":
        let rows = try await session.recommendations.mozzWeeklyTracks()
        return sessionSuccess(request, rows.map(wire))

    case "mozzWeeklyItems":
        let rows = try await session.recommendations.mozzWeeklyItems()
        return sessionSuccess(request, rows.map(wire))

    case "radioBatch":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "radioBatch needs serverId")
        }
        let seed = RadioSeed(title: request.seedTitle ?? "Radio",
                             genres: request.seedGenres ?? [],
                             artistIds: request.seedArtistIds ?? [],
                             seedTrackRef: request.seedTrackRef)
        let remoteIds = try await session.recommendations.radioBatch(
            seed: seed, serverId: serverId, limit: limit, excluding: Set(request.excluding ?? []))
        var tracks: [WireTrack] = []
        tracks.reserveCapacity(remoteIds.count)
        for remoteId in remoteIds {
            if let track = try await repo.track(serverId: serverId, remoteId: remoteId) {
                tracks.append(wire(track))
            }
        }
        return sessionSuccess(request, WireRadioBatch(remoteIds: remoteIds, tracks: tracks))

    case "lyrics":
        guard let serverId, let remoteId = request.remoteId else {
            return sessionFailure(request.id, request.cmd, "lyrics needs serverId and remoteId")
        }
        guard let record = try await repo.track(serverId: serverId, remoteId: remoteId) else {
            return sessionFailure(request.id, request.cmd, "lyrics track not found: \(remoteId)")
        }
        let backend = session.backends.backend(serverId)
        let resolution = await session.lyrics.resolve(
            track: record.toDomain(),
            backend: backend,
            context: .visible,
            useLRCLIB: request.useLRCLIB ?? true,
            userInitiated: request.userInitiated ?? false
        )
        let lyrics = resolution.lyrics.flatMap { $0.isEmpty ? nil : $0 }
        let activeIndex: Int?
        if let lyrics, let positionSeconds = request.positionSeconds {
            activeIndex = lyrics.activeLineIndex(
                at: positionSeconds,
                lead: request.leadSeconds ?? 0
            )
        } else {
            activeIndex = nil
        }
        return sessionSuccess(request, WireLyricsResolution(
            status: lyrics != nil ? "loaded" : (resolution.staySilent ? "silent" : "unavailable"),
            staySilent: resolution.staySilent,
            activeLineIndex: activeIndex,
            lyrics: lyrics.map(wire)
        ))

    case "reportPlayback":
        guard let serverId, let remoteId = request.remoteId else {
            return sessionFailure(request.id, request.cmd, "reportPlayback needs serverId and remoteId")
        }
        guard let stateRaw = request.state, let state = PlaybackState(rawValue: stateRaw) else {
            return sessionFailure(request.id, request.cmd, "reportPlayback needs state (playing|paused|stopped)")
        }
        guard let backend = session.backends.backend(serverId) else {
            return sessionFailure(request.id, request.cmd, "reportPlayback needs an attached serverId")
        }
        guard let record = try await repo.track(serverId: serverId, remoteId: remoteId) else {
            return sessionFailure(request.id, request.cmd, "reportPlayback track not found: \(remoteId)")
        }
        try await backend.reportPlayback(PlaybackReport(
            track: record.toDomain(),
            state: state,
            positionSeconds: request.positionSeconds ?? request.positionMS.map { Double($0) / 1000 } ?? 0,
            sessionID: request.contextID ?? request.contextId
        ))
        return sessionSuccess(request, WirePlaybackReportResult(reported: true))

    case "continuityQueueHash":
        do {
            let input = try continuityQueueInput(request)
            let queue = try continuityQueue(input)
            let bytes = ContinuityQueueBuilder.canonicalBytes(
                items: queue.items,
                descriptor: queue.descriptor,
                repeatMode: queue.repeatMode,
                isShuffled: queue.isShuffled,
                totalCount: queue.totalCount,
                startAbsoluteIndex: queue.startAbsoluteIndex
            )
            return sessionSuccess(request, WireContinuityHash(
                queueHash: queue.queueHash,
                canonicalByteCount: bytes.count,
                canonicalBytesHex: hex(bytes)
            ))
        } catch {
            return sessionFailure(request.id, request.cmd, String(describing: error))
        }

    case "continuityLoad":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "continuityLoad needs serverId")
        }
        guard let store = try await continuityStore(request, session: session, serverId: serverId) else {
            return sessionFailure(request.id, request.cmd, "continuityLoad needs an attached Jellyfin or Subsonic serverId")
        }
        guard let snapshot = try await store.load() else {
            return sessionSuccess(request, Optional<WireContinuitySnapshot>.none)
        }
        var hydrated: [TrackRecord] = []
        for remoteID in snapshot.hydrated.keys.sorted() {
            if let record = try await repo.track(serverId: serverId, remoteId: remoteID) {
                hydrated.append(record)
            }
        }
        return sessionSuccess(request, wire(snapshot, hydrated: hydrated))

    case "continuitySave":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "continuitySave needs serverId")
        }
        guard let store = try await continuityStore(request, session: session, serverId: serverId),
              let fingerprint = try await continuityFingerprint(session: session, serverId: serverId) else {
            return sessionFailure(request.id, request.cmd, "continuitySave needs an attached Jellyfin or Subsonic serverId")
        }
        guard let playbackRunID = request.playbackRunID.flatMap(UUID.init(uuidString:)) else {
            return sessionFailure(request.id, request.cmd, "continuitySave needs playbackRunID")
        }
        guard let deviceID = request.deviceID ?? request.deviceId, !deviceID.isEmpty else {
            return sessionFailure(request.id, request.cmd, "continuitySave needs deviceID")
        }
        guard let stateRaw = request.state, let state = ContinuityPlaybackState(rawValue: stateRaw) else {
            return sessionFailure(request.id, request.cmd, "continuitySave needs state (playing|paused|stopped)")
        }
        guard let currentRemoteID = request.currentRemoteID ?? request.remoteId,
              let currentAbsoluteIndex = request.currentAbsoluteIndex,
              let positionMS = request.positionMS else {
            return sessionFailure(request.id, request.cmd, "continuitySave needs currentRemoteID, currentAbsoluteIndex and positionMS")
        }
        let queue = try request.queue.map { try continuityQueue($0, fallbackFingerprint: fingerprint) }
        let cursor = ContinuityCursor(
            playbackRunID: playbackRunID,
            deviceID: deviceID,
            deviceName: request.deviceName ?? "",
            deviceKind: request.kind.flatMap(ContinuityDeviceKind.init(rawValue:)),
            cursorSequence: request.cursorSequence ?? 0,
            capturedAtMS: request.capturedAtMS ?? Int64(Date().timeIntervalSince1970 * 1000),
            state: state,
            current: TrackLocator(server: fingerprint, remoteID: currentRemoteID),
            currentAbsoluteIndex: currentAbsoluteIndex,
            positionMS: positionMS,
            queueHash: (store.features.storesQueue ? queue?.queueHash : nil)
        )
        try await store.save(cursor, queue: queue)
        return sessionSuccess(request, WireContinuitySave(saved: true, queueHash: queue?.queueHash))

    case "suppressTrack":
        guard let remoteId = request.remoteId, let serverId else {
            return sessionFailure(request.id, request.cmd, "suppressTrack needs remoteId and serverId")
        }
        try await session.recommendations.suppressTrack(remoteId: remoteId, serverId: serverId)
        return sessionSuccess(request, WireAction(ok: true))

    case "suppressArtist":
        guard let remoteId = request.remoteId, let serverId else {
            return sessionFailure(request.id, request.cmd, "suppressArtist needs remoteId and serverId")
        }
        try await session.recommendations.suppressArtist(remoteId: remoteId, serverId: serverId)
        return sessionSuccess(request, WireAction(ok: true))

    case "unsuppressTrack":
        guard let remoteId = request.remoteId, let serverId else {
            return sessionFailure(request.id, request.cmd, "unsuppressTrack needs remoteId and serverId")
        }
        try await session.recommendations.unsuppressTrack(remoteId: remoteId, serverId: serverId)
        return sessionSuccess(request, WireAction(ok: true))

    case "unsuppressArtist":
        guard let remoteId = request.remoteId, let serverId else {
            return sessionFailure(request.id, request.cmd, "unsuppressArtist needs remoteId and serverId")
        }
        try await session.recommendations.unsuppressArtist(remoteId: remoteId, serverId: serverId)
        return sessionSuccess(request, WireAction(ok: true))

    case "suppressions":
        guard let serverId else {
            return sessionFailure(request.id, request.cmd, "suppressions needs serverId")
        }
        let rows = try await session.recommendations.suppressions(serverId: serverId)
            .map { WireSuppression(scope: $0.scope, ref: $0.ref, createdAt: $0.createdAt) }
        return sessionSuccess(request, rows)

    default:
        // Not a catalog command — try the server/sync/streaming table before
        // declaring it unknown, so both halves share one envelope and one error.
        if let response = try await dispatchServerCommand(request, session) { return response }
        return sessionFailure(request.id, request.cmd, unknownCommandMessage(request.cmd))
    }
}

private func applyFavoriteMutation(
    _ request: SessionRequest,
    session: MozzSession,
    serverId: String,
    remoteId: String,
    value: FavoriteChange.Value,
    flush: Bool
) async throws -> String {
    let itemType = request.itemType.flatMap(CatalogItemType.init(rawValue:)) ?? .track
    guard itemType == .track else {
        return sessionFailure(request.id, request.cmd, "only track favorites are supported over the ABI")
    }
    guard let track = try await session.repository.track(serverId: serverId, remoteId: remoteId) else {
        return sessionFailure(request.id, request.cmd, "\(request.cmd) track not found: \(remoteId)")
    }
    let wasLiked = LikePolicy.isLiked(isFavorite: track.isFavorite, rating: track.rating)
    let change = FavoriteChange(serverId: serverId, remoteId: remoteId, itemType: itemType, value: value)
    let nowLiked = try await session.favorites.applyLocally(change)
    if nowLiked != wasLiked {
        try? await PlayEventStore(session.database).append(
            PlayEvent(trackID: remoteId, kind: nowLiked ? .liked : .unliked),
            serverId: serverId
        )
    }
    if flush {
        _ = try? await flushFavoriteOutbox(session: session, serverId: serverId)
    }
    let queued = try await session.favorites.pending(serverId: serverId).contains {
        $0.remoteId == remoteId && $0.itemType == itemType.rawValue
    }
    let kind: String
    let storedValue: Double?
    switch value {
    case .favorite(let favorite):
        kind = "favorite"
        storedValue = favorite ? 1 : 0
    case .rating(let rating):
        kind = "rating"
        storedValue = rating
    }
    return sessionSuccess(request, WireFavoriteMutation(
        serverId: serverId,
        remoteId: remoteId,
        itemType: itemType.rawValue,
        kind: kind,
        value: storedValue,
        liked: nowLiked,
        queued: queued,
        synced: !queued
    ))
}

private func flushFavoriteOutbox(session: MozzSession, serverId: String) async throws -> Int {
    guard let backend = session.backends.backend(serverId) else { return 0 }
    let pending = try await session.favorites.pending(serverId: serverId)
    var flushed = 0
    for op in pending {
        let type = CatalogItemType(rawValue: op.itemType) ?? .track
        do {
            if op.kind == "favorite" {
                try await backend.setFavorite((op.value ?? 0) >= 0.5, itemID: op.remoteId, type: type)
            } else {
                try await backend.setRating(op.value, itemID: op.remoteId, type: type)
            }
        } catch {
            break
        }
        if let id = op.id,
           try await session.favorites.removePending(id: id, ifUnchangedSince: op.createdAt) {
            flushed += 1
        }
    }
    return flushed
}

private func continuityFingerprint(
    session: MozzSession,
    serverId: String
) async throws -> ServerAccountFingerprint? {
    guard let backend = session.backends.backend(serverId) else { return nil }
    switch backend.connection.kind {
    case .jellyfin:
        let cached = try await session.repository.capabilities(serverId: serverId)
        let detected = try? await backend.detectCapabilities().serverIdentity
        let serverIdentity = cached?.serverIdentity ?? detected ?? ""
        return ServerAccountFingerprint(
            backend: .jellyfin,
            serverID: serverIdentity,
            accountID: backend.connection.userID ?? ""
        )
    case .subsonic:
        return ServerAccountFingerprint(
            backend: .subsonic,
            serverID: "",
            accountID: backend.connection.userID ?? ""
        )
    case .plex:
        return nil
    }
}

private func continuityStore(
    _ request: SessionRequest,
    session: MozzSession,
    serverId: String
) async throws -> (any ContinuityStore)? {
    guard let backend = session.backends.backend(serverId) else { return nil }
    if let jellyfin = backend as? JellyfinBackend {
        let cached = try await session.repository.capabilities(serverId: serverId)
        let detected = try? await backend.detectCapabilities().serverIdentity
        let serverIdentity = cached?.serverIdentity ?? detected
        return jellyfin.makeContinuityStore(serverIdentity: serverIdentity)
    }
    if let subsonic = backend as? SubsonicBackend {
        let cached = try await session.repository.capabilities(serverId: serverId)
        let supportsIndex = cached?.supportsIndexBasedQueue ?? false
        return subsonic.makeContinuityStore(supportsIndexBasedQueue: supportsIndex)
    }
    return nil
}

/// Every command the dispatcher accepts.
///
/// Kept beside the error rather than derived from the switch, because Swift
/// cannot enumerate a switch — so the honest thing is to admit the list is
/// hand-maintained and make the failure it protects against loud.
let mozzSessionCommands = [
    "ping", "servers", "counts", "artists", "albums", "tracks",
    "artist", "album", "artistAlbums", "artistTopTracks", "artistAppearsOn",
    "albumTracks", "albumReleaseKind", "playlists", "playlistTracks",
    "recentlyAddedAlbums", "recentlyAddedTracks", "recentlyPlayedTracks",
    "likedTracks", "likedTracksCount",
    "setFavorite", "setRating", "flushFavoriteOutbox",
    "recordPlayEvent", "playHistory", "historyExportBatch",
    "historyImportBatches", "historyYearRollup",
    "genres", "genreAlbums", "search", "homeMixes", "generateHomeMixes",
    "mix", "mixTracks", "generateMozzWeekly", "mozzWeeklyTracks",
    "mozzWeeklyItems", "radioBatch", "lyrics", "reportPlayback",
    "continuityQueueHash", "continuityLoad", "continuitySave",
    "suppressTrack", "suppressArtist",
    "unsuppressTrack", "unsuppressArtist", "suppressions",
    "connect", "plexPin", "plexPinCheck", "attach", "libraries", "account",
    "sync", "syncStatus", "streamURL", "artworkURL",
].sorted()

/// A wrong command name is one of the few mistakes that can only be made across
/// the FFI boundary, and it is invisible: a client written in another language
/// gets "unknown command" and no indication that it is one capital letter away
/// from working. `streamUrl` for `streamURL` cost real time, so the error now
/// names the near miss.
func unknownCommandMessage(_ cmd: String) -> String {
    let lowered = cmd.lowercased()
    if let match = mozzSessionCommands.first(where: { $0.lowercased() == lowered }) {
        return "unknown command '\(cmd)' — did you mean '\(match)'? (case matters)"
    }
    let prefixed = mozzSessionCommands.filter {
        $0.lowercased().hasPrefix(lowered.prefix(4)) || lowered.hasPrefix($0.lowercased().prefix(4))
    }
    if !prefixed.isEmpty {
        return "unknown command '\(cmd)' — did you mean \(prefixed.map { "'\($0)'" }.joined(separator: " or "))?"
    }
    return "unknown command '\(cmd)' — known commands: \(mozzSessionCommands.joined(separator: ", "))"
}

// MARK: - Response helpers

func sessionSuccess<P: Encodable>(
    _ request: SessionRequest,
    _ payload: P,
    nextCursor: String? = nil
) -> String {
    encodeSession(SessionResponse(id: request.id, ok: true, cmd: request.cmd,
                                  payload: payload, error: nil, nextCursor: nextCursor))
}

func sessionFailure(
    _ id: Int?,
    _ cmd: String,
    _ message: String
) -> String {
    encodeSession(SessionResponse<String>(id: id, ok: false, cmd: cmd,
                                          payload: nil, error: message, nextCursor: nil))
}

private func encodeSession<P: Encodable>(_ response: SessionResponse<P>) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(response),
          let json = String(data: data, encoding: .utf8) else {
        return #"{"ok":false,"error":"failed to encode response"}"#
    }
    return json
}

private func copySessionString(_ string: String) -> UnsafeMutablePointer<CChar>? {
    let bytes = Array(string.utf8CString)
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
    buffer.update(from: bytes, count: bytes.count)
    return buffer
}

// MARK: - async bridge

final class SessionResultBox<T>: @unchecked Sendable {
    var result: Result<T, any Error>?
}

/// Bridges async to the synchronous C ABI.
///
/// Still a parked thread, and still not something a UI thread should call
/// directly — clients must dispatch these off their main thread. A callback or
/// polled-completion API is the eventual answer, but every call here is a
/// database read measured in single-digit milliseconds, so the simpler shape
/// buys correctness now and can change without the request format moving.
/// Not file-private: `mozz_session_invoke` in MozzSessionInvoke.swift bridges the
/// same way, and a second copy of a semaphore-and-detached-task dance is exactly
/// the kind of duplication that drifts.
func runBlockingSession<T: Sendable>(
    _ body: @escaping @Sendable () async throws -> T
) throws -> T {
    let box = SessionResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await body()) }
        catch { box.result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    switch box.result {
    case .success(let value): return value
    case .failure(let error): throw error
    case nil: throw MozzError.invalidResponse
    }
}
