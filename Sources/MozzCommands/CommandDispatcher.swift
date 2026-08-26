import Foundation
import MozzCore
import MozzDatabase
import MozzSchema
import SwiftProtobuf

/// Adapts the wire format in `schema/` onto `CommandService`.
///
/// Non-Swift shells hand this a serialised `Request` and get back a serialised
/// `Response`. It performs no logic of its own: decode, call the one surface,
/// encode. Anything resembling a decision here would be a decision the Swift
/// shells do not get, which is the divergence this whole arrangement exists to
/// prevent.
public struct CommandDispatcher: Sendable {
    private let service: any CommandService

    public init(service: any CommandService) {
        self.service = service
    }

    /// Decode a request, run it, encode the response.
    ///
    /// Never throws. A failure that reaches a shell as a thrown error across a C
    /// ABI is a crash; as a `Failure` variant of the result it is something the
    /// caller is obliged to handle, because the generated `oneof` makes it a
    /// case rather than an afterthought.
    public func handle(_ requestBytes: Data) async -> Data {
        let request: Mozz_V1_Request
        do {
            request = try Mozz_V1_Request(serializedBytes: requestBytes)
        } catch {
            // A request we cannot even parse has no id to echo, so the failure
            // is reported against id 0 rather than invented.
            return Self.encode(Self.failure(id: 0, "malformed request: \(error)"))
        }

        do {
            return Self.encode(try await run(request))
        } catch {
            return Self.encode(Self.failure(id: request.id, String(describing: error)))
        }
    }

    /// An encoded failure for a request that could not even be understood.
    ///
    /// Static because the caller may not have a dispatcher — a bad handle or an
    /// empty buffer is refused before one is built. Reports against id 0, since
    /// a request that did not parse has no id to echo and inventing one would be
    /// worse than admitting there is none.
    public static func malformed(_ message: String) -> Data {
        var failure = Mozz_V1_Failure()
        failure.message = message
        var response = Mozz_V1_Response()
        response.id = 0
        response.failure = failure
        return (try? response.serializedData()) ?? Data()
    }

    // MARK: Dispatch

    /// The exhaustive switch. This is the load-bearing part of the whole design.
    ///
    /// There is no `default`, and there must never be one. Adding a command to
    /// `library.proto` and regenerating adds a case to `OneOf_Command`, and this
    /// function then refuses to compile until the command is handled — which
    /// forces a method on `CommandService`, which forces the core to implement
    /// it. A `default` here would restore the exact failure mode this replaced:
    /// a capability that exists, that one platform can reach and the others
    /// silently cannot.
    private func run(_ request: Mozz_V1_Request) async throws -> Mozz_V1_Response {
        switch request.command {

        case .libraries:
            let servers = try await service.libraries()
            var payload = Mozz_V1_LibrariesResponse()
            payload.libraries = servers.map(Self.wire)
            return Self.response(id: request.id) { $0.libraries = payload }

        case .albums(let arguments):
            guard let cursor = Self.pageCursor(arguments.after, present: arguments.hasAfter) else {
                return Self.failure(id: request.id, "unreadable page cursor")
            }

            let page = try await service.albums(
                serverId: ServerID(arguments.serverID),
                after: cursor,
                limit: Int(arguments.limit)
            )

            var payload = Mozz_V1_AlbumsResponse()
            payload.albums = page.rows.map(Self.wire)
            payload.page = Self.pageInfo(page.next)
            return Self.response(id: request.id) { $0.albums = payload }

        case .artists(let arguments):
            guard let cursor = Self.pageCursor(arguments.after, present: arguments.hasAfter) else {
                return Self.failure(id: request.id, "unreadable page cursor")
            }

            let page = try await service.artists(
                serverId: ServerID(arguments.serverID),
                after: cursor,
                limit: Int(arguments.limit)
            )

            var payload = Mozz_V1_ArtistsResponse()
            payload.artists = page.rows.map { Self.wire($0) }
            payload.page = Self.pageInfo(page.next)
            return Self.response(id: request.id) { $0.artists = payload }

        case .tracks(let arguments):
            guard let cursor = Self.pageCursor(arguments.after, present: arguments.hasAfter) else {
                return Self.failure(id: request.id, "unreadable page cursor")
            }

            let page = try await service.tracks(
                serverId: ServerID(arguments.serverID),
                after: cursor,
                limit: Int(arguments.limit)
            )

            var payload = Mozz_V1_TracksResponse()
            payload.tracks = page.rows.map(Self.wire)
            payload.page = Self.pageInfo(page.next)
            return Self.response(id: request.id) { $0.tracks = payload }

        case .artist(let arguments):
            guard let artist = try await service.artist(
                serverId: ServerID(arguments.serverID),
                remoteId: arguments.remoteID
            ) else {
                return Self.failure(id: request.id, "artist not found: \(arguments.remoteID)")
            }
            let albums = try await service.artistAlbums(
                serverId: ServerID(arguments.serverID),
                remoteId: arguments.remoteID
            )
            let heroArtworkKey = ArtistDetailPresentation.heroArtworkKey(artist: artist, albums: albums)
            var payload = Mozz_V1_ArtistResponse()
            payload.artist = Self.wire(artist, heroArtworkKey: heroArtworkKey)
            return Self.response(id: request.id) { $0.artist = payload }

        case .artistAlbums(let arguments):
            let albums = try await service.artistAlbums(
                serverId: ServerID(arguments.serverID),
                remoteId: arguments.remoteID
            )
            var payload = Mozz_V1_ArtistAlbumsResponse()
            payload.albums = albums.map(Self.wire)
            return Self.response(id: request.id) { $0.artistAlbums = payload }

        case .albumTracks(let arguments):
            let tracks: [TrackRecord]
            if arguments.hasGroupKey {
                tracks = try await service.albumTracks(
                    serverId: ServerID(arguments.serverID),
                    groupKey: arguments.groupKey
                )
            } else if arguments.hasRemoteID {
                tracks = try await service.albumTracks(
                    serverId: ServerID(arguments.serverID),
                    remoteId: arguments.remoteID
                )
            } else {
                return Self.failure(id: request.id, "albumTracks needs remoteId or groupKey")
            }
            var payload = Mozz_V1_AlbumTracksResponse()
            payload.tracks = tracks.map(Self.wire)
            return Self.response(id: request.id) { $0.albumTracks = payload }

        case .counts(let arguments):
            let counts = try await service.counts(serverId: ServerID(arguments.serverID))
            var payload = Mozz_V1_CountsResponse()
            payload.artists = Int32(counts.artists)
            payload.albums = Int32(counts.albums)
            payload.tracks = Int32(counts.tracks)
            return Self.response(id: request.id) { $0.counts = payload }

        case .getPlaybackSettings:
            let settings = try await service.playbackSettings()
            var payload = Mozz_V1_GetPlaybackSettingsResponse()
            payload.settings = Self.wire(settings)
            return Self.response(id: request.id) { $0.getPlaybackSettings = payload }

        case .setPlaybackSettings(let arguments):
            let stored = try await service.setPlaybackSettings(Self.playbackSettings(arguments.settings))
            var payload = Mozz_V1_SetPlaybackSettingsResponse()
            payload.settings = Self.wire(stored)
            return Self.response(id: request.id) { $0.setPlaybackSettings = payload }

        case .artwork(let arguments):
            let outcome = await service.artwork(
                serverId: ServerID(arguments.serverID),
                artworkKey: arguments.artworkKey,
                size: Int(arguments.size)
            )
            var payload = Mozz_V1_ArtworkResponse()
            switch outcome {
            case .bytes(let data):
                payload.status = .present
                payload.data = data
            case .absent:
                payload.status = .absent
            case .unavailable:
                payload.status = .unavailable
            }
            return Self.response(id: request.id) { $0.artwork = payload }

        // MARK: Downloads
        //
        // Every mutating case addresses a track by (server, remote) and echoes
        // those ids straight back onto the wire Download, since the record is
        // keyed only by internal id and the caller thinks in remote ids.

        case .enqueueDownload(let arguments):
            let record = try await service.enqueueDownload(
                serverId: ServerID(arguments.serverID), remoteId: arguments.remoteID)
            var payload = Mozz_V1_EnqueueDownloadResponse()
            payload.download = Self.wire(record, serverId: arguments.serverID, remoteId: arguments.remoteID)
            return Self.response(id: request.id) { $0.enqueueDownload = payload }

        case .reportDownloadProgress(let arguments):
            let record = try await service.reportDownloadProgress(
                serverId: ServerID(arguments.serverID),
                remoteId: arguments.remoteID,
                receivedBytes: arguments.receivedBytes,
                totalBytes: arguments.hasTotalBytes ? arguments.totalBytes : nil)
            var payload = Mozz_V1_ReportDownloadProgressResponse()
            payload.download = Self.wire(record, serverId: arguments.serverID, remoteId: arguments.remoteID)
            return Self.response(id: request.id) { $0.reportDownloadProgress = payload }

        case .completeDownload(let arguments):
            let record = try await service.completeDownload(
                serverId: ServerID(arguments.serverID),
                remoteId: arguments.remoteID,
                localPath: arguments.localPath,
                sizeBytes: arguments.sizeBytes)
            var payload = Mozz_V1_CompleteDownloadResponse()
            payload.download = Self.wire(record, serverId: arguments.serverID, remoteId: arguments.remoteID)
            return Self.response(id: request.id) { $0.completeDownload = payload }

        case .failDownload(let arguments):
            let record = try await service.failDownload(
                serverId: ServerID(arguments.serverID),
                remoteId: arguments.remoteID,
                message: arguments.message)
            var payload = Mozz_V1_FailDownloadResponse()
            payload.download = Self.wire(record, serverId: arguments.serverID, remoteId: arguments.remoteID)
            return Self.response(id: request.id) { $0.failDownload = payload }

        case .cancelDownload(let arguments):
            let record = try await service.cancelDownload(
                serverId: ServerID(arguments.serverID), remoteId: arguments.remoteID)
            var payload = Mozz_V1_CancelDownloadResponse()
            payload.download = Self.wire(record, serverId: arguments.serverID, remoteId: arguments.remoteID)
            return Self.response(id: request.id) { $0.cancelDownload = payload }

        case .deleteDownload(let arguments):
            let removed = try await service.deleteDownload(
                serverId: ServerID(arguments.serverID), remoteId: arguments.remoteID)
            var payload = Mozz_V1_DeleteDownloadResponse()
            if let removed { payload.removedLocalPath = removed }
            return Self.response(id: request.id) { $0.deleteDownload = payload }

        case .downloadStatus(let arguments):
            let record = try await service.downloadStatus(
                serverId: ServerID(arguments.serverID), remoteId: arguments.remoteID)
            var payload = Mozz_V1_DownloadStatusResponse()
            // Absent record = "not downloaded"; the optional field is simply left
            // unset rather than filled with an invented empty download.
            if let record {
                payload.download = Self.wire(
                    record, serverId: arguments.serverID, remoteId: arguments.remoteID)
            }
            return Self.response(id: request.id) { $0.downloadStatus = payload }

        case .downloads(let arguments):
            let downloads = try await service.downloads(in: Self.downloadStates(arguments.states))
            var payload = Mozz_V1_DownloadsResponse()
            payload.downloads = downloads.map {
                Self.wire($0.record, serverId: $0.serverId, remoteId: $0.remoteId)
            }
            return Self.response(id: request.id) { $0.downloads = payload }

        case .storageUsage:
            let usage = try await service.storageUsage()
            var payload = Mozz_V1_StorageUsageResponse()
            payload.downloadedTrackCount = Int32(usage.downloadedTrackCount)
            payload.totalBytes = usage.totalBytes
            return Self.response(id: request.id) { $0.storageUsage = payload }

        case .lyrics(let arguments):
            let availability = try await service.lyrics(
                serverId: ServerID(arguments.serverID), remoteId: arguments.remoteID,
                resolve: arguments.resolve, useOnlineLookup: arguments.useOnlineLookup,
                userInitiated: arguments.userInitiated)
            var payload = Mozz_V1_LyricsResponse()
            switch availability {
            case .present(let lyrics):
                payload.status = .present
                payload.lyrics = Self.wire(lyrics)
            case .absent:
                payload.status = .absent
            case .notFetched:
                payload.status = .notFetched
            case .failed:
                payload.status = .failed
            }
            return Self.response(id: request.id) { $0.lyrics = payload }

        case .recordingIdentity(let arguments):
            let identity = try await service.recordingIdentity(
                serverId: ServerID(arguments.serverID), remoteId: arguments.remoteID)
            var payload = Mozz_V1_RecordingIdentityResponse()
            switch identity {
            case .resolved(let recordingMbid, let canonical, let artist):
                payload.status = .resolved
                payload.recordingMbid = recordingMbid
                if let canonical { payload.canonicalRecordingMbid = canonical }
                if let artist { payload.artistMbid = artist }
            case .unmatched:
                payload.status = .unmatched
            case .notResolved:
                payload.status = .notResolved
            }
            return Self.response(id: request.id) { $0.recordingIdentity = payload }

        case .similarTracks(let arguments):
            let scored = try await service.similarTracks(
                serverId: ServerID(arguments.serverID), remoteId: arguments.remoteID,
                limit: Int(arguments.limit))
            var payload = Mozz_V1_SimilarTracksResponse()
            payload.tracks = scored.map {
                var similar = Mozz_V1_SimilarTrack()
                similar.track = Self.wire($0.track)
                similar.score = $0.score
                return similar
            }
            return Self.response(id: request.id) { $0.similarTracks = payload }

        case .watchLibrary:
            // Declared in the schema before it is implemented, deliberately: the
            // shape of a subscription had to be settled while the wire format
            // was being designed, because retrofitting one is the expensive
            // version. Answering honestly is better than answering emptily.
            return Self.failure(id: request.id, "watchLibrary is not implemented yet")

        case .cancel:
            return Self.failure(id: request.id, "cancel is not implemented yet")

        case .none:
            // A command this build has never heard of. The core and the shells
            // ship separately, so one will eventually be older than the other;
            // say so rather than failing obscurely.
            return Self.failure(id: request.id, "unknown command — this build may be older than the caller")
        }
    }

    // MARK: Wire mapping

    private static func pageCursor(
        _ after: Mozz_V1_PageCursor,
        present: Bool
    ) -> LibraryRepository.PageCursor?? {
        guard present else { return .some(nil) }
        guard let cursor = LibraryRepository.PageCursor(token: after.token) else { return nil }
        return .some(cursor)
    }

    private static func pageInfo(_ next: LibraryRepository.PageCursor?) -> Mozz_V1_Page {
        var page = Mozz_V1_Page()
        if let next {
            var token = Mozz_V1_PageCursor()
            token.token = next.token
            page.next = token
        }
        return page
    }

    private static func wire(_ server: ServerConnection) -> Mozz_V1_Library {
        var library = Mozz_V1_Library()
        library.id = server.id
        library.name = server.name
        library.serverID = server.id
        return library
    }

    private static func wire(_ album: AlbumRecord) -> Mozz_V1_AlbumSummary {
        var summary = Mozz_V1_AlbumSummary()
        summary.id = album.id ?? 0
        summary.serverID = album.serverId
        summary.remoteID = album.remoteId
        summary.title = album.title
        if let sortTitle = album.sortTitle { summary.sortTitle = sortTitle }
        summary.artistName = album.artistName
        if let artistRemoteId = album.artistRemoteId { summary.artistRemoteID = artistRemoteId }
        if let year = album.year { summary.year = Int32(year) }
        if let artwork = album.artworkKey { summary.artworkKey = artwork }
        summary.trackCount = Int32(album.trackCount ?? 0)
        summary.groupKey = album.albumGroupKey
        summary.genres = album.genres
        summary.isFavorite = album.isFavorite
        if let addedAt = album.addedAt { summary.addedAt = addedAt }
        let release = AlbumReleaseClassifier.kind(trackCount: album.trackCount)
        summary.releaseKind = release.rawValue
        summary.isSingleOrEp = release.isSingleOrEP
        return summary
    }

    private static func wire(
        _ artist: ArtistRecord,
        heroArtworkKey: String? = nil
    ) -> Mozz_V1_Artist {
        var wired = Mozz_V1_Artist()
        wired.id = artist.id ?? 0
        wired.serverID = artist.serverId
        wired.remoteID = artist.remoteId
        wired.name = artist.name
        if let sortName = artist.sortName { wired.sortName = sortName }
        if let artwork = artist.artworkKey { wired.artworkKey = artwork }
        if let heroArtworkKey = heroArtworkKey ?? artist.artworkKey {
            wired.heroArtworkKey = heroArtworkKey
        }
        wired.albumCount = Int32(artist.albumCount ?? 0)
        wired.genres = artist.genres
        wired.isFavorite = artist.isFavorite
        return wired
    }

    private static func wire(_ track: TrackRecord) -> Mozz_V1_TrackSummary {
        var summary = Mozz_V1_TrackSummary()
        summary.id = track.id ?? 0
        summary.serverID = track.serverId
        summary.remoteID = track.remoteId
        summary.title = track.title
        summary.artistName = track.artistName
        if let albumTitle = track.albumTitle { summary.albumTitle = albumTitle }
        if let albumRemoteId = track.albumRemoteId { summary.albumRemoteID = albumRemoteId }
        if let trackNumber = track.trackNumber { summary.trackNumber = Int32(trackNumber) }
        if let discNumber = track.discNumber { summary.discNumber = Int32(discNumber) }
        summary.durationSeconds = track.duration
        if let artwork = track.artworkKey { summary.artworkKey = artwork }
        summary.isFavorite = track.isFavorite
        if let rating = track.rating { summary.rating = rating }
        if let addedAt = track.addedAt { summary.addedAt = addedAt }
        if let gain = track.normalizationGainDB { summary.normalizationGainDb = gain }
        return summary
    }

    // MARK: Enrichment mapping

    /// Domain lyrics → wire. `start_seconds` is set only on lines that carry a
    /// timestamp (unsynced lines leave it unset); `is_synced` is the domain
    /// model's own derived flag. The source token and its display name travel
    /// together, both unset when the source is unknown.
    private static func wire(_ lyrics: Lyrics) -> Mozz_V1_Lyrics {
        var wired = Mozz_V1_Lyrics()
        wired.lines = lyrics.lines.map { line in
            var wiredLine = Mozz_V1_LyricLine()
            wiredLine.text = line.text
            if let start = line.start { wiredLine.startSeconds = start }
            return wiredLine
        }
        if let source = lyrics.source {
            wired.source = source.rawValue
            wired.sourceDisplayName = source.displayName
        }
        wired.isSynced = lyrics.isSynced
        return wired
    }

    // MARK: Download mapping

    /// Core record → wire. The (server, remote) identity is threaded in by the
    /// caller — the record itself is keyed only by internal id — so a listed or
    /// queried download arrives on the wire addressable the same way every other
    /// track is. Progress travels as the raw received/total byte counters; a
    /// client computes any fraction it wants to draw.
    private static func wire(
        _ record: DownloadRecord, serverId: ServerID, remoteId: String
    ) -> Mozz_V1_Download {
        var wired = Mozz_V1_Download()
        wired.trackID = record.trackId
        wired.serverID = serverId
        wired.remoteID = remoteId
        wired.state = wire(record.downloadState)
        wired.receivedBytes = record.sizeBytes
        if let totalBytes = record.totalBytes { wired.totalBytes = totalBytes }
        if let localPath = record.localPath { wired.localPath = localPath }
        if let errorMessage = record.errorMessage { wired.errorMessage = errorMessage }
        wired.requestedAt = record.requestedAt
        if let completedAt = record.completedAt { wired.completedAt = completedAt }
        return wired
    }

    /// Core → wire state. A record whose stored string does not parse (a value
    /// written by a newer build) maps to UNSPECIFIED rather than a wrong case.
    private static func wire(_ state: DownloadState?) -> Mozz_V1_DownloadState {
        switch state {
        case .queued: return .queued
        case .downloading: return .downloading
        case .downloaded: return .downloaded
        case .failed: return .failed
        case .none: return .unspecified
        }
    }

    /// Wire → core states for the list filter. UNSPECIFIED and any unrecognized
    /// value (from a newer client) are dropped; an empty result means "no
    /// filter", which the repository reads as every state.
    private static func downloadStates(_ wire: [Mozz_V1_DownloadState]) -> [DownloadState] {
        wire.compactMap { state in
            switch state {
            case .queued: return .queued
            case .downloading: return .downloading
            case .downloaded: return .downloaded
            case .failed: return .failed
            case .unspecified, .UNRECOGNIZED: return nil
            }
        }
    }

    // MARK: Playback settings mapping

    /// Core → wire. The EQ curve is expanded to explicit band gains + preamp so
    /// no client needs to agree on a JSON shape to render it.
    private static func wire(_ settings: PlaybackSettings) -> Mozz_V1_PlaybackSettings {
        var wired = Mozz_V1_PlaybackSettings()
        wired.equalizerEnabled = settings.equalizerEnabled
        wired.equalizerBandGainsDb = settings.equalizer.gains
        wired.equalizerPreampDb = settings.equalizer.preampDB
        wired.replayGainMode = wire(settings.replayGainMode)
        wired.replayGainPreampDb = settings.replayGainPreampDB
        return wired
    }

    /// Wire → core. Every value passes through the value type's clamping
    /// initializers, so an out-of-range or wrong-length request is normalized
    /// rather than rejected. An unset/UNSPECIFIED mode takes the core default.
    private static func playbackSettings(_ wire: Mozz_V1_PlaybackSettings) -> PlaybackSettings {
        PlaybackSettings(
            equalizerEnabled: wire.equalizerEnabled,
            equalizer: EqualizerSettings(gains: wire.equalizerBandGainsDb, preampDB: wire.equalizerPreampDb),
            replayGainMode: replayGainMode(wire.replayGainMode),
            replayGainPreampDB: wire.replayGainPreampDb
        )
    }

    private static func wire(_ mode: ReplayGainMode) -> Mozz_V1_ReplayGainMode {
        switch mode {
        case .off: return .off
        case .track: return .track
        case .album: return .album
        }
    }

    private static func replayGainMode(_ wire: Mozz_V1_ReplayGainMode) -> ReplayGainMode {
        switch wire {
        case .off: return .off
        case .track: return .track
        case .album: return .album
        // A client that omitted the field, or a build newer than this one, takes
        // the core's default rather than an invented value.
        case .unspecified, .UNRECOGNIZED: return .default
        }
    }

    // MARK: Envelopes

    private static func response(
        id: UInt64,
        _ fill: (inout Mozz_V1_Response) -> Void
    ) -> Mozz_V1_Response {
        var response = Mozz_V1_Response()
        response.id = id
        fill(&response)
        return response
    }

    private static func failure(id: UInt64, _ message: String) -> Mozz_V1_Response {
        var failure = Mozz_V1_Failure()
        failure.message = message
        return response(id: id) { $0.failure = failure }
    }

    /// Encoding a response cannot meaningfully fail — every field is set from
    /// values already in memory — but the API is throwing, so the fallback is an
    /// empty payload rather than a crash on a path that should never run.
    private static func encode(_ response: Mozz_V1_Response) -> Data {
        (try? response.serializedData()) ?? Data()
    }
}
