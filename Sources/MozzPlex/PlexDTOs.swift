import Foundation

// Decodable mirrors of Plex JSON (obtained by sending `Accept: application/json`).
// Server browse responses wrap everything in a `MediaContainer`; the plex.tv v2
// pin/resources endpoints return flat JSON / arrays. All fields optional so a
// sparse item still decodes.

// MARK: - Server (MediaContainer) responses

struct PlexContainerResponse: Decodable {
    let MediaContainer: PlexMediaContainer
}

struct PlexMediaContainer: Decodable {
    let size: Int?
    let totalSize: Int?
    let offset: Int?
    let machineIdentifier: String?
    let version: String?
    let friendlyName: String?
    let Directory: [PlexDirectory]?
    let Metadata: [PlexMetadata]?
}

struct PlexDirectory: Decodable {
    let key: String?
    let type: String?
    let title: String?
    let uuid: String?
}

struct PlexTag: Decodable {
    let tag: String?
}

/// External-identifier entry Plex attaches to items when `includeGuids=1` is
/// requested, e.g. `{"id": "mbid://<uuid>"}` (MusicBrainz agent) or the legacy
/// `com.plexapp.agents.musicbrainz://<uuid>?lang=en`.
struct PlexGuid: Decodable {
    let id: String?
}

struct PlexPart: Decodable {
    let key: String?
    let file: String?
    let size: Int64?
    let container: String?
    /// Per-part streams. Only `streamType == 4` (lyrics) is read here; audio
    /// streams are described by the parent `Media` entry instead.
    let Stream: [PlexStream]?
}

/// A media stream attached to a `Part`. Plex uses `streamType` 1 = video,
/// 2 = audio, 3 = subtitle, 4 = lyrics. A lyric stream's `key` is a
/// server-relative path (`/library/streams/5555`) that serves the `.lrc` (or
/// timed-JSON) body.
struct PlexStream: Decodable {
    let id: Int?
    let streamType: Int?
    let key: String?
    let format: String?
    let displayTitle: String?
}

struct PlexMedia: Decodable {
    let container: String?
    let audioCodec: String?
    let bitrate: Int?
    let audioChannels: Int?
    let Part: [PlexPart]?
}

struct PlexMetadata: Decodable {
    let ratingKey: String?
    let key: String?
    let type: String?
    let title: String?
    let titleSort: String?
    let parentRatingKey: String?
    let grandparentRatingKey: String?
    let parentTitle: String?
    let grandparentTitle: String?
    let leafCount: Int?
    let childCount: Int?
    let duration: Int?
    let year: Int?
    let index: Int?
    let parentIndex: Int?
    let thumb: String?
    let parentThumb: String?
    let grandparentThumb: String?
    let addedAt: Double?
    let userRating: Double?
    let Media: [PlexMedia]?
    let Genre: [PlexTag]?
    let Guid: [PlexGuid]?
}

// MARK: - plex.tv v2 auth/discovery

struct PlexPinResponse: Decodable {
    let id: Int
    let code: String
    let authToken: String?
}

struct PlexResource: Decodable {
    let name: String?
    /// Plex server machine id. The resource is the server; its `connections`
    /// are alternate addresses for that same machine.
    let clientIdentifier: String?
    let provides: String?
    let accessToken: String?
    let connections: [PlexConnectionDTO]?
}

/// The signed-in plex.tv account. `thumb` is an absolute plex.tv URL (with a
/// `?c=` cache-buster that changes when the user swaps their photo, so the URL
/// is re-fetched rather than cached forever).
struct PlexAccountUser: Decodable {
    let username: String?
    let title: String?
    let email: String?
    let thumb: String?
}

struct PlexConnectionDTO: Decodable {
    let uri: String?
    let address: String?
    let port: Int?
    let `protocol`: String?
    let local: Bool?
    let relay: Bool?
}
