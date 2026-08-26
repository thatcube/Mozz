import Foundation
import GRDB
import MozzCore

/// The core's home for playback settings — the graphic EQ and loudness
/// normalization. A single row (`id = 1`) holds the one shared definition that
/// every shell reads and writes through the command Facade, replacing the
/// per-platform preference stores that could never sync and drifted apart.
///
/// Reads return normalized defaults when nothing is stored; writes normalize
/// through ``PlaybackSettings`` (clamping every value) before persisting, so a
/// corrupt row or an out-of-range caller can never yield invalid settings.
public struct PlaybackSettingsStore: Sendable {
    private let database: MusicDatabase

    public init(_ database: MusicDatabase) { self.database = database }

    /// The stored settings, or ``PlaybackSettings/defaults`` when nothing has
    /// been persisted yet. A corrupt EQ blob degrades to the default curve via
    /// ``EqualizerSettings`` decoding rather than throwing.
    public func load() async throws -> PlaybackSettings {
        try await database.read { db in
            guard let record = try PlaybackSettingsRecord.fetchOne(db, key: PlaybackSettingsRecord.singletonID) else {
                return .defaults
            }
            return record.settings
        }
    }

    /// Persist `settings` (normalized on the way in) and return exactly what was
    /// stored, so a caller sees the clamped/normalized result of its write.
    @discardableResult
    public func save(_ settings: PlaybackSettings) async throws -> PlaybackSettings {
        // Re-construct through the value type's initializer so the persisted row
        // is always the normalized form, regardless of how the caller built it.
        let normalized = PlaybackSettings(equalizerEnabled: settings.equalizerEnabled,
                                          equalizer: settings.equalizer,
                                          replayGainMode: settings.replayGainMode,
                                          replayGainPreampDB: settings.replayGainPreampDB)
        try await database.write { db in
            try PlaybackSettingsRecord(normalized).save(db)
        }
        return normalized
    }
}

/// GRDB row for the single-row `playback_settings` table. The EQ curve is stored
/// as the `{gains, preampDB}` JSON both shells already used, so stored blobs stay
/// mutually readable and no encoding semantics change.
struct PlaybackSettingsRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "playback_settings"
    static let singletonID: Int64 = 1

    var id: Int64
    var equalizerEnabled: Bool
    var equalizer: String
    var replayGainMode: String
    var replayGainPreampDB: Double

    init(_ settings: PlaybackSettings) {
        self.id = Self.singletonID
        self.equalizerEnabled = settings.equalizerEnabled
        self.equalizer = Self.encodeEqualizer(settings.equalizer)
        self.replayGainMode = settings.replayGainMode.rawValue
        self.replayGainPreampDB = settings.replayGainPreampDB
    }

    /// Rebuild the value type, decoding through its validating initializers so a
    /// tampered or future-format row can never bypass clamping.
    var settings: PlaybackSettings {
        PlaybackSettings(equalizerEnabled: equalizerEnabled,
                         equalizer: Self.decodeEqualizer(equalizer),
                         replayGainMode: ReplayGainMode.parse(replayGainMode),
                         replayGainPreampDB: replayGainPreampDB)
    }

    private static func encodeEqualizer(_ eq: EqualizerSettings) -> String {
        guard let data = try? JSONEncoder().encode(eq),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private static func decodeEqualizer(_ json: String) -> EqualizerSettings {
        guard let data = json.data(using: .utf8),
              let eq = try? JSONDecoder().decode(EqualizerSettings.self, from: data) else { return .flat }
        return eq
    }
}
