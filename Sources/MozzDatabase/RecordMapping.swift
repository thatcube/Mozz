import Foundation
import MozzCore

/// Maps stored records back to the pure domain models the rest of the app (the
/// player, downloads, and providers) speaks. The database is the source of
/// truth, so these conversions are how the UI and playback layers consume it.
public extension TrackRecord {
    func toDomain() -> Track {
        Track(
            id: remoteId,
            title: title,
            sortTitle: sortTitle,
            albumTitle: albumTitle,
            albumID: albumRemoteId,
            artistName: artistName,
            artistID: artistRemoteId,
            albumArtistName: albumArtistName,
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: duration,
            format: AudioFormat(
                container: container,
                codec: codec,
                bitrateKbps: bitrateKbps,
                sampleRateHz: sampleRateHz,
                channels: channels,
                bitDepth: bitDepth
            ),
            fileSizeBytes: fileSizeBytes,
            mediaKey: mediaKey,
            artwork: artworkKey.map(ArtworkRef.init(key:)),
            genres: genres,
            isFavorite: isFavorite,
            normalizationGainDB: normalizationGainDB,
            addedAt: addedAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

public extension AlbumRecord {
    func toDomain() -> Album {
        Album(
            id: remoteId,
            title: title,
            sortTitle: sortTitle,
            artistName: artistName,
            artistID: artistRemoteId,
            year: year,
            artwork: artworkKey.map(ArtworkRef.init(key:)),
            trackCount: trackCount,
            genres: genres,
            isFavorite: isFavorite,
            addedAt: addedAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

public extension ArtistRecord {
    func toDomain() -> Artist {
        Artist(
            id: remoteId,
            name: name,
            sortName: sortName,
            artwork: artworkKey.map(ArtworkRef.init(key:)),
            albumCount: albumCount,
            genres: genres,
            isFavorite: isFavorite
        )
    }
}

public extension PlaylistRecord {
    func toDomain() -> Playlist {
        Playlist(
            id: remoteId,
            title: title,
            trackCount: trackCount,
            durationSeconds: durationSeconds,
            artwork: artworkKey.map(ArtworkRef.init(key:)),
            isSmart: isSmart
        )
    }
}
