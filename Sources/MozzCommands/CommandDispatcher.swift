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
