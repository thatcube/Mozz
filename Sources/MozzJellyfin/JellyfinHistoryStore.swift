import Foundation
import MozzCore
import MozzHistory
import MozzNetworking

/// Cross-device listening history backed by Jellyfin's per-user
/// `DisplayPreferences` key-value store.
///
/// The same substrate as `JellyfinContinuityStore`, for the same reason: it is
/// the only durable, per-user, client-writable place a Jellyfin server offers,
/// and `CustomItemDisplayPreferences.Value` is unlimited TEXT.
///
/// **A separate preferences record, deliberately.** Continuity rewrites its
/// cursor every 15-30 seconds while music plays. History changes rarely. Sharing
/// one record would drag the entire history payload across the network on every
/// one of those cursor writes, because the write is a whole-record POST rather
/// than a patch. Two records keep the hot path small.
///
/// **One key per device, never a shared one.** `mozz.history.{deviceID}`. Two
/// devices writing a single key would overwrite each other, and there is no
/// compare-and-swap to prevent it. With a key each, every write is
/// last-writer-wins over history that device alone authored — a write it can
/// always safely make. Merging happens on read, where a G-Set union needs no
/// coordination at all (see `HistoryMerge`).
public struct JellyfinHistoryStore: HistoryStore {
    /// Stable key; the server MD5-hashes non-GUID ids to a deterministic Guid.
    static let preferencesID = "mozz-history"
    /// `Client` is capped at 32 characters by the server.
    static let clientKey = "Mozz"
    /// Prefix for this app's per-device slots, so foreign keys in the same
    /// record are left strictly alone.
    static let keyPrefix = "mozz.history."

    /// Byte budget for one device's batch.
    ///
    /// `Value` has no server-side limit, but every device's slot lives in the
    /// *same* record and the write is a whole-record POST — so the cost of a
    /// write scales with the total across all devices, not just this one's. At
    /// roughly 150 bytes an event this holds ~1,700 events, and the taste
    /// profile's 30-day half-life means older ones contribute very little
    /// anyway. A heavy listener's window will bind here rather than at 180 days;
    /// `HistoryMerge.window` keeps the newest events when it does.
    public static let batchByteBudget = 256 * 1024

    /// How long a device's slot survives without being rewritten.
    ///
    /// Twice the sync window, so a slot is only ever collected once everything
    /// it could possibly contain is already too old to affect the taste profile.
    /// Without this, a retired device's slot would sit in the record forever and
    /// be re-uploaded on every write by every other device.
    static let staleSlotSeconds: Int64 = Int64(2 * HistoryMerge.defaultWindowDays) * 86_400_000

    private let client: HTTPClient
    private let userID: String

    public init(client: HTTPClient, userID: String) {
        self.client = client
        self.userID = userID
    }

    public var maximumBatchBytes: Int { Self.batchByteBudget }

    private var query: [URLQueryItem] {
        [
            URLQueryItem(name: "userId", value: userID),
            URLQueryItem(name: "client", value: Self.clientKey),
        ]
    }

    // MARK: Load

    public func loadBatches() async throws -> [HistoryBatch] {
        let dto: JFDisplayPreferencesDto
        do {
            dto = try await client.send(
                Endpoint(path: "DisplayPreferences/\(Self.preferencesID)", query: query),
                as: JFDisplayPreferencesDto.self
            )
        } catch MozzError.notFound {
            // Nothing has ever been written. Not an error — this is what a first
            // sync from a fresh account looks like.
            return []
        }
        guard let prefs = dto.CustomPrefs else { return [] }

        return prefs
            .filter { $0.key.hasPrefix(Self.keyPrefix) }
            // One malformed or truncated slot must not cost the user every other
            // device's history, so a slot that fails to decode is skipped rather
            // than thrown.
            .compactMap { _, json -> HistoryBatch? in
                guard let data = json.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(HistoryBatch.self, from: data)
            }
            .sorted { $0.writtenAtMS < $1.writtenAtMS }
    }

    // MARK: Save

    public func save(_ batch: HistoryBatch) async throws {
        // Read-modify-write: the POST replaces the whole record, so every other
        // device's slot — and anything else living here — has to be carried
        // across untouched.
        var dto = (try? await client.send(
            Endpoint(path: "DisplayPreferences/\(Self.preferencesID)", query: query),
            as: JFDisplayPreferencesDto.self
        )) ?? JFDisplayPreferencesDto()

        var prefs = dto.CustomPrefs ?? [:]

        let encoder = HistoryMerge.makeEncoder()
        guard let data = try? encoder.encode(batch),
              let json = String(data: data, encoding: .utf8) else {
            throw MozzError.invalidResponse
        }
        prefs[Self.key(for: batch.deviceID)] = json

        Self.dropStaleSlots(from: &prefs, now: batch.writtenAtMS, keeping: batch.deviceID)

        dto.CustomPrefs = prefs
        dto.Id = dto.Id ?? Self.preferencesID
        dto.Client = dto.Client ?? Self.clientKey
        _ = try await client.send(try Endpoint.jsonPost(
            "DisplayPreferences/\(Self.preferencesID)",
            body: dto,
            query: query
        ))
    }

    // MARK: Rollups

    /// Rollups live in a **separate preferences record per year**.
    ///
    /// A finished year never changes again, so keeping it out of the record that
    /// holds the constantly-rewritten event batches means it is fetched and
    /// re-uploaded only while it is still the current year.
    static func rollupPreferencesID(year: Int) -> String { "mozz-rollup-\(year)" }
    static let rollupKeyPrefix = "mozz.rollup."

    public func loadRollups(year: Int) async throws -> [HistoryRollup] {
        let id = Self.rollupPreferencesID(year: year)
        let dto: JFDisplayPreferencesDto
        do {
            dto = try await client.send(
                Endpoint(path: "DisplayPreferences/\(id)", query: query),
                as: JFDisplayPreferencesDto.self
            )
        } catch MozzError.notFound {
            return []
        }
        guard let prefs = dto.CustomPrefs else { return [] }

        return prefs
            .filter { $0.key.hasPrefix(Self.rollupKeyPrefix) }
            .compactMap { _, json -> HistoryRollup? in
                guard let data = json.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(HistoryRollup.self, from: data)
            }
            .filter { $0.year == year }
    }

    public func save(_ rollup: HistoryRollup) async throws {
        let id = Self.rollupPreferencesID(year: rollup.year)
        var dto = (try? await client.send(
            Endpoint(path: "DisplayPreferences/\(id)", query: query),
            as: JFDisplayPreferencesDto.self
        )) ?? JFDisplayPreferencesDto()

        var prefs = dto.CustomPrefs ?? [:]
        guard let data = try? HistoryMerge.makeEncoder().encode(rollup),
              let json = String(data: data, encoding: .utf8) else {
            throw MozzError.invalidResponse
        }
        prefs["\(Self.rollupKeyPrefix)\(rollup.deviceID)"] = json

        dto.CustomPrefs = prefs
        dto.Id = dto.Id ?? id
        dto.Client = dto.Client ?? Self.clientKey
        _ = try await client.send(try Endpoint.jsonPost(
            "DisplayPreferences/\(id)",
            body: dto,
            query: query
        ))
    }

    // MARK: Helpers

    static func key(for deviceID: String) -> String { "\(keyPrefix)\(deviceID)" }

    /// Remove slots whose contents are entirely older than anything the sync
    /// window can use.
    ///
    /// This is the one place a device touches another device's slot, so the
    /// threshold is deliberately conservative: by the time a slot is collected,
    /// every event in it is at least twice the window old and already carries no
    /// weight. A device that returns after a long absence simply writes a fresh
    /// slot and loses nothing that mattered.
    ///
    /// Slots that cannot be parsed are LEFT ALONE. A batch written by a future
    /// version of Mozz would fail to decode here, and deleting it because this
    /// build cannot read it would destroy a newer client's history.
    static func dropStaleSlots(
        from prefs: inout [String: String],
        now: Int64,
        keeping ownDeviceID: String
    ) {
        let ownKey = key(for: ownDeviceID)
        for (key, json) in prefs where key.hasPrefix(keyPrefix) && key != ownKey {
            guard let data = json.data(using: .utf8),
                  let batch = try? JSONDecoder().decode(HistoryBatch.self, from: data)
            else { continue }
            if now - batch.writtenAtMS > staleSlotSeconds {
                prefs.removeValue(forKey: key)
            }
        }
    }
}
