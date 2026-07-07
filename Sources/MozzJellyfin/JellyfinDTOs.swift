import Foundation

// Decodable mirrors of the Jellyfin JSON we consume. Property names match the
// server's PascalCase keys verbatim (so no CodingKeys boilerplate); everything
// optional so a partial/older server response still decodes rather than failing
// the whole page.

struct JFItemsResponse: Decodable {
    let Items: [JFBaseItem]?
    let TotalRecordCount: Int?
}

struct JFNameGuidPair: Decodable {
    let Name: String?
    let Id: String?
}

struct JFUserData: Decodable {
    let IsFavorite: Bool?
}

struct JFMediaStream: Decodable {
    // `Type` is reserved as a Swift member name, so map it explicitly.
    let streamType: String?
    let Codec: String?
    let BitRate: Int?
    let SampleRate: Int?
    let Channels: Int?
    let BitDepth: Int?

    enum CodingKeys: String, CodingKey {
        case streamType = "Type"
        case Codec, BitRate, SampleRate, Channels, BitDepth
    }
}

struct JFMediaSource: Decodable {
    let Container: String?
    let Size: Int64?
    let Bitrate: Int?
    let MediaStreams: [JFMediaStream]?
}

struct JFBaseItem: Decodable {
    let Id: String
    let Name: String?
    let SortName: String?
    let itemType: String?
    let AlbumArtist: String?
    let AlbumArtists: [JFNameGuidPair]?
    let ArtistItems: [JFNameGuidPair]?
    let Artists: [String]?
    let Album: String?
    let AlbumId: String?
    let ProductionYear: Int?
    let IndexNumber: Int?
    let ParentIndexNumber: Int?
    let RunTimeTicks: Int64?
    let Genres: [String]?
    let ImageTags: [String: String]?
    let AlbumPrimaryImageTag: String?
    let ChildCount: Int?
    let UserData: JFUserData?
    let MediaSources: [JFMediaSource]?
    let NormalizationGain: Double?
    let DateCreated: String?
    /// External ids Jellyfin exposes when `Fields=ProviderIds` is requested, e.g.
    /// `MusicBrainzTrack` (recording), `MusicBrainzArtist`, `MusicBrainzAlbum`.
    let ProviderIds: [String: String]?

    enum CodingKeys: String, CodingKey {
        case itemType = "Type"
        case Id, Name, SortName, AlbumArtist, AlbumArtists, ArtistItems, Artists
        case Album, AlbumId, ProductionYear, IndexNumber, ParentIndexNumber
        case RunTimeTicks, Genres, ImageTags, AlbumPrimaryImageTag, ChildCount
        case UserData, MediaSources, NormalizationGain, DateCreated, ProviderIds
    }
}

struct JFSystemInfoPublic: Decodable {
    let Version: String?
    let ServerName: String?
    let Id: String?
}

/// Serves both `QuickConnect/Initiate` (Secret+Code) and `QuickConnect/Connect`
/// (Authenticated) responses; unused fields simply stay nil.
struct JFQuickConnectResult: Decodable {
    let Secret: String?
    let Code: String?
    let Authenticated: Bool?
}

struct JFUser: Decodable {
    let Id: String?
    let Name: String?
}

struct JFAuthenticationResult: Decodable {
    let AccessToken: String?
    let ServerId: String?
    let User: JFUser?
}
