#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import MozzCore

// MARK: - Portable listening history
//
// Continuity (ADR-0010) moves the *queue* between devices. It does not move the
// *history*, and history is the one thing no server can give back:
//
//   * Jellyfin, Plex and Subsonic all record a scrobble — a completed play.
//   * None of them record a **skip**, and none record a **partial** listen.
//   * `TasteProfile` weights those heavily and oppositely (completed +1.0,
//     skipped −0.6), so the signal that actually personalizes Mozz exists
//     nowhere but in the local `play_event` log.
//
// So an hour of listening on a second device is not merely unsynced, it is
// permanently lost, and the two devices' recommendations drift apart forever.
//
// WHY THIS NEEDS NO CONSENSUS
//
// ADR-0010 established that no available substrate offers compare-and-swap or
// atomic append, which is why continuity ownership had to be reduced to
// best-effort. History has none of that difficulty, because of one property:
//
//   **Play events are immutable facts, and are only ever added.**
//
// A set that only grows is a G-Set, the simplest CRDT there is. Union is
// idempotent, commutative and associative, so merges need no ordering, no
// locking and no arbitration — two devices that have seen the same events agree
// regardless of the order they saw them in, and a merge applied twice changes
// nothing. There are no tombstones because nothing is ever deleted.
//
// The only requirement the union imposes is a *stable identity per event*, so
// both sides can tell "the same event" from "a different event". That is what
// `HistoryEvent.uid` is, and why it is content-derived rather than a local row
// id: a local autoincrement means device A and device B both call their first
// event `1`.

// MARK: - Wire types

/// One immutable listening fact, in a form another platform can read.
///
/// Times are **integer milliseconds** throughout, matching `MozzContinuity`.
/// The local table stores seconds as `Double`, but floating point is not
/// canonical across languages, and these values feed a hash that a non-Apple
/// peer has to reproduce exactly.
public struct HistoryEvent: Codable, Sendable, Hashable, Identifiable {
    /// Content-derived, globally unique, and stable across devices — the
    /// identity the set union is taken on.
    public var uid: String
    /// Which device observed this. Part of the identity: the same track played
    /// at the same instant on two devices is genuinely two listening events.
    public var deviceID: String
    /// `"{serverId}:{remoteId}"` — the durable history key, built by
    /// `PlayEventStore.trackRef` and never split (a serverId may contain ':').
    public var trackRef: String
    /// `PlayEventKind` raw value: started, completed, skipped, liked, unliked, seek.
    public var kind: String
    public var createdAtMS: Int64
    /// Playback position when the event occurred.
    public var positionMS: Int64?
    /// Track duration, so a receiving device can weigh a partial listen without
    /// having the catalog row.
    public var durationMS: Int64?
    /// Where it was played from (album, playlist…), for future context-aware
    /// scoring. Not part of the identity — it is descriptive, not defining.
    public var context: String?
    public var contextID: String?

    public var id: String { uid }

    public init(
        uid: String,
        deviceID: String,
        trackRef: String,
        kind: String,
        createdAtMS: Int64,
        positionMS: Int64? = nil,
        durationMS: Int64? = nil,
        context: String? = nil,
        contextID: String? = nil
    ) {
        self.uid = uid
        self.deviceID = deviceID
        self.trackRef = trackRef
        self.kind = kind
        self.createdAtMS = createdAtMS
        self.positionMS = positionMS
        self.durationMS = durationMS
        self.context = context
        self.contextID = contextID
    }

    /// Build an event, deriving its uid from its defining fields.
    public init(
        deviceID: String,
        trackRef: String,
        kind: String,
        createdAtMS: Int64,
        positionMS: Int64? = nil,
        durationMS: Int64? = nil,
        context: String? = nil,
        contextID: String? = nil
    ) {
        self.init(
            uid: HistoryEvent.makeUID(
                deviceID: deviceID,
                trackRef: trackRef,
                kind: kind,
                createdAtMS: createdAtMS,
                positionMS: positionMS,
                durationMS: durationMS
            ),
            deviceID: deviceID,
            trackRef: trackRef,
            kind: kind,
            createdAtMS: createdAtMS,
            positionMS: positionMS,
            durationMS: durationMS,
            context: context,
            contextID: contextID
        )
    }

    // MARK: Identity

    /// The canonical byte encoding the uid hashes. Same discipline as
    /// `ContinuityQueueBuilder.canonicalBytes` — fields joined with `U+0001`,
    /// a version prefix, integer milliseconds, `nil` rendered as empty — so
    /// there is one encoding convention across the project rather than two.
    ///
    /// `context`/`contextID` are deliberately excluded: they describe an event
    /// without defining it, and including them would mean the same listen
    /// re-imported with richer context looked like a second listen.
    ///
    /// Public so another implementation can diff its intermediate bytes when a
    /// uid disagrees. The bytes are always where the difference is.
    public static func canonicalUIDBytes(
        deviceID: String,
        trackRef: String,
        kind: String,
        createdAtMS: Int64,
        positionMS: Int64?,
        durationMS: Int64?
    ) -> Data {
        let parts = [
            "h1",
            deviceID,
            trackRef,
            kind,
            String(createdAtMS),
            positionMS.map(String.init) ?? "",
            durationMS.map(String.init) ?? "",
        ]
        return Data(parts.joined(separator: "\u{1}").utf8)
    }

    /// SHA-256 of the canonical bytes, truncated to 128 bits and rendered as 32
    /// lowercase hex characters.
    ///
    /// Truncated because these ride in a payload written to the user's server on
    /// every sync, and a batch of a thousand events pays 32 KB for the second
    /// half of a digest that buys nothing: at any plausible library size the
    /// collision probability across 128 bits is vanishingly small, and a
    /// collision would merely deduplicate two events rather than corrupt
    /// anything.
    public static func makeUID(
        deviceID: String,
        trackRef: String,
        kind: String,
        createdAtMS: Int64,
        positionMS: Int64?,
        durationMS: Int64?
    ) -> String {
        let digest = SHA256.hash(data: canonicalUIDBytes(
            deviceID: deviceID,
            trackRef: trackRef,
            kind: kind,
            createdAtMS: createdAtMS,
            positionMS: positionMS,
            durationMS: durationMS
        ))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// A window of one device's history, as written to a per-server store.
///
/// Batches are **per device**, not one shared slot. Two devices writing to a
/// single slot would overwrite each other, and there is no compare-and-swap to
/// prevent it; with a slot each, every write is last-writer-wins over *that
/// device's own* history, which is a write it can always safely make because it
/// is the only author.
public struct HistoryBatch: Codable, Sendable, Hashable {
    /// Encoding version, so a future change can be read by old clients.
    public var version: Int
    public var deviceID: String
    /// Free-text label for diagnostics only.
    public var deviceName: String
    /// When this batch was written. Freshness only — never authority.
    public var writtenAtMS: Int64
    /// The oldest event this batch could contain, given its window. Lets a
    /// reader tell "this device has played nothing since" from "this device
    /// trimmed older events", which look identical from the events alone.
    public var windowStartMS: Int64
    public var events: [HistoryEvent]

    public init(
        version: Int = HistoryBatch.currentVersion,
        deviceID: String,
        deviceName: String = "",
        writtenAtMS: Int64,
        windowStartMS: Int64,
        events: [HistoryEvent]
    ) {
        self.version = version
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.writtenAtMS = writtenAtMS
        self.windowStartMS = windowStartMS
        self.events = events
    }

    public static let currentVersion = 1
}

// MARK: - Store

/// Per-server durable storage for history batches.
///
/// Mirrors `ContinuityStore`: the backends implement it, so this module stays
/// free of any transport. Jellyfin can hold these in `DisplayPreferences`
/// `CustomPrefs` (unbounded TEXT); Subsonic's `savePlayQueue` cannot carry them,
/// so a Subsonic-only user keeps history local until another channel exists.
public protocol HistoryStore: Sendable {
    /// Every device's batch, including this device's own (callers filter).
    func loadBatches() async throws -> [HistoryBatch]

    /// Write *this device's* batch, replacing its previous one. Never touches
    /// another device's slot.
    func save(_ batch: HistoryBatch) async throws

    /// Roughly how many bytes a batch may occupy, so the caller can size its
    /// window before serializing. Backends differ enormously here.
    var maximumBatchBytes: Int { get }
}
