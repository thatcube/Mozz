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
    let clientIdentifier: String?
    let provides: String?
    let accessToken: String?
    let connections: [PlexConnectionDTO]?
}

struct PlexConnectionDTO: Decodable {
    let uri: String?
    let address: String?
    let port: Int?
    let `protocol`: String?
    let local: Bool?
    let relay: Bool?
}
