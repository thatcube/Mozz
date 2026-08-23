#if os(iOS)
import Foundation
import Intents
import MozzCore
import MozzDatabase

/// What a spoken media request resolved to inside the catalog.
struct MediaIntentResolution {
    var subject: MediaIntentSubject
    var title: String
    var artist: String?
    var type: INMediaItemType
    var tracks: [Track]
    /// Content that is a mix by nature — an artist, a genre, the whole library —
    /// and should shuffle unless Siri asked for a particular order.
    var prefersShuffle = false
    /// Keep playing similar music once `tracks` runs out. Set for requests that
    /// name a single song, where a three-minute queue that then falls silent is
    /// a poor answer on a speaker in another room.
    var continuesAsStation = false
    var artworkKey: String?
}

enum MediaIntentOutcome {
    case resolved(MediaIntentResolution)
    /// The request named something specific that this library doesn't have.
    case notFound
    /// Podcasts, audiobooks, video — things Mozz is not.
    case unsupportedMediaType
    case signInRequired
    /// The session couldn't be restored in time — typically a server that can't
    /// be reached from wherever the phone currently is.
    case serviceUnavailable
}

/// Turns Siri's parse of a spoken request into something concrete to play.
///
/// Siri does the language work and hands over an `INMediaSearch`: a media type it
/// guessed at, plus whichever of name / artist / album / genre / mood it managed
/// to pick out. Very often the type is `unknown` and the whole request is a bare
/// name, because only the app can know whether "Rumours" is an album, a song, or
/// a playlist someone made. Resolving that against the user's own server — which
/// may hold anything at all and nothing in particular — is this type's job.
@MainActor
struct MediaIntentResolver {
    let env: AppEnvironment

    /// Media types Mozz has no answer for. Saying so explicitly is what gets Siri
    /// to reply "Mozz doesn't support playing that" rather than the far more
    /// misleading "I couldn't find that in your Mozz library".
    private static let unsupportedTypes: Set<INMediaItemType> = [
        .podcastShow, .podcastEpisode, .podcastPlaylist, .podcastStation,
        .audioBook, .movie, .tvShow, .tvShowEpisode, .musicVideo, .news,
    ]

    /// Words that name no particular music: "play music", "play some songs".
    /// Siri passes these through as a media name, so they have to be recognised
    /// as "anything" or every one of them would be searched for and missed.
    private static let genericTerms: Set<String> = [
        "music", "song", "songs", "some music", "some songs", "any music",
        "anything", "something", "tunes", "my music", "my songs", "my library",
        "library", "audio", "playlist", "playlists",
    ]

    // MARK: - Entry point

    func resolve(_ search: INMediaSearch?) async -> MediaIntentOutcome {
        guard let serverId = env.active?.connection.id else { return .signInRequired }
        guard let search else { return await personalMix(serverId: serverId) }

        // A donated intent replayed by the system carries the identifier Mozz
        // minted, so rebuild precisely what was donated instead of parsing the
        // same words a second time and possibly landing somewhere else.
        if let raw = search.mediaIdentifier, let subject = MediaIntentSubject(rawValue: raw),
           let rebuilt = await resolve(subject: subject, serverId: serverId) {
            return .resolved(rebuilt)
        }

        if Self.unsupportedTypes.contains(search.mediaType) { return .unsupportedMediaType }

        // "Play this again" / the target of an add or affinity request.
        if search.reference == .currentlyPlaying, let current = env.playback.currentTrack {
            return .resolved(single(current))
        }

        let name = Self.meaningful(search.mediaName)
        let artist = Self.meaningful(search.artistName)
        let album = Self.meaningful(search.albumName)
        let genres = (search.genreNames ?? []).compactMap(Self.meaningful)
        let moods = (search.moodNames ?? []).compactMap(Self.meaningful)
        let wantsStation = Self.stationTypes.contains(search.mediaType)

        // Siri passes "music" and "some songs" through as a media name even though
        // they name nothing at all. Recognising that as the *absence* of a target
        // is what lets the rest of the request still count: "play popular music"
        // reaches the sort order rather than searching the library for a band
        // called Music and coming back empty.
        let named = name.flatMap { Self.genericTerms.contains(Self.normalized($0)) ? nil : $0 }

        if named == nil, artist == nil, album == nil, genres.isEmpty, moods.isEmpty {
            return await unspecified(sortOrder: search.sortOrder, serverId: serverId)
        }

        // Siri named a type it is confident about — honour it, so "play the album
        // Rumours" can't land on a song of the same name.
        switch search.mediaType {
        case .playlist:
            if let match = await playlist(named: named ?? album, serverId: serverId) {
                return .resolved(match)
            }
        case .album:
            if let match = await albumResolution(named: album ?? named, artist: artist, serverId: serverId) {
                return .resolved(match)
            }
        case .artist:
            if let match = await artistResolution(named: artist ?? named, serverId: serverId) {
                return .resolved(station(match, if: wantsStation))
            }
        case .song:
            if let match = await songResolution(named: named, artist: artist, album: album, serverId: serverId) {
                return .resolved(match)
            }
        case .genre:
            if let match = await genreResolution(named: genres.first ?? named, serverId: serverId) {
                return .resolved(station(match, if: wantsStation))
            }
        default:
            break
        }

        // Untyped, which is the common case: Siri passes the words along and
        // leaves it to the app to work out what kind of thing they name.
        if let named, let match = await bestMatch(for: named, artist: artist, serverId: serverId) {
            return .resolved(station(match, if: wantsStation))
        }
        if named == nil, let artist, let match = await artistResolution(named: artist, serverId: serverId) {
            return .resolved(station(match, if: wantsStation))
        }
        if named == nil, artist == nil, let album,
           let match = await albumResolution(named: album, artist: nil, serverId: serverId) {
            return .resolved(match)
        }

        // Only a genre or a mood was given. A mood Mozz holds no tag for ("play
        // something relaxing") still deserves music rather than an apology, so
        // fall back to the personal mix — but only here, where nothing specific
        // was named. A missed artist name must still report "not found", or Siri
        // would silently play something unrelated and look broken.
        if !genres.isEmpty || !moods.isEmpty {
            for term in genres + moods {
                if let match = await genreResolution(named: term, serverId: serverId) {
                    return .resolved(station(match, if: wantsStation))
                }
            }
            if named == nil, artist == nil, album == nil {
                return await personalMix(serverId: serverId)
            }
        }
        return .notFound
    }

    // MARK: - Rebuilding a donated subject

    /// Rebuild a queue from an identifier alone — the path taken when handling
    /// follows resolution, and when the system replays a donated intent.
    func resolve(subject: MediaIntentSubject) async -> MediaIntentOutcome {
        guard let serverId = env.active?.connection.id else { return .signInRequired }
        guard let resolution = await resolve(subject: subject, serverId: serverId) else { return .notFound }
        return .resolved(resolution)
    }

    private func resolve(subject: MediaIntentSubject, serverId: ServerID) async -> MediaIntentResolution? {
        switch subject {
        case .song(let remoteId):
            let rows = (try? await env.repository.tracksForPlayback(remoteIds: [remoteId], serverId: serverId)) ?? []
            return rows.first.map { single($0) }
        case .album(let remoteId):
            guard let album = try? await env.repository.album(serverId: serverId, remoteId: remoteId) else { return nil }
            return await albumResolution(record: album, serverId: serverId)
        case .artist(let remoteId):
            guard let artist = try? await env.repository.artist(serverId: serverId, remoteId: remoteId) else { return nil }
            return await artistResolution(record: artist, serverId: serverId)
        case .playlist(let remoteId):
            let all = (try? await env.repository.allPlaylists(serverId: serverId)) ?? []
            guard let playlist = all.first(where: { $0.remoteId == remoteId }) else { return nil }
            return await playlistResolution(record: playlist, serverId: serverId)
        case .genre(let genre):
            return await genreResolution(named: genre, serverId: serverId)
        case .mix(let id):
            guard let set = try? await env.recommendations.set(id: id),
                  let rows = try? await env.recommendations.tracks(forSetId: id), !rows.isEmpty
            else { return nil }
            return MediaIntentResolution(subject: .mix(id), title: set.title, type: .music,
                                         tracks: rows.map { $0.toDomain() })
        case .liked:
            return await likedSongs(serverId: serverId)
        case .recentlyAdded:
            return await recentlyAdded(serverId: serverId)
        case .library:
            return await wholeLibrary(serverId: serverId)
        }
    }

    // MARK: - Untyped name matching

    /// Work out what a bare spoken name refers to.
    ///
    /// Everything with that name is scored on how well it matches, then ties are
    /// broken by kind: an exact hit always wins, and between two equally good
    /// matches an artist beats an album beats a playlist beats a genre beats a
    /// single song. That ordering is what makes "play Radiohead" play the artist
    /// even when a song by that name exists.
    private func bestMatch(for name: String, artist: String?, serverId: ServerID) async -> MediaIntentResolution? {
        guard !Self.genericTerms.contains(Self.normalized(name)) else {
            if case .resolved(let mix) = await personalMix(serverId: serverId) { return mix }
            return nil
        }

        let results = try? await env.repository.search(name, serverId: serverId, limitPerType: 25)
        let playlists = (try? await env.repository.allPlaylists(serverId: serverId)) ?? []
        let genres = (try? await env.repository.genres(serverId: serverId)) ?? []

        enum Kind: Int { case song = 1, genre = 2, playlist = 3, album = 4, artist = 5 }
        var best: (score: Int, kind: Kind, index: Int)?
        func consider(_ candidate: String, _ kind: Kind, _ index: Int, boost: Int = 0) {
            let score = Self.score(candidate, against: name) + boost
            guard score > 0 else { return }
            guard let current = best else { best = (score, kind, index); return }
            if score > current.score || (score == current.score && kind.rawValue > current.kind.rawValue) {
                best = (score, kind, index)
            }
        }

        let artists = results?.artists ?? []
        let albums = results?.albums ?? []
        let tracks = results?.tracks ?? []
        for (i, item) in artists.enumerated() { consider(item.name, .artist, i) }
        for (i, item) in albums.enumerated() {
            // "Play <album> by <artist>" — a named artist settles which of several
            // same-titled albums was meant.
            consider(item.title, .album, i, boost: Self.matches(item.artistName, artist) ? 1 : 0)
        }
        for (i, item) in playlists.enumerated() { consider(item.title, .playlist, i) }
        for (i, item) in genres.enumerated() { consider(item, .genre, i) }
        for (i, item) in tracks.enumerated() {
            consider(item.title, .song, i, boost: Self.matches(item.artistName, artist) ? 1 : 0)
        }

        guard let best else { return nil }
        switch best.kind {
        case .artist: return await artistResolution(record: artists[best.index], serverId: serverId)
        case .album: return await albumResolution(record: albums[best.index], serverId: serverId)
        case .playlist: return await playlistResolution(record: playlists[best.index], serverId: serverId)
        case .genre: return await genreResolution(named: genres[best.index], serverId: serverId)
        case .song: return single(tracks[best.index].toDomain())
        }
    }

    // MARK: - Typed lookups

    private func playlist(named name: String?, serverId: ServerID) async -> MediaIntentResolution? {
        guard let name else { return nil }
        let all = (try? await env.repository.allPlaylists(serverId: serverId)) ?? []
        guard let match = Self.best(all, named: name, by: \.title) else { return nil }
        return await playlistResolution(record: match, serverId: serverId)
    }

    private func playlistResolution(record: PlaylistRecord, serverId: ServerID) async -> MediaIntentResolution? {
        let rows = (try? await env.repository.tracks(forPlaylistRemoteId: record.remoteId, serverId: serverId)) ?? []
        guard !rows.isEmpty else { return nil }
        return MediaIntentResolution(subject: .playlist(record.remoteId), title: record.title,
                                     type: .playlist, tracks: rows.map { $0.toDomain() },
                                     artworkKey: record.artworkKey)
    }

    private func albumResolution(named name: String?, artist: String?,
                                 serverId: ServerID) async -> MediaIntentResolution? {
        guard let name else { return nil }
        let results = try? await env.repository.search(name, serverId: serverId, limitPerType: 25)
        var albums = results?.albums ?? []
        if artist != nil {
            let byArtist = albums.filter { Self.matches($0.artistName, artist) }
            if !byArtist.isEmpty { albums = byArtist }
        }
        guard let match = Self.best(albums, named: name, by: \.title) else { return nil }
        return await albumResolution(record: match, serverId: serverId)
    }

    private func albumResolution(record: AlbumRecord, serverId: ServerID) async -> MediaIntentResolution? {
        // By group, not by remote id: a server that split an album across several
        // entries should still play as the one album the user asked for.
        let rows = (try? await env.repository.tracks(forAlbumGroupContaining: record.remoteId,
                                                    serverId: serverId)) ?? []
        guard !rows.isEmpty else { return nil }
        return MediaIntentResolution(subject: .album(record.remoteId), title: record.title,
                                     artist: record.artistName, type: .album,
                                     tracks: rows.map { $0.toDomain() }, artworkKey: record.artworkKey)
    }

    private func artistResolution(named name: String?, serverId: ServerID) async -> MediaIntentResolution? {
        guard let name else { return nil }
        let results = try? await env.repository.search(name, serverId: serverId, limitPerType: 25)
        guard let match = Self.best(results?.artists ?? [], named: name, by: \.name) else { return nil }
        return await artistResolution(record: match, serverId: serverId)
    }

    private func artistResolution(record: ArtistRecord, serverId: ServerID) async -> MediaIntentResolution? {
        let rows = (try? await env.repository.topTracks(forArtistRemoteId: record.remoteId,
                                                       serverId: serverId, limit: 300)) ?? []
        guard !rows.isEmpty else { return nil }
        return MediaIntentResolution(subject: .artist(record.remoteId), title: record.name,
                                     artist: record.name, type: .artist,
                                     tracks: rows.map { $0.toDomain() },
                                     prefersShuffle: true, artworkKey: record.artworkKey)
    }

    private func songResolution(named name: String?, artist: String?, album: String?,
                                serverId: ServerID) async -> MediaIntentResolution? {
        guard let name else { return nil }
        let results = try? await env.repository.search(name, serverId: serverId, limitPerType: 30)
        var tracks = results?.tracks ?? []
        if artist != nil {
            let byArtist = tracks.filter { Self.matches($0.artistName, artist) }
            if !byArtist.isEmpty { tracks = byArtist }
        }
        if album != nil {
            let onAlbum = tracks.filter { Self.matches($0.albumTitle ?? "", album) }
            if !onAlbum.isEmpty { tracks = onAlbum }
        }
        guard let match = Self.best(tracks, named: name, by: \.title) else { return nil }
        return single(match.toDomain())
    }

    private func genreResolution(named name: String?, serverId: ServerID) async -> MediaIntentResolution? {
        guard let name else { return nil }
        let all = (try? await env.repository.genres(serverId: serverId)) ?? []
        guard let genre = Self.best(all, named: name, by: \.self) else { return nil }
        // Genres are stored per album, so the pool is gathered album by album.
        // Bounded on both sides: enough to feel endless, few enough that Siri's
        // ten-second budget is never in question.
        let albums = (try? await env.repository.albums(forGenre: genre, serverId: serverId)) ?? []
        var tracks: [Track] = []
        for album in albums.prefix(50) {
            let rows = (try? await env.repository.tracks(forAlbumGroupContaining: album.remoteId,
                                                        serverId: serverId)) ?? []
            tracks.append(contentsOf: rows.map { $0.toDomain() })
            if tracks.count >= 300 { break }
        }
        guard !tracks.isEmpty else { return nil }
        return MediaIntentResolution(subject: .genre(genre), title: genre, type: .genre,
                                     tracks: tracks, prefersShuffle: true)
    }

    // MARK: - Nothing in particular was asked for

    private func unspecified(sortOrder: INMediaSortOrder, serverId: ServerID) async -> MediaIntentOutcome {
        switch sortOrder {
        case .newest:
            if let match = await recentlyAdded(serverId: serverId) { return .resolved(match) }
        case .popular, .best, .trending:
            if let match = await likedSongs(serverId: serverId) { return .resolved(match) }
        default:
            break
        }
        return await personalMix(serverId: serverId)
    }

    /// The answer to a bare "play music": Mozz Weekly when it has been generated,
    /// otherwise the whole library shuffled. Never an error — someone talking to a
    /// speaker asked for music, and the library is full of it.
    private func personalMix(serverId: ServerID) async -> MediaIntentOutcome {
        if let set = try? await env.recommendations.mozzWeeklySet(),
           let rows = try? await env.recommendations.mozzWeeklyTracks(), !rows.isEmpty {
            return .resolved(MediaIntentResolution(subject: .mix(set.id), title: set.title,
                                                   type: .music, tracks: rows.map { $0.toDomain() }))
        }
        guard let library = await wholeLibrary(serverId: serverId) else { return .notFound }
        return .resolved(library)
    }

    private func wholeLibrary(serverId: ServerID) async -> MediaIntentResolution? {
        let all = (try? await env.repository.allTracksForPlayback(serverId: serverId)) ?? []
        guard !all.isEmpty else { return nil }
        return MediaIntentResolution(subject: .library, title: "Your Library", type: .music,
                                     tracks: all, prefersShuffle: true)
    }

    private func likedSongs(serverId: ServerID) async -> MediaIntentResolution? {
        let rows = (try? await env.repository.likedTracks(serverId: serverId, limit: 300)) ?? []
        guard !rows.isEmpty else { return nil }
        return MediaIntentResolution(subject: .liked, title: "Liked Songs", type: .music,
                                     tracks: rows.map { $0.toDomain() }, prefersShuffle: true)
    }

    private func recentlyAdded(serverId: ServerID) async -> MediaIntentResolution? {
        let rows = (try? await env.repository.recentlyAddedTracks(serverId: serverId, limit: 200)) ?? []
        guard !rows.isEmpty else { return nil }
        return MediaIntentResolution(subject: .recentlyAdded, title: "Recently Added",
                                     type: .music, tracks: rows.map { $0.toDomain() })
    }

    // MARK: - Helpers

    private static let stationTypes: Set<INMediaItemType> = [
        .station, .musicStation, .radioStation, .algorithmicRadioStation,
    ]

    /// A single song plays on its own but doesn't end the listening: similar music
    /// follows it, the way a speaker in the kitchen ought to behave.
    private func single(_ track: Track) -> MediaIntentResolution {
        MediaIntentResolution(subject: .song(track.id), title: track.title, artist: track.artistName,
                              type: .song, tracks: [track], continuesAsStation: true,
                              artworkKey: track.artwork?.key)
    }

    /// "Play <artist> radio" resolves the artist exactly as a plain request would,
    /// then keeps going once their songs run out.
    private func station(_ resolution: MediaIntentResolution, if wanted: Bool) -> MediaIntentResolution {
        guard wanted else { return resolution }
        var stationed = resolution
        stationed.prefersShuffle = true
        stationed.continuesAsStation = true
        return stationed
    }

    /// Trimmed, or `nil` when Siri passed an empty string.
    private static func meaningful(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How well a name from the catalog answers what was said: exact beats prefix
    /// beats contains, and `0` means "not this at all".
    static func score(_ candidate: String, against spoken: String) -> Int {
        let candidate = normalized(candidate), spoken = normalized(spoken)
        guard !candidate.isEmpty, !spoken.isEmpty else { return 0 }
        if candidate == spoken { return 4 }
        if candidate.hasPrefix(spoken) || spoken.hasPrefix(candidate) { return 3 }
        // Substring matching only once there's enough of a word to be meaningful,
        // or a two-letter band name would match half the library.
        guard candidate.count >= 4, spoken.count >= 4 else { return 0 }
        if candidate.contains(spoken) || spoken.contains(candidate) { return 2 }
        return 0
    }

    private static func matches(_ candidate: String, _ spoken: String?) -> Bool {
        guard let spoken else { return false }
        return score(candidate, against: spoken) > 0
    }

    private static func best<T>(_ items: [T], named name: String, by key: KeyPath<T, String>) -> T? {
        var winner: T?
        var winningScore = 0
        for item in items {
            let score = score(item[keyPath: key], against: name)
            if score > winningScore {
                winner = item
                winningScore = score
            }
        }
        return winner
    }
}
#endif
