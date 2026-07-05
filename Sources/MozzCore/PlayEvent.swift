import Foundation

/// The kind of a listening-history event appended to the on-device play log.
///
/// The distinction that matters for recommendations is `completed` (a track
/// played to its natural end — a positive signal) vs `skipped` (the user moved
/// on before it ended — a negative signal). The coarse `PlaybackState`
/// (playing/paused/stopped) deliberately can't capture this, which is why
/// history is a separate, append-only log.
public enum PlayEventKind: String, Sendable, Hashable, Codable {
    case started
    case completed
    case skipped
    case seek
    case liked
    case unliked
}

/// A single listening-history event emitted by the playback engine and appended
/// (never mutated) to the on-device `play_event` log — fuel for play counts,
/// "recently played", scrobbling, and the recommender.
///
/// The engine is server-agnostic, so this carries the track's *remote* id
/// (`trackID` = `Track.id`). The composition root pairs it with the active
/// server id to form the durable `track_ref` = `"{serverID}:{remoteID}"`, which
/// is the key history is stored under so it survives catalog prunes.
public struct PlayEvent: Sendable, Hashable {
    public var trackID: String
    public var kind: PlayEventKind
    /// Playback position when the event fired (for started/skipped/seek).
    public var positionSeconds: TimeInterval?
    /// Track length at play time (lets consumers compute a completion ratio).
    public var durationSeconds: TimeInterval?
    /// Where playback was initiated from (album/playlist/search/…), when known.
    public var context: String?
    public var contextID: String?
    public var createdAt: Date

    public init(
        trackID: String,
        kind: PlayEventKind,
        positionSeconds: TimeInterval? = nil,
        durationSeconds: TimeInterval? = nil,
        context: String? = nil,
        contextID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.trackID = trackID
        self.kind = kind
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.context = context
        self.contextID = contextID
        self.createdAt = createdAt
    }
}
