import Foundation
import MozzCore

/// How the queue behaves when it reaches the end of a track / the queue.
public enum RepeatMode: String, Sendable, Hashable, CaseIterable, Codable {
    /// Advance to the next track; stop at the end of the queue.
    case off
    /// Repeat the current track indefinitely.
    case one
    /// Advance to the next track; wrap to the start at the end of the queue.
    case all

    /// The next mode when the user taps the repeat control (off → all → one → off).
    public var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// A pure, value-typed playback queue. Holds no AVFoundation state, so it is
/// trivially testable and drives the engine deterministically.
///
/// Model:
/// - `tracks` is the *base* order the caller supplied (stable identity).
/// - `order` is a permutation of indices into `tracks` describing playback
///   order. With shuffle off it is the identity; with shuffle on it is a random
///   permutation that keeps the currently-playing track pinned at the front so
///   the current track is never interrupted by toggling shuffle.
/// - `position` indexes into `order`.
///
/// The distinction between ``advance()`` (user pressed *next*) and
/// ``trackDidFinish()`` (a track played to its end) matters for repeat-one:
/// finishing repeats the track, but pressing next always skips forward.
public struct PlayQueue: Sendable, Equatable, Codable {
    public private(set) var tracks: [Track]
    public private(set) var order: [Int]
    public private(set) var position: Int
    public private(set) var repeatMode: RepeatMode
    public private(set) var isShuffled: Bool

    /// Transient, gapless-critical cache: the freshly reshuffled order to install
    /// when a shuffled repeat-all queue wraps. Populated while the queue is
    /// parked on its last slot so ``peekNext`` can pre-roll the next loop's first
    /// track and ``advance()`` then plays that exact track. Excluded from
    /// `Codable`/`Equatable` (see ``CodingKeys``) — it's rebuilt on demand.
    private var nextLoopOrder: [Int]?

    private enum CodingKeys: String, CodingKey {
        case tracks, order, position, repeatMode, isShuffled
    }

    public init() {
        self.tracks = []
        self.order = []
        self.position = -1
        self.repeatMode = .off
        self.isShuffled = false
        self.nextLoopOrder = nil
    }

    /// Transient shuffle bookkeeping is deliberately excluded so equality (and
    /// the persisted snapshot) stays purely semantic.
    public static func == (lhs: PlayQueue, rhs: PlayQueue) -> Bool {
        lhs.tracks == rhs.tracks
            && lhs.order == rhs.order
            && lhs.position == rhs.position
            && lhs.repeatMode == rhs.repeatMode
            && lhs.isShuffled == rhs.isShuffled
    }

    // MARK: Derived state

    public var isEmpty: Bool { tracks.isEmpty }
    public var count: Int { tracks.count }

    /// The track at the current position, or `nil` when the queue is empty.
    public var current: Track? {
        guard order.indices.contains(position) else { return nil }
        return tracks[order[position]]
    }

    /// The tracks after the current one, in playback order (for an "up next" view).
    public var upNext: [Track] {
        guard position >= 0 else { return [] }
        let tail = order[(position + 1)...]
        return tail.map { tracks[$0] }
    }

    /// Whether ``advance()`` would yield a track (there's somewhere to go).
    public var hasNext: Bool {
        guard !isEmpty else { return false }
        if repeatMode == .all { return count > 0 }
        return position + 1 < order.count
    }

    public var hasPrevious: Bool {
        guard !isEmpty else { return false }
        if repeatMode == .all { return count > 0 }
        return position > 0
    }

    /// The track that will play once the current one finishes, without
    /// mutating. Used by the engine to preload the next item for gapless
    /// playback. Respects `repeatMode`.
    public var peekNext: Track? {
        guard !isEmpty else { return nil }
        switch repeatMode {
        case .one:
            return current
        case .off:
            let n = position + 1
            return order.indices.contains(n) ? tracks[order[n]] : nil
        case .all:
            let n = position + 1
            if n < order.count {
                return tracks[order[n]]
            }
            // Wrapping: when shuffled, the next loop uses the reshuffled order
            // cached while parked on the last slot; otherwise it replays `order`.
            let wrapped = nextLoopOrder ?? order
            return wrapped.first.map { tracks[$0] }
        }
    }

    /// The track a user "previous" would land on, without mutating. Mirrors
    /// ``peekNext`` and respects `repeatMode` (wraps to the last track under
    /// repeat-all). Note the engine additionally *restarts* the current track on
    /// `previous()` when more than 3s in — that policy lives in the engine, not
    /// here, so this always reports the true prior track.
    public var peekPrevious: Track? {
        guard !isEmpty else { return nil }
        switch repeatMode {
        case .one:
            return current
        case .off:
            let p = position - 1
            return order.indices.contains(p) ? tracks[order[p]] : nil
        case .all:
            let p = position - 1
            let idx = p >= 0 ? p : order.count - 1
            return order.indices.contains(idx) ? tracks[order[idx]] : nil
        }
    }

    // MARK: Loading

    /// Replace the queue with `newTracks` and begin at `startIndex` (a base
    /// index into `newTracks`). Preserves the current shuffle setting.
    public mutating func setItems(_ newTracks: [Track], startingAt startIndex: Int = 0) {
        tracks = newTracks
        nextLoopOrder = nil
        guard !newTracks.isEmpty else {
            order = []
            position = -1
            return
        }
        let clampedStart = min(max(startIndex, 0), newTracks.count - 1)
        if isShuffled {
            order = balancedOrder(pinning: clampedStart)
            position = 0
        } else {
            order = Array(newTracks.indices)
            position = clampedStart
        }
        refreshWrapCache()
    }

    /// Replace the queue with `newTracks` and start playing a freshly balanced
    /// shuffle (no pinned start, so the first track feels random). Forces shuffle
    /// on — the single entry point every "Shuffle" button in the app uses.
    public mutating func setItemsShuffled(_ newTracks: [Track]) {
        tracks = newTracks
        isShuffled = true
        nextLoopOrder = nil
        guard !newTracks.isEmpty else {
            order = []
            position = -1
            return
        }
        order = balancedOrder(pinning: nil)
        position = 0
        refreshWrapCache()
    }

    /// Append tracks to the end of the base list and the play order.
    public mutating func append(_ newTracks: [Track]) {
        guard !newTracks.isEmpty else { return }
        let firstNew = tracks.count
        tracks.append(contentsOf: newTracks)
        order.append(contentsOf: (firstNew..<tracks.count))
        if position < 0 { position = 0 }
        refreshWrapCache()
    }

    /// Insert tracks so they play immediately after the current track.
    public mutating func insertNext(_ newTracks: [Track]) {
        guard !newTracks.isEmpty else { return }
        let firstNew = tracks.count
        tracks.append(contentsOf: newTracks)
        let newOrderEntries = Array(firstNew..<tracks.count)
        let insertAt = position < 0 ? order.count : position + 1
        order.insert(contentsOf: newOrderEntries, at: insertAt)
        if position < 0 { position = 0 }
        refreshWrapCache()
    }

    // MARK: Navigation

    /// Advance as if the current track finished playing. Repeat-one keeps the
    /// same track; otherwise behaves like ``advance()``. Returns the new
    /// current track (or `nil` at the end of a non-repeating queue).
    @discardableResult
    public mutating func trackDidFinish() -> Track? {
        guard !isEmpty else { return nil }
        if repeatMode == .one { return current }
        return advance()
    }

    /// Skip to the next track (user action). Ignores repeat-one. Wraps when
    /// repeat-all is on; returns `nil` if already at the end with repeat off.
    @discardableResult
    public mutating func advance() -> Track? {
        guard !isEmpty else { return nil }
        if position + 1 < order.count {
            position += 1
        } else if repeatMode == .all {
            wrapToStart()
        } else {
            return nil
        }
        refreshWrapCache()
        return current
    }

    /// Go to the previous track. Wraps when repeat-all is on.
    @discardableResult
    public mutating func previous() -> Track? {
        guard !isEmpty else { return nil }
        if position > 0 {
            position -= 1
        } else if repeatMode == .all {
            position = order.count - 1
        } else {
            return current
        }
        refreshWrapCache()
        return current
    }

    /// Jump directly to a track by its base index.
    @discardableResult
    public mutating func jump(toBaseIndex baseIndex: Int) -> Track? {
        guard let p = order.firstIndex(of: baseIndex) else { return current }
        position = p
        refreshWrapCache()
        return current
    }

    // MARK: Repeat

    /// Set the repeat mode. Routed through a method (rather than a settable
    /// property) so the gapless reshuffle-on-wrap cache is refreshed when the
    /// mode changes while parked on the last track.
    public mutating func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
        refreshWrapCache()
    }

    // MARK: Shuffle

    public mutating func setShuffle(_ enabled: Bool) {
        guard enabled != isShuffled else { return }
        isShuffled = enabled
        nextLoopOrder = nil
        guard !isEmpty else { return }
        let currentBase = order.indices.contains(position) ? order[position] : 0
        if enabled {
            order = balancedOrder(pinning: currentBase)
            position = 0
        } else {
            order = Array(tracks.indices)
            position = currentBase
        }
        refreshWrapCache()
    }

    public mutating func toggleShuffle() { setShuffle(!isShuffled) }

    /// Rebuild transient, non-persisted bookkeeping after a queue is assigned
    /// wholesale (e.g. decoded from a saved session). `nextLoopOrder` is excluded
    /// from `Codable`, so this re-primes the reshuffle-on-wrap cache for the
    /// current position; call it after restoring a persisted queue.
    public mutating func rebuildTransientState() {
        refreshWrapCache()
    }

    /// A balanced permutation of all base indices, spreading by artist (primary)
    /// then album (secondary) so same-artist and, within that, same-album tracks
    /// don't clump. When `pinned` is non-nil that track is forced to the front so
    /// it keeps playing when shuffle turns on mid-track; the remainder stays spread.
    private func balancedOrder(pinning pinned: Int?) -> [Int] {
        var result = BalancedShuffle.order(
            of: Array(tracks.indices),
            keys: [{ Self.artistKey(tracks[$0]) }, { Self.albumKey(tracks[$0]) }]
        )
        if let pinned {
            result.removeAll { $0 == pinned }
            result.insert(pinned, at: 0)
        }
        return result
    }

    /// Primary grouping key: the normalized artist, so same-artist tracks spread.
    private static func artistKey(_ track: Track) -> String {
        track.artistName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Secondary grouping key: album identity. Prefers the stable album id, then
    /// title+album-artist; an unknown album falls back to the track id so those
    /// tracks stay unique and spread freely rather than clumping under "".
    private static func albumKey(_ track: Track) -> String {
        if let id = track.albumID, !id.isEmpty { return "id:" + id }
        let title = track.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            let artist = (track.albumArtistName ?? track.artistName).lowercased()
            return "t:" + title.lowercased() + "|" + artist
        }
        return "u:" + track.id
    }

    private func sameArtist(_ a: Int, _ b: Int) -> Bool {
        Self.artistKey(tracks[a]) == Self.artistKey(tracks[b])
    }

    /// A fresh balanced order for the next loop that avoids a jarring seam: its
    /// first track won't be the same track — or, when possible, the same artist —
    /// as `outgoing` (the track currently finishing the loop). It **rotates** the
    /// balanced order to a non-colliding head rather than splicing an element to
    /// the front: rotation preserves the internal spread (only the wrap-around
    /// join changes), and for equal-sized artist groups the balanced order is a
    /// clean cycle whose ends differ, so no new same-artist adjacency appears.
    /// Falls back gracefully when the library is a single artist.
    private func wrapOrder(avoiding outgoing: Int) -> [Int] {
        let fresh = balancedOrder(pinning: nil)
        guard fresh.count > 1, let head = fresh.first,
              head == outgoing || sameArtist(head, outgoing) else {
            return fresh   // head already opens on a different artist and track
        }
        // Prefer rotating to a different artist; otherwise at least a different
        // track than the one just played.
        let pivot = fresh.firstIndex { !sameArtist($0, outgoing) }
            ?? fresh.firstIndex { $0 != outgoing }
        guard let pivot, pivot != 0 else { return fresh }
        return Array(fresh[pivot...] + fresh[..<pivot])
    }

    /// Install the next loop's order when wrapping a shuffled repeat-all queue.
    /// Consumes the cache populated by ``refreshWrapCache()`` so the track that
    /// actually plays matches the one ``peekNext`` pre-rolled for gapless
    /// playback; falls back to replaying `order` when no reshuffle is cached.
    private mutating func wrapToStart() {
        if isShuffled, let next = nextLoopOrder {
            order = next
            nextLoopOrder = nil
        }
        position = 0
    }

    /// Keep ``nextLoopOrder`` populated exactly while the queue is parked on its
    /// last slot with shuffle + repeat-all. That lets ``peekNext`` pre-roll the
    /// reshuffled first track of the next loop and ``advance()`` play that same
    /// track, so the loop boundary stays gapless. The cached order also avoids a
    /// same-artist/same-track seam with the outgoing track. Cleared whenever the
    /// conditions don't hold; never overwritten while they do (so a pre-rolled
    /// choice can't drift before it's consumed).
    private mutating func refreshWrapCache() {
        let parkedOnLast = !isEmpty && position == order.count - 1
        guard isShuffled, repeatMode == .all, parkedOnLast else {
            nextLoopOrder = nil
            return
        }
        if nextLoopOrder == nil {
            nextLoopOrder = wrapOrder(avoiding: order[position])
        }
    }
}
