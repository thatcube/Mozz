import Foundation
import MozzCore

/// Pure DTO → domain mapping. No I/O, exhaustively unit-tested against
/// recorded OpenSubsonic JSON fixtures.
enum SubsonicMapper {
    static func artist(_ dto: SSArtistRef) -> Artist {
        Artist(
            id: dto.id.value,
            name: dto.name ?? "Unknown Artist",
            artwork: artwork(coverArt: dto.coverArt),
            albumCount: dto.albumCount,
            isFavorite: dto.starred != nil
        )
    }

    static func album(_ dto: SSAlbumSummary) -> Album {
        Album(
            id: dto.id.value,
            title: dto.name ?? "Unknown Album",
            artistName: dto.artist ?? "Unknown Artist",
            artistID: dto.artistId?.value,
            year: dto.year,
            artwork: artwork(coverArt: dto.coverArt),
            trackCount: dto.songCount,
            genres: dto.genre.map { [$0] } ?? [],
            isFavorite: dto.starred != nil,
            addedAt: date(dto.created)
        )
    }

    static func album(_ dto: SSAlbumWithSongs) -> Album {
        Album(
            id: dto.id.value,
            title: dto.name ?? "Unknown Album",
            artistName: dto.artist ?? "Unknown Artist",
            artistID: dto.artistId?.value,
            year: dto.year,
            artwork: artwork(coverArt: dto.coverArt),
            trackCount: dto.songCount ?? dto.song?.count,
            genres: dto.genre.map { [$0] } ?? [],
            isFavorite: dto.starred != nil,
            addedAt: date(dto.created)
        )
    }

    static func track(_ dto: SSSong) -> Track {
        let bitrate = dto.bitRate
        let format = AudioFormat(
            container: dto.suffix,
            codec: dto.contentType.map(codec(fromContentType:)) ?? dto.suffix,
            bitrateKbps: bitrate,
            sampleRateHz: dto.samplingRate,
            channels: dto.channelCount,
            bitDepth: dto.bitDepth
        )
        // ReplayGain: prefer track gain; fall back to album gain if the server
        // only provides that. Both are already in dB.
        let normalization = dto.replayGain?.trackGain ?? dto.replayGain?.albumGain
        // Stars 1-5 → half-star rating 0.5-5.0 (Subsonic has no half-star).
        let rating = dto.userRating.flatMap { $0 >= 1 && $0 <= 5 ? Double($0) : nil }
        return Track(
            id: dto.id.value,
            title: dto.title ?? "Unknown",
            albumTitle: dto.album,
            albumID: dto.albumId?.value,
            artistName: dto.artist ?? "Unknown Artist",
            artistID: dto.artistId?.value,
            albumArtistName: dto.artist,
            trackNumber: dto.track,
            discNumber: dto.discNumber,
            duration: TimeInterval(dto.duration ?? 0),
            format: format,
            fileSizeBytes: dto.size,
            mediaKey: dto.id.value,
            artwork: artwork(coverArt: dto.coverArt) ?? artwork(coverArt: dto.albumId?.value),
            genres: dto.genre.map { [$0] } ?? [],
            isFavorite: dto.starred != nil,
            rating: rating,
            normalizationGainDB: normalization,
            addedAt: nil,
            mbid: MusicBrainzID.extract(fromGUID: dto.musicBrainzId),
            artistMbid: nil
        )
    }

    static func playlist(_ dto: SSPlaylistSummary) -> Playlist {
        Playlist(
            id: dto.id.value,
            title: dto.name ?? "Playlist",
            trackCount: dto.songCount,
            durationSeconds: dto.duration.map(TimeInterval.init),
            artwork: artwork(coverArt: dto.coverArt),
            isSmart: false
        )
    }

    /// Cover-art references are the opaque `coverArt` string the server returns;
    /// the backend fires it back at `/rest/getCoverArt?id=<coverArt>`.
    static func artwork(coverArt: String?) -> ArtworkRef? {
        guard let coverArt, !coverArt.isEmpty else { return nil }
        return ArtworkRef(key: coverArt)
    }

    /// Best-effort codec from an audio MIME type. Subsonic servers emit these
    /// with reasonable consistency; when absent we fall back to `suffix`.
    static func codec(fromContentType type: String) -> String? {
        let trimmed = type.split(separator: ";").first.map(String.init) ?? type
        let lower = trimmed.lowercased()
        guard let slash = lower.firstIndex(of: "/") else { return nil }
        let sub = String(lower[lower.index(after: slash)...])
        switch sub {
        case "mpeg", "mp3": return "mp3"
        case "mp4", "m4a", "aac", "x-m4a": return "aac"
        case "flac", "x-flac": return "flac"
        case "ogg", "x-vorbis+ogg", "vorbis": return "vorbis"
        case "opus", "x-opus+ogg": return "opus"
        case "wav", "x-wav", "wave": return "wav"
        case "x-ms-wma": return "wma"
        default: return sub
        }
    }

    /// Parse Subsonic's ISO 8601 (`created`, `starred`) with and without
    /// fractional seconds.
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
