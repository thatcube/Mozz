import Foundation
import MozzCore

/// Pure DTO -> domain mapping. No I/O, so it is exhaustively unit-testable
/// against recorded fixtures. Ids are kept OPAQUE (whatever string the server
/// used); OpenSubsonic rich fields (musicBrainzId, replayGain, per-item genres,
/// sortName, userRating, starred) are mapped when present and simply absent on
/// classic servers.
enum SubsonicMapper {
    // MARK: Entities

    static func artist(_ dto: SubsonicArtistID3) -> Artist {
        Artist(
            id: dto.id?.value ?? "",
            name: dto.name ?? "Unknown Artist",
            sortName: dto.sortName,
            artwork: artwork(dto.coverArt) ?? artwork(dto.id),
            albumCount: dto.albumCount,
            genres: [],
            isFavorite: dto.starred != nil
        )
    }

    static func album(_ dto: SubsonicAlbumID3) -> Album {
        Album(
            id: dto.id?.value ?? "",
            title: dto.name ?? "Unknown Album",
            sortTitle: dto.sortName,
            artistName: dto.artist ?? "Unknown Artist",
            artistID: dto.artistId?.value,
            year: dto.year,
            artwork: artwork(dto.coverArt) ?? artwork(dto.id),
            trackCount: dto.songCount,
            genres: genres(single: dto.genre, list: dto.genres),
            isFavorite: dto.starred != nil,
            addedAt: date(dto.created)
        )
    }

    static func track(_ dto: SubsonicChild) -> Track {
        let format = AudioFormat(
            container: dto.suffix,
            codec: dto.suffix,
            bitrateKbps: dto.bitRate,
            sampleRateHz: dto.samplingRate,
            channels: dto.channelCount,
            bitDepth: dto.bitDepth
        )
        // Prefer the item's own cover art, falling back to its album's.
        let art = artwork(dto.coverArt) ?? artwork(dto.albumId)
        return Track(
            id: dto.id?.value ?? "",
            title: dto.title ?? "Unknown",
            sortTitle: dto.sortName,
            albumTitle: dto.album,
            albumID: dto.albumId?.value,
            artistName: dto.artist ?? "Unknown Artist",
            artistID: dto.artistId?.value,
            albumArtistName: nil,
            trackNumber: dto.track,
            discNumber: dto.discNumber,
            duration: dto.duration.map(TimeInterval.init) ?? 0,
            format: format,
            fileSizeBytes: dto.size,
            // The opaque song id is the key for stream/download URLs (`id=`).
            mediaKey: dto.id?.value,
            artwork: art,
            genres: genres(single: dto.genre, list: dto.genres),
            isFavorite: dto.starred != nil,
            rating: dto.userRating.map(Double.init),
            normalizationGainDB: dto.replayGain?.trackGain ?? dto.replayGain?.albumGain,
            addedAt: date(dto.created),
            mbid: MusicBrainzID.normalized(dto.musicBrainzId),
            artistMbid: nil
        )
    }

    static func playlist(_ dto: SubsonicPlaylistDTO) -> Playlist {
        Playlist(
            id: dto.id?.value ?? "",
            title: dto.name ?? "Playlist",
            trackCount: dto.songCount,
            durationSeconds: dto.duration.map(TimeInterval.init),
            artwork: artwork(dto.coverArt) ?? artwork(dto.id),
            isSmart: false
        )
    }

    // MARK: Helpers

    /// A cover-art reference. The opaque `coverArt` id (or, as a fallback, the
    /// item id — Subsonic accepts an entity id at `getCoverArt`) is stored raw;
    /// ``SubsonicBackend/artworkURL(for:size:)`` turns it into a signed,
    /// deterministic URL.
    static func artwork(_ id: SubsonicID?) -> ArtworkRef? {
        guard let value = id?.value, !value.isEmpty else { return nil }
        return ArtworkRef(key: value)
    }

    /// Merge Subsonic's single `genre` string with OpenSubsonic's `genres`
    /// array, de-duplicated (case-insensitively) and order-preserving, dropping
    /// blanks.
    static func genres(single: String?, list: [SubsonicGenreDTO]?) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        func add(_ name: String?) {
            guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return }
            let key = name.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            out.append(name)
        }
        add(single)
        for g in list ?? [] { add(g.name) }
        return out
    }

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
