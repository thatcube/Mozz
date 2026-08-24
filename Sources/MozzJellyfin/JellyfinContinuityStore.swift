import Foundation
import MozzContinuity
import MozzCore
import MozzNetworking

// MARK: - DTOs

/// Jellyfin's `DisplayPreferencesDto`.
///
/// Only `CustomPrefs` matters here; the rest is sent back unchanged because the
/// write is a whole-record POST, not a patch.
struct JFDisplayPreferencesDto: Codable {
    var Id: String?
    var Client: String?
    var ViewType: String?
    var SortBy: String?
    var SortOrder: String?
    var RememberIndexing: Bool?
    var RememberSorting: Bool?
    var PrimaryImageHeight: Int?
    var PrimaryImageWidth: Int?
    var ScrollDirection: String?
    var ShowBackdrop: Bool?
    var ShowSidebar: Bool?
    var CustomPrefs: [String: String]?
}

// MARK: - Store

/// Cross-device continuity backed by Jellyfin's per-user `DisplayPreferences`
/// key-value store (ADR-0010).
///
/// Jellyfin has no purpose-built endpoint for this. Its `NowPlayingQueue` is
/// in-memory on the session and dies with the connection, and it does not
/// persist a resume position for music at all — `Audio` inherits
/// `SupportsPositionTicksResume => false`, so `UserDataManager.UpdatePlayState`
/// zeroes the position before writing it. `CustomPrefs` is therefore the only
/// durable, per-user, client-writable place to put a checkpoint.
///
/// Two things make it a good fit despite being a general-purpose store:
/// - `CustomItemDisplayPreferences.Value` has **no length limit** (unlimited
///   TEXT), so the full queue is stored — no windowing, unlike Subsonic.
/// - A non-GUID `displayPreferencesId` is deterministically MD5-hashed by the
///   server, so a stable string key resolves to the same record every time.
///
/// The cursor and the queue are separate keys so the frequently-written cursor
/// does not drag the whole queue over the network every 20 seconds. They are
/// **not** atomic together, which is deliberate: the cursor records the queue's
/// hash, and a reader that finds a mismatch degrades to track + position rather
/// than following a dangling reference.
public struct JellyfinContinuityStore: ContinuityStore {
    /// Stable key; the server MD5-hashes non-GUID ids to a deterministic Guid.
    static let preferencesID = "mozz-continuity"
    /// `Client` is capped at 32 characters by the server.
    static let clientKey = "Mozz"
    static let cursorKey = "mozz.continuity.cursor"
    static let queueKey = "mozz.continuity.queue"

    private let client: HTTPClient
    private let userID: String
    private let fingerprint: ServerAccountFingerprint

    public init(client: HTTPClient, userID: String, fingerprint: ServerAccountFingerprint) {
        self.client = client
        self.userID = userID
        self.fingerprint = fingerprint
    }

    public var features: ContinuityFeatures {
        ContinuityFeatures(
            richCursor: true,
            storesQueue: true,
            deviceAttribution: true,
            truncatesQueue: false
        )
    }

    private var query: [URLQueryItem] {
        [
            URLQueryItem(name: "userId", value: userID),
            URLQueryItem(name: "client", value: Self.clientKey),
        ]
    }

    // MARK: Load

    public func load() async throws -> ContinuitySnapshot? {
        let dto: JFDisplayPreferencesDto
        do {
            dto = try await client.send(
                Endpoint(path: "DisplayPreferences/\(Self.preferencesID)", query: query),
                as: JFDisplayPreferencesDto.self
            )
        } catch MozzError.notFound {
            return nil
        }
        guard let prefs = dto.CustomPrefs,
              let cursorJSON = prefs[Self.cursorKey],
              let cursorData = cursorJSON.data(using: .utf8),
              let cursor = try? JSONDecoder().decode(ContinuityCursor.self, from: cursorData)
        else { return nil }

        var queue: ContinuityQueue?
        if let queueJSON = prefs[Self.queueKey],
           let queueData = queueJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ContinuityQueue.self, from: queueData),
           // The pair is only trustworthy when the hashes agree. A mismatch
           // means the two writes interleaved with another device's; the track
           // and position are still exact, so degrade rather than fail.
           decoded.queueHash == cursor.queueHash {
            queue = decoded
        }
        return ContinuitySnapshot(cursor: cursor, queue: queue)
    }

    // MARK: Save

    public func save(_ cursor: ContinuityCursor, queue: ContinuityQueue?) async throws {
        // Read-modify-write: the POST replaces the whole record, so anything
        // else living in this app's CustomPrefs must be preserved.
        var dto = (try? await client.send(
            Endpoint(path: "DisplayPreferences/\(Self.preferencesID)", query: query),
            as: JFDisplayPreferencesDto.self
        )) ?? JFDisplayPreferencesDto()

        var prefs = dto.CustomPrefs ?? [:]
        // Write the queue FIRST, so a cursor is never published pointing at a
        // queue that isn't there yet. The reverse order would make every
        // interleaved read degrade unnecessarily.
        if let queue, let data = try? JSONEncoder().encode(queue),
           let json = String(data: data, encoding: .utf8) {
            prefs[Self.queueKey] = json
        }
        if let data = try? JSONEncoder().encode(cursor),
           let json = String(data: data, encoding: .utf8) {
            prefs[Self.cursorKey] = json
        }

        dto.CustomPrefs = prefs
        dto.Id = dto.Id ?? Self.preferencesID
        dto.Client = dto.Client ?? Self.clientKey
        _ = try await client.send(try Endpoint.jsonPost(
            "DisplayPreferences/\(Self.preferencesID)",
            body: dto,
            query: query
        ))
    }
}
