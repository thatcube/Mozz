import Foundation

// Decodable mirrors of the OpenSubsonic JSON we consume.
//
// Every response is wrapped in a `subsonic-response` object with a
// `status` string ("ok" / "failed"). ERRORS ARRIVE OVER HTTP 200 — never as
// a non-2xx status — so decoding the envelope FIRST (and refusing to touch
// payload on `failed`) is the only correct way to detect a rejected request.
// The client's `send<T:>` funnels every JSON call through the envelope so no
// per-endpoint code can accidentally skip that check.

struct SSEnvelope<Payload: Decodable>: Decodable {
    let response: SSResponse<Payload>
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

struct SSResponse<Payload: Decodable>: Decodable {
    let status: String
    let version: String?
    /// The server product string (e.g. "navidrome"). OpenSubsonic servers set
    /// this; classic Subsonic servers omit it, so we treat missing as "unknown".
    let type: String?
    /// The product-specific version string (e.g. "0.51.1"). Distinct from the
    /// Subsonic protocol `version` above.
    let serverVersion: String?
    /// Populated when `status == "failed"`.
    let error: SSError?
    /// The typed payload. Optional because failed responses omit it.
    let payload: Payload?

    private enum FixedKeys: String, CodingKey {
        case status, version, type, serverVersion, error
    }

    /// Custom decoding: pull the fixed metadata keys, then look for the payload
    /// under a caller-provided key. Payload key is the untyped part of the
    /// envelope (e.g. `album`, `song`, `musicFolders`) and varies per endpoint.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        self.status = (try? container.decode(String.self, forKey: .init("status"))) ?? "unknown"
        self.version = try? container.decode(String.self, forKey: .init("version"))
        self.type = try? container.decode(String.self, forKey: .init("type"))
        self.serverVersion = try? container.decode(String.self, forKey: .init("serverVersion"))
        self.error = try? container.decode(SSError.self, forKey: .init("error"))
        // The payload key is provided by the caller via a decoding userInfo entry.
        if let key = decoder.userInfo[.subsonicPayloadKey] as? String {
            self.payload = try? container.decode(Payload.self, forKey: .init(key))
        } else {
            self.payload = nil
        }
    }
}

struct SSError: Decodable, Equatable {
    let code: Int
    let message: String?
}

/// Dynamic coding key so the envelope can pull an arbitrary payload key.
struct DynamicKey: CodingKey {
    var stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    init(_ s: String) { self.stringValue = s }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

extension CodingUserInfoKey {
    /// Which key inside `subsonic-response` holds this endpoint's typed payload.
    static let subsonicPayloadKey = CodingUserInfoKey(rawValue: "subsonic.payloadKey")!
}

// MARK: - Payloads

struct SSPing: Decodable {}

struct SSOpenSubsonicExtensions: Decodable {
    let openSubsonicExtensions: [SSExtension]?
}

struct SSExtension: Decodable {
    let name: String
    let versions: [Int]?
}

struct SSMusicFolders: Decodable {
    let musicFolder: [SSMusicFolder]?
}

struct SSMusicFolder: Decodable {
    let id: SSAnyID
    let name: String?
}

struct SSAlbumList2: Decodable {
    let album: [SSAlbumSummary]?
}

/// The item shape returned by `getAlbumList2` — a lightweight album row.
/// The full track listing arrives from `getAlbum(id)`.
struct SSAlbumSummary: Decodable {
    let id: SSAnyID
    let name: String?
    let artist: String?
    let artistId: SSAnyID?
    let coverArt: String?
    let songCount: Int?
    let year: Int?
    let genre: String?
    let created: String?
    let starred: String?
    let musicBrainzId: String?
}

struct SSAlbumWithSongs: Decodable {
    let id: SSAnyID
    let name: String?
    let artist: String?
    let artistId: SSAnyID?
    let coverArt: String?
    let songCount: Int?
    let year: Int?
    let genre: String?
    let created: String?
    let starred: String?
    let musicBrainzId: String?
    let song: [SSSong]?
}

struct SSSong: Decodable {
    let id: SSAnyID
    let title: String?
    let album: String?
    let albumId: SSAnyID?
    let artist: String?
    let artistId: SSAnyID?
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let genre: String?
    let coverArt: String?
    let size: Int64?
    let contentType: String?
    let suffix: String?
    let transcodedSuffix: String?
    let duration: Int?
    let bitRate: Int?
    let samplingRate: Int?
    let channelCount: Int?
    let bitDepth: Int?
    let path: String?
    let starred: String?
    let userRating: Int?           // 1-5 stars
    let averageRating: Double?
    let musicBrainzId: String?
    /// OpenSubsonic ReplayGain block (nullable — many servers omit it).
    let replayGain: SSReplayGain?
}

struct SSReplayGain: Decodable {
    let trackGain: Double?
    let albumGain: Double?
    let trackPeak: Double?
    let albumPeak: Double?
}

struct SSArtistsIndex: Decodable {
    let index: [SSIndex]?
    let ignoredArticles: String?
}

struct SSIndex: Decodable {
    let name: String?
    let artist: [SSArtistRef]?
}

struct SSArtistRef: Decodable {
    let id: SSAnyID
    let name: String?
    let coverArt: String?
    let albumCount: Int?
    let starred: String?
    let musicBrainzId: String?
}

struct SSPlaylists: Decodable {
    let playlist: [SSPlaylistSummary]?
}

struct SSPlaylistSummary: Decodable {
    let id: SSAnyID
    let name: String?
    let songCount: Int?
    let duration: Int?
    let coverArt: String?
}

struct SSPlaylistDetail: Decodable {
    let id: SSAnyID
    let name: String?
    let songCount: Int?
    let duration: Int?
    let coverArt: String?
    let entry: [SSSong]?
}

/// Subsonic ids come as either strings ("al-123") or numbers (12345). Decode
/// both into a single canonical string form; this dodges the classic
/// `Expected String but got Int` crash on servers that emit numeric ids while
/// still round-tripping the id byte-for-byte.
struct SSAnyID: Decodable, Equatable, Hashable, Sendable {
    let value: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int64.self) {
            value = String(int)
        } else {
            throw DecodingError.typeMismatch(String.self, .init(
                codingPath: decoder.codingPath,
                debugDescription: "Subsonic id was neither String nor Int"))
        }
    }
    init(_ raw: String) { self.value = raw }
}
