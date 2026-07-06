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
    public var repeatMode: RepeatMode
    public private(set) var isShuffled: Bool

    public init() {
        self.tracks = []
        self.order = []
        self.position = -1
        self.repeatMode = .off
        self.isShuffled = false
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
            let idx = n < order.count ? n : 0
            return order.indices.contains(idx) ? tracks[order[idx]] : nil
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
        guard !newTracks.isEmpty else {
            order = []
            position = -1
            return
        }
        let clampedStart = min(max(startIndex, 0), newTracks.count - 1)
        if isShuffled {
            order = shuffledOrder(pinning: clampedStart)
            position = 0
        } else {
            order = Array(newTracks.indices)
            position = clampedStart
        }
    }

    /// Append tracks to the end of the base list and the play order.
    public mutating func append(_ newTracks: [Track]) {
        guard !newTracks.isEmpty else { return }
        let firstNew = tracks.count
        tracks.append(contentsOf: newTracks)
        order.append(contentsOf: (firstNew..<tracks.count))
        if position < 0 { position = 0 }
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
            position = 0
        } else {
            return nil
        }
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
        return current
    }

    /// Jump directly to a track by its base index.
    @discardableResult
    public mutating func jump(toBaseIndex baseIndex: Int) -> Track? {
        guard let p = order.firstIndex(of: baseIndex) else { return current }
        position = p
        return current
    }

    // MARK: Shuffle

    public mutating func setShuffle(_ enabled: Bool) {
        guard enabled != isShuffled else { return }
        isShuffled = enabled
        guard !isEmpty else { return }
        let currentBase = order.indices.contains(position) ? order[position] : 0
        if enabled {
            order = shuffledOrder(pinning: currentBase)
            position = 0
        } else {
            order = Array(tracks.indices)
            position = currentBase
        }
    }

    public mutating func toggleShuffle() { setShuffle(!isShuffled) }

    /// A random permutation of all base indices with `pinned` forced to the
    /// front, so the current track keeps playing when shuffle turns on.
    private func shuffledOrder(pinning pinned: Int) -> [Int] {
        var rest = Array(tracks.indices)
        rest.removeAll { $0 == pinned }
        rest.shuffle()
        return [pinned] + rest
    }
}
