import Foundation

// MARK: - Envelope
//
// Every Subsonic/OpenSubsonic call returns ONE JSON shape:
// `{"subsonic-response": {status, version, type, serverVersion, openSubsonic,
// error?, <one-of-many-payload-keys>?}}`. Rather than modeling this generically
// (which would need a type parameter threaded through every call site for a
// payload key that differs per endpoint), `SubsonicResponseDTO` simply lists
// every endpoint's payload as an optional sibling field. Each call site reads
// the one field it expects; unused fields cost nothing (absent keys decode to
// `nil`). This mirrors how most hand-rolled Subsonic clients model the API and
// keeps `SubsonicClient` decoding logic in one place.

struct SubsonicEnvelopeDTO: Decodable {
    let response: SubsonicResponseDTO
    private enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

struct SubsonicResponseDTO: Decodable {
    let status: String
    let version: String?
    /// OpenSubsonic: the server's self-reported product name, e.g. "Navidrome".
    let type: String?
    /// OpenSubsonic: the server's own version string (distinct from `version`,
    /// which is the Subsonic *protocol* version).
    let serverVersion: String?
    /// OpenSubsonic: `true` if the server implements the OpenSubsonic API.
    /// Absent (nil) on a classic Subsonic server — treated as `false`.
    let openSubsonic: Bool?
    let error: SubsonicErrorDTO?

    // Payloads, one per endpoint family. All optional; only the field for the
    // endpoint actually called will be non-nil.
    let artists: ArtistsID3DTO?
    let albumList2: AlbumList2DTO?
    let album: AlbumID3WithSongsDTO?
    let searchResult3: SearchResult3DTO?
    let musicFolders: MusicFoldersDTO?
    let openSubsonicExtensions: [OpenSubsonicExtensionDTO]?
    let playlists: PlaylistsDTO?
    let playlist: PlaylistWithSongsDTO?
}

struct SubsonicErrorDTO: Decodable {
    let code: Int
    let message: String?
    let helpUrl: String?
}

// MARK: - ID3 (artist/album org) responses

struct ArtistsID3DTO: Decodable {
    let ignoredArticles: String?
    let index: [ArtistIndexDTO]?
}

struct ArtistIndexDTO: Decodable {
    let name: String
    let artist: [ArtistID3DTO]?
}

struct ArtistID3DTO: Decodable {
    let id: String
    let name: String
    let coverArt: String?
    let artistImageUrl: String?
    let albumCount: Int?
    let starred: String?
    /// OpenSubsonic.
    let musicBrainzId: String?
    /// OpenSubsonic.
    let sortName: String?
}

struct AlbumList2DTO: Decodable {
    let album: [AlbumID3DTO]?
}

struct AlbumID3DTO: Decodable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let created: String?
    let year: Int?
    let genre: String?
    /// OpenSubsonic: structured genre list; prefer over the single `genre`
    /// string when present.
    let genres: [GenreDTO]?
    let starred: String?
    let userRating: Int?
    /// OpenSubsonic.
    let musicBrainzId: String?
}

/// `getAlbum` response: an `AlbumID3` plus its ordered `song` list.
struct AlbumID3WithSongsDTO: Decodable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let created: String?
    let year: Int?
    let genre: String?
    let genres: [GenreDTO]?
    let starred: String?
    let userRating: Int?
    let musicBrainzId: String?
    let song: [ChildDTO]?
}

struct GenreDTO: Decodable {
    let name: String
}

/// A song ("Child" in the Subsonic schema — the same shape is reused for
/// directory entries, playlist entries and search results).
struct ChildDTO: Decodable {
    let id: String
    let parent: String?
    let title: String
    let album: String?
    let albumId: String?
    let artist: String?
    let artistId: String?
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let genre: String?
    let genres: [GenreDTO]?
    let coverArt: String?
    let size: Int64?
    let contentType: String?
    let suffix: String?
    let duration: Int?
    let bitRate: Int?
    let bitDepth: Int?
    let samplingRate: Int?
    let channelCount: Int?
    let path: String?
    let created: String?
    let starred: String?
    let userRating: Int?
    /// OpenSubsonic.
    let musicBrainzId: String?
    /// OpenSubsonic.
    let replayGain: ReplayGainDTO?
}

struct ReplayGainDTO: Decodable {
    let trackGain: Double?
    let albumGain: Double?
    let trackPeak: Double?
    let albumPeak: Double?
    let baseGain: Double?
}

struct SearchResult3DTO: Decodable {
    let artist: [ArtistID3DTO]?
    let album: [AlbumID3DTO]?
    let song: [ChildDTO]?
}

struct MusicFoldersDTO: Decodable {
    let musicFolder: [MusicFolderDTO]?
}

struct MusicFolderDTO: Decodable {
    let id: Int
    let name: String?
}

struct OpenSubsonicExtensionDTO: Decodable {
    let name: String
    let versions: [Int]
}

struct PlaylistsDTO: Decodable {
    let playlist: [PlaylistDTO]?
}

struct PlaylistDTO: Decodable {
    let id: String
    let name: String
    let songCount: Int?
    let duration: Int?
    let coverArt: String?
}

struct PlaylistWithSongsDTO: Decodable {
    let id: String
    let name: String
    let songCount: Int?
    let duration: Int?
    let coverArt: String?
    let entry: [ChildDTO]?
}
