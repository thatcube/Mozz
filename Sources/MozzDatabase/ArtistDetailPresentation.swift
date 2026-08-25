import Foundation

public enum ArtistDetailPresentation {
    /// Artists frequently have no art of their own. Falling back to the first
    /// album cover with artwork gives every client the same colorful hero.
    public static func heroArtworkKey(artist: ArtistRecord, albums: [AlbumRecord]) -> String? {
        artist.artworkKey ?? albums.first(where: { $0.artworkKey != nil })?.artworkKey
    }
}
