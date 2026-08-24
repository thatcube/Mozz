import Foundation
import MozzCore

// MARK: - Identity

/// Identifies *a server plus the account on it* — the scope within which a
/// provider track id is meaningful.
///
/// This deliberately replaces the old `"\(kind)-\(baseURL)"` server id for
/// continuity purposes. That form is derived from the URL used to reach the
/// server, so the same machine reached at `http://192.168.1.5:8096` on the LAN
/// and `https://music.example.com` from outside produces two different ids —
/// which would silently break correlation for the exact "listening out, then
/// come home" case this feature exists to serve.
///
/// `serverID` comes from the server's own identity where the protocol has one
/// (Jellyfin `System/Info/Public.Id`, Plex `machineIdentifier`). Generic
/// Subsonic has no server UUID at all, so it falls back to the configured
/// profile and makes no cross-URL correlation claim — see
/// ``isComparableAcross(_:)``.
public struct ServerAccountFingerprint: Codable, Sendable, Hashable {
    public var backend: BackendKind
    /// The server's own stable id, or `""` when the protocol doesn't expose one.
    public var serverID: String
    /// The account the checkpoint belongs to (Jellyfin user id, Plex account id,
    /// Subsonic username).
    public var accountID: String

    public init(backend: BackendKind, serverID: String, accountID: String) {
        self.backend = backend
        self.serverID = serverID
        self.accountID = accountID
    }

    /// Whether two fingerprints can be *meaningfully* compared.
    ///
    /// False when either side lacks a real server id (generic Subsonic), because
    /// then a mismatch tells us nothing — it may just be a different URL for the
    /// same machine. Callers must treat "not comparable" as "don't reject",
    /// never as "reject".
    public func isComparableAcross(_ other: ServerAccountFingerprint) -> Bool {
        !serverID.isEmpty && !other.serverID.isEmpty
    }
}

/// A track reference that is meaningful outside the device that wrote it.
///
/// A bare `Track.id` is only unique *within* one server, which is why the local
/// database keys catalog rows on `(serverId, remoteId)`. A locator carries the
/// same qualification onto the wire.
public struct TrackLocator: Codable, Sendable, Hashable {
    public var server: ServerAccountFingerprint
    /// The provider id — equal to `Track.id` within that server.
    public var remoteID: String

    public init(server: ServerAccountFingerprint, remoteID: String) {
        self.server = server
        self.remoteID = remoteID
    }
}

// MARK: - Playback state

/// Coarse transport state as stored in a checkpoint.
///
/// Deliberately separate from `MozzPlayback`'s richer status: this module must
/// not depend on the playback engine (see the module note in `Package.swift`),
/// and a wire format should not move whenever an internal enum does.
public enum ContinuityPlaybackState: String, Codable, Sendable, Hashable {
    case playing
    case paused
    case stopped
}

/// Repeat mode as stored in a checkpoint.
///
/// A local copy of the playback engine's `RepeatMode` on purpose: `RepeatMode`
/// lives in `MozzPlayback`, and importing that here would invert the dependency
/// this module was created to keep clean. `MozzApp` maps between the two.
public enum ContinuityRepeatMode: String, Codable, Sendable, Hashable {
    case off
    case one
    case all
}

/// Where a queue came from, so a device that cannot read the queue verbatim can
/// still rebuild something sensible — and so a truncated queue can be extended
/// past its stored end instead of simply stopping.
public struct QueueDescriptor: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case album
        case playlist
        case artist
        case station
        /// An ad-hoc queue with no reconstructible source.
        case adHoc
    }

    public var kind: Kind
    /// The source's provider id, when `kind` identifies one.
    public var sourceID: String?
    /// A revision/content hash of the source where the backend offers one, so a
    /// receiver can tell that a mutable playlist changed underneath the queue.
    public var sourceRevision: String?

    public init(kind: Kind, sourceID: String? = nil, sourceRevision: String? = nil) {
        self.kind = kind
        self.sourceID = sourceID
        self.sourceRevision = sourceRevision
    }

    public static let adHoc = QueueDescriptor(kind: .adHoc)

    /// Whether the remainder of a truncated queue can be rebuilt locally.
    public var isReconstructible: Bool { kind != .adHoc && sourceID != nil }
}

// MARK: - The records

/// The small, frequently-written record: what is playing and where.
///
/// Times are **integer milliseconds** throughout. Floating point is not
/// canonical across platforms, and a future non-Apple peer has to be able to
/// compute an identical `queueHash`.
public struct ContinuityCursor: Codable, Sendable, Hashable {
    /// Identifies one continuous run of playback. Minted on explicit new
    /// playback or on a takeover.
    ///
    /// Deliberately **not** the stream session id: `PlaybackReport.sessionID` is
    /// the Jellyfin `PlaySessionId` (a transcode/stream handle) and means
    /// something entirely different. Two identically-named fields would be wired
    /// up wrongly sooner or later.
    public var playbackRunID: UUID
    /// Stable per install; a domain-separated hash of the app's client
    /// identifier, so it never leaks the id presented to the server.
    public var deviceID: String
    /// Human label for the UI ("Brandon's iPhone"). Empty where the backend
    /// cannot carry it.
    public var deviceName: String
    /// Monotonic **within one `playbackRunID`** and meaningless across runs. It
    /// orders one device's own updates; it is not a claim to authority.
    public var cursorSequence: UInt64
    /// Freshness only — used to age a candidate out and to bound position
    /// extrapolation. Never used to decide who owns playback.
    public var capturedAtMS: Int64
    public var state: ContinuityPlaybackState
    public var current: TrackLocator
    /// Absolute index in the queue. Resolves the case where the same track
    /// appears twice — a bare track id cannot say *which* occurrence is playing.
    public var currentAbsoluteIndex: Int
    public var positionMS: Int64
    /// Links to the queue record. `nil` means "track and position only", which
    /// is a perfectly good resume on its own.
    public var queueHash: String?

    public init(
        playbackRunID: UUID,
        deviceID: String,
        deviceName: String = "",
        cursorSequence: UInt64,
        capturedAtMS: Int64,
        state: ContinuityPlaybackState,
        current: TrackLocator,
        currentAbsoluteIndex: Int,
        positionMS: Int64,
        queueHash: String? = nil
    ) {
        self.playbackRunID = playbackRunID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.cursorSequence = cursorSequence
        self.capturedAtMS = capturedAtMS
        self.state = state
        self.current = current
        self.currentAbsoluteIndex = currentAbsoluteIndex
        self.positionMS = positionMS
        self.queueHash = queueHash
    }

    public var capturedAt: Date {
        Date(timeIntervalSince1970: Double(capturedAtMS) / 1000)
    }

    public var positionSeconds: TimeInterval { Double(positionMS) / 1000 }
}

/// One entry of a stored queue.
///
/// Carries just enough metadata to render a row before the track has been
/// resolved against the local catalog — a device that has never synced this
/// server can still show the user what it is about to resume.
public struct ContinuityItem: Codable, Sendable, Hashable {
    public var locator: TrackLocator
    /// Index in the **pre-shuffle** order. This is what lets the receiving
    /// device turn shuffle *off* and get the album back; a flat list plus an
    /// `isShuffled` flag cannot express it.
    public var baseOrdinal: Int
    public var title: String
    public var artist: String
    /// Also caps how far a stale position may be extrapolated.
    public var durationMS: Int64
    public var artwork: ArtworkRef?

    public init(
        locator: TrackLocator,
        baseOrdinal: Int,
        title: String,
        artist: String,
        durationMS: Int64,
        artwork: ArtworkRef? = nil
    ) {
        self.locator = locator
        self.baseOrdinal = baseOrdinal
        self.title = title
        self.artist = artist
        self.durationMS = durationMS
        self.artwork = artwork
    }

    public var durationSeconds: TimeInterval { Double(durationMS) / 1000 }
}

/// The large, rarely-written record: the queue itself, in realized playback
/// order.
///
/// The order is stored **verbatim** rather than as a shuffle seed because Mozz's
/// shuffle is a *balanced* shuffle keyed on artist/album and biased by
/// device-local recency and taste scores — another device cannot reproduce it
/// from a seed even in principle.
public struct ContinuityQueue: Codable, Sendable, Hashable {
    /// Content hash; the cursor references this to detect a mismatched pair.
    public var queueHash: String
    public var descriptor: QueueDescriptor
    /// Realized playback order.
    public var items: [ContinuityItem]
    /// Absolute index of `items[0]` within the full queue. Non-zero only when
    /// the store forced truncation.
    public var startAbsoluteIndex: Int
    /// Length of the full queue, which may exceed `items.count`.
    public var totalCount: Int
    public var isTruncated: Bool
    public var repeatMode: ContinuityRepeatMode
    public var isShuffled: Bool

    public init(
        queueHash: String,
        descriptor: QueueDescriptor,
        items: [ContinuityItem],
        startAbsoluteIndex: Int = 0,
        totalCount: Int,
        isTruncated: Bool = false,
        repeatMode: ContinuityRepeatMode = .off,
        isShuffled: Bool = false
    ) {
        self.queueHash = queueHash
        self.descriptor = descriptor
        self.items = items
        self.startAbsoluteIndex = startAbsoluteIndex
        self.totalCount = totalCount
        self.isTruncated = isTruncated
        self.repeatMode = repeatMode
        self.isShuffled = isShuffled
    }
}

// MARK: - What a store hands back

/// A cursor plus, when available, the queue it refers to.
///
/// `queue` is nil when the store holds only a cursor, when the pair was found
/// mismatched, or when the backend cannot store a queue at all. That is a
/// degraded but genuinely useful resume — the track and position are still
/// exact — so it is modelled as an ordinary case, not an error.
public struct ContinuitySnapshot: Sendable {
    public var cursor: ContinuityCursor
    public var queue: ContinuityQueue?
    /// Tracks already hydrated by the store, keyed by provider id.
    ///
    /// Subsonic's `getPlayQueue` returns full song entries, so hydration there
    /// is free and the app must not re-fetch them one by one.
    public var hydrated: [String: Track]

    public init(
        cursor: ContinuityCursor,
        queue: ContinuityQueue? = nil,
        hydrated: [String: Track] = [:]
    ) {
        self.cursor = cursor
        self.queue = queue
        self.hydrated = hydrated
    }

    /// True when the cursor referenced a queue we could not pair with it.
    public var isQueueMissing: Bool { cursor.queueHash != nil && queue == nil }
}

/// What a particular store can actually do.
///
/// Callers gate UI on these rather than branching on the backend kind: Subsonic
/// genuinely cannot attribute a checkpoint to a device (its only signal is the
/// client *product* name), so a device label must not be promised there.
public struct ContinuityFeatures: Sendable, Hashable {
    /// Can persist the full cursor, not just track + position.
    public var richCursor: Bool
    /// Can persist a queue alongside the cursor.
    public var storesQueue: Bool
    /// Can attribute a checkpoint to a specific device.
    public var deviceAttribution: Bool
    /// Truncates the queue to a byte budget (Subsonic's GET URL limit).
    public var truncatesQueue: Bool

    public init(
        richCursor: Bool,
        storesQueue: Bool,
        deviceAttribution: Bool,
        truncatesQueue: Bool
    ) {
        self.richCursor = richCursor
        self.storesQueue = storesQueue
        self.deviceAttribution = deviceAttribution
        self.truncatesQueue = truncatesQueue
    }
}

// MARK: - The store

/// Durable, cross-device resume state held on the user's own server.
///
/// Deliberately narrow. It carries **resume information only and never
/// ownership**: nothing a device reads through this protocol may stop playback
/// or make a playing device yield. That rule is what makes last-writer-wins on a
/// single shared slot safe, given none of the supported servers offers
/// compare-and-swap.
public protocol ContinuityStore: Sendable {
    var features: ContinuityFeatures { get }

    /// The stored checkpoint, or nil when there is none (or the server does not
    /// support one).
    func load() async throws -> ContinuitySnapshot?

    /// Persist a cursor, and a queue when one is supplied and supported.
    func save(_ cursor: ContinuityCursor, queue: ContinuityQueue?) async throws
}
