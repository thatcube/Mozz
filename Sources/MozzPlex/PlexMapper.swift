import Foundation
import MozzCore

/// Pure Plex DTO -> domain mapping. Plex encodes the artist/album/track
/// hierarchy through `parent*`/`grandparent*` fields; we denormalize those into
/// the flat domain models the database stores.
enum PlexMapper {
    /// Plex durations are milliseconds; bitrates are already kbps.
    static func track(_ meta: PlexMetadata) -> Track? {
        guard let id = meta.ratingKey else { return nil }
        let media = meta.Media?.first
        let part = media?.Part?.first
        let format = AudioFormat(
            container: part?.container ?? media?.container,
            codec: media?.audioCodec,
            bitrateKbps: media?.bitrate,
            sampleRateHz: nil,
            channels: media?.audioChannels,
            bitDepth: nil
        )
        return Track(
            id: id,
            title: meta.title ?? "Unknown",
            sortTitle: meta.titleSort,
            albumTitle: meta.parentTitle,
            albumID: meta.parentRatingKey,
            artistName: meta.grandparentTitle ?? "Unknown Artist",
            artistID: meta.grandparentRatingKey,
            albumArtistName: meta.grandparentTitle,
            trackNumber: meta.index,
            discNumber: meta.parentIndex,
            duration: Double(meta.duration ?? 0) / 1000,
            format: format,
            fileSizeBytes: part?.size,
            mediaKey: part?.key,
            artwork: artwork(meta.thumb ?? meta.parentThumb ?? meta.grandparentThumb),
            genres: tags(meta.Genre),
            isFavorite: false,
            normalizationGainDB: nil,
            addedAt: date(meta.addedAt)
        )
    }

    static func album(_ meta: PlexMetadata) -> Album? {
        guard let id = meta.ratingKey else { return nil }
        return Album(
            id: id,
            title: meta.title ?? "Unknown Album",
            sortTitle: meta.titleSort,
            artistName: meta.parentTitle ?? "Unknown Artist",
            artistID: meta.parentRatingKey,
            year: meta.year,
            artwork: artwork(meta.thumb ?? meta.parentThumb),
            trackCount: meta.leafCount ?? meta.childCount,
            genres: tags(meta.Genre),
            isFavorite: false,
            addedAt: date(meta.addedAt)
        )
    }

    static func artist(_ meta: PlexMetadata) -> Artist? {
        guard let id = meta.ratingKey else { return nil }
        return Artist(
            id: id,
            name: meta.title ?? "Unknown Artist",
            sortName: meta.titleSort,
            artwork: artwork(meta.thumb),
            albumCount: meta.childCount,
            genres: tags(meta.Genre),
            isFavorite: false
        )
    }

    static func playlist(_ meta: PlexMetadata) -> Playlist? {
        guard let id = meta.ratingKey else { return nil }
        return Playlist(
            id: id,
            title: meta.title ?? "Playlist",
            trackCount: meta.leafCount,
            durationSeconds: meta.duration.map { Double($0) / 1000 },
            artwork: artwork(meta.thumb),
            isSmart: false
        )
    }

    /// The artwork reference for Plex is the raw `thumb` path (token-free), e.g.
    /// `/library/metadata/123/thumb/1700000000`.
    static func artwork(_ thumb: String?) -> ArtworkRef? {
        guard let thumb, !thumb.isEmpty else { return nil }
        return ArtworkRef(key: thumb)
    }

    static func tags(_ genres: [PlexTag]?) -> [String] {
        (genres ?? []).compactMap { $0.tag }
    }

    static func date(_ epoch: Double?) -> Date? {
        guard let epoch else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
}
