import Foundation

// Decodable mirrors of the Subsonic / OpenSubsonic JSON we consume.
//
// Subsonic wraps EVERY response in a top-level `{"subsonic-response": {…}}`
// envelope. Crucially, errors arrive over **HTTP 200** with `status == "failed"`
// and an `error` object — never as a non-2xx status — so the envelope is decoded
// on every call and mapped to `MozzError` by ``SubsonicClient`` (see
// ``SubsonicResponseError``). Every field is optional so a failed or partial
// response still decodes rather than throwing an opaque decode error and hiding
// the server's actual error code/message.
//
// Property names match the server's camelCase keys verbatim (Subsonic uses
// camelCase: `albumList2`, `songCount`, `coverArt`), so CodingKeys boilerplate is
// only needed where a key collides with a Swift keyword (`type`, `public`).

// MARK: - Envelope

/// The `{"subsonic-response": {…}}` wrapper. `Payload` decodes the endpoint's
/// data keys (e.g. `albumList2`) from the SAME object the envelope metadata lives
/// in, so a decoded value carries both the status/type metadata and the payload.
struct SubsonicEnvelope<Payload: Decodable>: Decodable {
    let response: SubsonicResponseBody<Payload>

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

/// The body of a `subsonic-response`: shared metadata plus the endpoint payload,
/// both read from the same keyed container (payload keys are siblings of
/// `status`).
struct SubsonicResponseBody<Payload: Decodable>: Decodable {
    let status: String?
    let version: String?
    /// OpenSubsonic server product name, e.g. "navidrome", "gonic", "lms".
    let type: String?
    /// OpenSubsonic concrete server version (distinct from the Subsonic API
    /// `version`), e.g. "0.51.1".
    let serverVersion: String?
    /// OpenSubsonic handshake flag: present + true on OpenSubsonic servers.
    let openSubsonic: Bool?
    let error: SubsonicResponseError?
    let payload: Payload

    private enum MetaKeys: String, CodingKey {
        case status, version, type, serverVersion, openSubsonic, error
    }

    init(from decoder: Decoder) throws {
        let meta = try decoder.container(keyedBy: MetaKeys.self)
        status = try meta.decodeIfPresent(String.self, forKey: .status)
        version = try meta.decodeIfPresent(String.self, forKey: .version)
        type = try meta.decodeIfPresent(String.self, forKey: .type)
        serverVersion = try meta.decodeIfPresent(String.self, forKey: .serverVersion)
        openSubsonic = try meta.decodeIfPresent(Bool.self, forKey: .openSubsonic)
        error = try meta.decodeIfPresent(SubsonicResponseError.self, forKey: .error)
        // Decode the payload from the same object; its own CodingKeys pick the
        // sibling data keys (albumList2/album/artists/…).
        payload = try Payload(from: decoder)
    }

    var isFailed: Bool { status?.lowercased() == "failed" || error != nil }
}

struct SubsonicResponseError: Decodable {
    let code: Int?
    let message: String?
}

/// An empty payload for endpoints that return only status (ping, star, unstar,
/// setRating, scrobble).
struct SubsonicEmpty: Decodable {
    init(from decoder: Decoder) throws {}
    init() {}
}

// MARK: - Handshake / capabilities

struct SubsonicOpenExtensionsPayload: Decodable {
    let openSubsonicExtensions: [SubsonicExtensionDTO]?
}

struct SubsonicExtensionDTO: Decodable {
    let name: String?
    let versions: [Int]?
}

// MARK: - Music folders

struct SubsonicMusicFoldersPayload: Decodable {
    let musicFolders: SubsonicMusicFoldersDTO?
}

struct SubsonicMusicFoldersDTO: Decodable {
    let musicFolder: [SubsonicMusicFolderDTO]?
}

struct SubsonicMusicFolderDTO: Decodable {
    let id: SubsonicID?
    let name: String?
}

// MARK: - Core entities

/// A song/track — Subsonic's `Child` type (also used for playlist/search
/// entries). Fields cover OpenSubsonic extensions (musicBrainzId, genres,
/// replayGain, sortName, bitDepth) which are simply nil on classic servers.
struct SubsonicChild: Decodable {
    let id: SubsonicID?
    let parent: SubsonicID?
    let title: String?
    let album: String?
    let artist: String?
    let track: Int?
    let year: Int?
    let genre: String?
    let coverArt: SubsonicID?
    let size: Int64?
    let contentType: String?
    let suffix: String?
    let transcodedContentType: String?
    let transcodedSuffix: String?
    let duration: Int?
    let bitRate: Int?
    let path: String?
    let discNumber: Int?
    let created: String?
    let albumId: SubsonicID?
    let artistId: SubsonicID?
    let mediaType: String?
    let userRating: Int?
    let starred: String?
    let musicBrainzId: String?
    let sortName: String?
    let samplingRate: Int?
    let bitDepth: Int?
    let channelCount: Int?
    let genres: [SubsonicGenreDTO]?
    let replayGain: SubsonicReplayGainDTO?
    /// `type` — reserved word; classic Subsonic ("music"/"podcast"). Mapped.
    let itemType: String?

    enum CodingKeys: String, CodingKey {
        case id, parent, title, album, artist, track, year, genre, coverArt
        case size, contentType, suffix, transcodedContentType, transcodedSuffix
        case duration, bitRate, path, discNumber, created, albumId, artistId
        case mediaType, userRating, starred, musicBrainzId, sortName
        case samplingRate, bitDepth, channelCount, genres, replayGain
        case itemType = "type"
    }
}

struct SubsonicGenreDTO: Decodable {
    let name: String?
}

struct SubsonicReplayGainDTO: Decodable {
    let trackGain: Double?
    let albumGain: Double?
    let trackPeak: Double?
    let albumPeak: Double?
}

/// An album — Subsonic's `AlbumID3`. `song` is populated by `getAlbum`.
struct SubsonicAlbumID3: Decodable {
    let id: SubsonicID?
    let name: String?
    let artist: String?
    let artistId: SubsonicID?
    let coverArt: SubsonicID?
    let songCount: Int?
    let duration: Int?
    let playCount: Int64?
    let created: String?
    let starred: String?
    let year: Int?
    let genre: String?
    let musicBrainzId: String?
    let sortName: String?
    let genres: [SubsonicGenreDTO]?
    let song: [SubsonicChild]?
}

/// An artist — Subsonic's `ArtistID3`.
struct SubsonicArtistID3: Decodable {
    let id: SubsonicID?
    let name: String?
    let coverArt: SubsonicID?
    let albumCount: Int?
    let starred: String?
    let musicBrainzId: String?
    let sortName: String?
    let artistImageUrl: String?
}

/// A playlist header — `entry` populated by `getPlaylist`.
struct SubsonicPlaylistDTO: Decodable {
    let id: SubsonicID?
    let name: String?
    let comment: String?
    let owner: String?
    let songCount: Int?
    let duration: Int?
    let created: String?
    let changed: String?
    let coverArt: SubsonicID?
    /// `public` — reserved word. Mapped.
    let isPublic: Bool?
    let entry: [SubsonicChild]?

    enum CodingKeys: String, CodingKey {
        case id, name, comment, owner, songCount, duration, created, changed, coverArt, entry
        case isPublic = "public"
    }
}

// MARK: - Payload shells (one per endpoint)

struct SubsonicAlbumList2Payload: Decodable {
    let albumList2: SubsonicAlbumList2DTO?
}
struct SubsonicAlbumList2DTO: Decodable {
    let album: [SubsonicAlbumID3]?
}

struct SubsonicAlbumPayload: Decodable {
    let album: SubsonicAlbumID3?
}

struct SubsonicArtistsPayload: Decodable {
    let artists: SubsonicArtistsIndexDTO?
}
struct SubsonicArtistsIndexDTO: Decodable {
    let index: [SubsonicArtistIndexEntryDTO]?
}
struct SubsonicArtistIndexEntryDTO: Decodable {
    let name: String?
    let artist: [SubsonicArtistID3]?
}

struct SubsonicSearchResult3Payload: Decodable {
    let searchResult3: SubsonicSearchResult3DTO?
}
struct SubsonicSearchResult3DTO: Decodable {
    let artist: [SubsonicArtistID3]?
    let album: [SubsonicAlbumID3]?
    let song: [SubsonicChild]?
}

struct SubsonicPlaylistsPayload: Decodable {
    let playlists: SubsonicPlaylistsDTO?
}
struct SubsonicPlaylistsDTO: Decodable {
    let playlist: [SubsonicPlaylistDTO]?
}

struct SubsonicPlaylistPayload: Decodable {
    let playlist: SubsonicPlaylistDTO?
}

// MARK: - Lenient opaque id

/// A Subsonic id that decodes from either a JSON string or number. Navidrome ids
/// are opaque strings (e.g. "al-3f2…"); some servers (Gonic, classic Subsonic)
/// use integers. Decoding both keeps ids opaque without assuming a type.
struct SubsonicID: Decodable, Hashable {
    let value: String

    init(_ value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            value = s
        } else if let i = try? container.decode(Int64.self) {
            value = String(i)
        } else if let d = try? container.decode(Double.self) {
            // Avoid a trailing ".0" for integral doubles.
            value = d == d.rounded() ? String(Int64(d)) : String(d)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Subsonic id was neither string nor number")
            )
        }
    }
}
