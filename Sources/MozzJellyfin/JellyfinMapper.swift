import Foundation
import MozzCore

/// Pure DTO -> domain mapping. No I/O, so it is exhaustively unit-testable
/// against recorded fixtures.
enum JellyfinMapper {
    static let ticksPerSecond: Double = 10_000_000

    static func artist(_ item: JFBaseItem) -> Artist {
        Artist(
            id: item.Id,
            name: item.Name ?? "Unknown Artist",
            sortName: item.SortName,
            artwork: artwork(itemID: item.Id, tag: item.ImageTags?["Primary"]),
            genres: item.Genres ?? [],
            isFavorite: item.UserData?.IsFavorite ?? false
        )
    }

    static func album(_ item: JFBaseItem) -> Album {
        Album(
            id: item.Id,
            title: item.Name ?? "Unknown Album",
            sortTitle: item.SortName,
            artistName: item.AlbumArtist ?? item.AlbumArtists?.first?.Name ?? "Unknown Artist",
            artistID: item.AlbumArtists?.first?.Id,
            year: item.ProductionYear,
            artwork: artwork(itemID: item.Id, tag: item.ImageTags?["Primary"]),
            trackCount: item.ChildCount,
            genres: item.Genres ?? [],
            isFavorite: item.UserData?.IsFavorite ?? false,
            addedAt: date(item.DateCreated)
        )
    }

    static func track(_ item: JFBaseItem) -> Track {
        let source = item.MediaSources?.first
        let audio = source?.MediaStreams?.first(where: { $0.streamType == "Audio" })
        let bitrate = (audio?.BitRate ?? source?.Bitrate).map { $0 / 1000 }
        let format = AudioFormat(
            container: source?.Container,
            codec: audio?.Codec,
            bitrateKbps: bitrate,
            sampleRateHz: audio?.SampleRate,
            channels: audio?.Channels,
            bitDepth: audio?.BitDepth
        )
        let art = artwork(itemID: item.Id, tag: item.ImageTags?["Primary"])
            ?? artwork(itemID: item.AlbumId, tag: item.AlbumPrimaryImageTag)
        return Track(
            id: item.Id,
            title: item.Name ?? "Unknown",
            sortTitle: item.SortName,
            albumTitle: item.Album,
            albumID: item.AlbumId,
            artistName: item.ArtistItems?.first?.Name ?? item.Artists?.first ?? item.AlbumArtist ?? "Unknown Artist",
            artistID: item.ArtistItems?.first?.Id,
            albumArtistName: item.AlbumArtist,
            trackNumber: item.IndexNumber,
            discNumber: item.ParentIndexNumber,
            duration: item.RunTimeTicks.map { Double($0) / ticksPerSecond } ?? 0,
            format: format,
            fileSizeBytes: source?.Size,
            mediaKey: item.Id,
            artwork: art,
            genres: item.Genres ?? [],
            isFavorite: item.UserData?.IsFavorite ?? false,
            normalizationGainDB: item.NormalizationGain,
            addedAt: date(item.DateCreated)
        )
    }

    static func playlist(_ item: JFBaseItem) -> Playlist {
        Playlist(
            id: item.Id,
            title: item.Name ?? "Playlist",
            trackCount: item.ChildCount,
            durationSeconds: item.RunTimeTicks.map { Double($0) / ticksPerSecond },
            artwork: artwork(itemID: item.Id, tag: item.ImageTags?["Primary"]),
            isSmart: false
        )
    }

    /// Encodes an artwork reference as `itemId` or `itemId|tag`. The tag lets
    /// the CDN/browser cache bust correctly when art changes.
    static func artwork(itemID: String?, tag: String?) -> ArtworkRef? {
        guard let itemID else { return nil }
        if let tag { return ArtworkRef(key: "\(itemID)|\(tag)") }
        return ArtworkRef(key: itemID)
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
