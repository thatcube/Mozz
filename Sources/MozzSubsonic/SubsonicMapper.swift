import Foundation
import MozzCore

/// Pure DTO -> domain mapping. No I/O, so it is exhaustively unit-testable
/// against recorded fixtures.
enum SubsonicMapper {
    static func artist(_ dto: ArtistID3DTO) -> Artist {
        Artist(
            id: dto.id,
            name: dto.name,
            sortName: dto.sortName,
            artwork: artwork(coverArt: dto.coverArt),
            albumCount: dto.albumCount,
            genres: [],
            isFavorite: dto.starred != nil
        )
    }

    static func album(_ dto: AlbumID3DTO) -> Album {
        Album(
            id: dto.id,
            title: dto.name,
            artistName: dto.artist ?? "Unknown Artist",
            artistID: dto.artistId,
            year: dto.year,
            artwork: artwork(coverArt: dto.coverArt),
            trackCount: dto.songCount,
            genres: genres(single: dto.genre, list: dto.genres),
            isFavorite: dto.starred != nil,
            addedAt: date(dto.created)
        )
    }

    /// `getAlbum` (`AlbumID3WithSongsDTO`) duplicates every `AlbumID3` field
    /// alongside its `song` list. Two DTOs exist because `getAlbumList2`
    /// doesn't return `song` and the field sets, while identical today, are
    /// independently defined by the spec — but they map through identical
    /// logic to ``album(_:)``.
    static func album(_ dto: AlbumID3WithSongsDTO) -> Album {
        Album(
            id: dto.id,
            title: dto.name,
            artistName: dto.artist ?? "Unknown Artist",
            artistID: dto.artistId,
            year: dto.year,
            artwork: artwork(coverArt: dto.coverArt),
            trackCount: dto.songCount,
            genres: genres(single: dto.genre, list: dto.genres),
            isFavorite: dto.starred != nil,
            addedAt: date(dto.created)
        )
    }

    static func track(_ dto: ChildDTO) -> Track {
        // Subsonic's `Child` schema has no separate codec field: `suffix` (the
        // file extension, e.g. "flac", "mp3") doubles as both container and
        // codec identifier for every format Mozz's transcode gate cares about
        // (see `SubsonicBackend.isDirectPlayFriendly`).
        let format = AudioFormat(
            container: dto.suffix,
            codec: dto.suffix,
            bitrateKbps: dto.bitRate,
            sampleRateHz: dto.samplingRate,
            channels: dto.channelCount,
            bitDepth: dto.bitDepth
        )
        return Track(
            id: dto.id,
            title: dto.title,
            albumTitle: dto.album,
            albumID: dto.albumId,
            artistName: dto.artist ?? "Unknown Artist",
            artistID: dto.artistId,
            albumArtistName: dto.artist,
            trackNumber: dto.track,
            discNumber: dto.discNumber,
            duration: dto.duration.map(TimeInterval.init) ?? 0,
            format: format,
            fileSizeBytes: dto.size,
            mediaKey: dto.id,
            artwork: artwork(coverArt: dto.coverArt),
            genres: genres(single: dto.genre, list: dto.genres),
            isFavorite: dto.starred != nil,
            rating: rating(dto.userRating),
            normalizationGainDB: dto.replayGain?.trackGain ?? dto.replayGain?.albumGain,
            addedAt: date(dto.created),
            mbid: MusicBrainzID.normalized(dto.musicBrainzId),
            // Subsonic's `Child` schema carries no separate artist MBID field
            // (only the OpenSubsonic `musicBrainzId`, which is the
            // *recording* mbid mapped above) — stays nil, matching Plex.
            artistMbid: nil
        )
    }

    static func playlist(_ dto: PlaylistDTO) -> Playlist {
        Playlist(
            id: dto.id,
            title: dto.name,
            trackCount: dto.songCount,
            durationSeconds: dto.duration.map(TimeInterval.init),
            artwork: artwork(coverArt: dto.coverArt),
            isSmart: false
        )
    }

    static func playlist(_ dto: PlaylistWithSongsDTO) -> Playlist {
        Playlist(
            id: dto.id,
            title: dto.name,
            trackCount: dto.songCount,
            durationSeconds: dto.duration.map(TimeInterval.init),
            artwork: artwork(coverArt: dto.coverArt),
            isSmart: false
        )
    }

    /// A stable artwork reference built from a bare `coverArt` id.
    ///
    /// Unlike Jellyfin (whose reference embeds an image *tag* that changes
    /// whenever artwork is replaced), Subsonic's `coverArt` id is already the
    /// full opaque token `getCoverArt` needs — no composite key required. It
    /// stays deterministic across launches because ``SubsonicBackend/artworkURL``
    /// signs it with the same persisted credential every time (see
    /// architecture point 8): a random per-launch salt would have made this
    /// reference resolve to a different URL each launch and thrashed the
    /// artwork cache.
    static func artwork(coverArt: String?) -> ArtworkRef? {
        guard let coverArt, !coverArt.isEmpty else { return nil }
        return ArtworkRef(key: coverArt)
    }

    /// Prefer OpenSubsonic's structured `genres[]` (a name list) over the
    /// classic singular `genre` string when present; fall back to wrapping the
    /// singular field for classic-profile servers that don't send `genres`.
    static func genres(single: String?, list: [GenreDTO]?) -> [String] {
        if let list, !list.isEmpty {
            return list.map(\.name)
        }
        if let single, !single.isEmpty {
            return [single]
        }
        return []
    }

    /// Subsonic's `userRating` is an integer 1–5 star rating (`0`/absent =
    /// unrated). Mozz's domain `rating` is a `Double` 0–5 in half-star steps
    /// (matching Plex) — Subsonic has no half-star granularity, so this is a
    /// direct widening, not a rescale.
    static func rating(_ stars: Int?) -> Double? {
        guard let stars, stars > 0 else { return nil }
        return Double(stars)
    }

    /// Parses Subsonic's `created`/`starred` ISO-8601 timestamps. Mirrors
    /// `JellyfinMapper.date(_:)`: try fractional-seconds first, then plain —
    /// `ISO8601DateFormatter`'s fractional mode is strict about digit count,
    /// so a server emitting nanosecond precision falls through to `nil`
    /// (an accepted, pre-existing limitation, not something new here).
    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        return isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()
}
