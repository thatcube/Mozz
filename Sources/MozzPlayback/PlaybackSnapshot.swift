import Foundation

/// High-level transport state the UI binds to.
public enum PlaybackStatus: String, Sendable, Hashable {
    case idle
    case buffering
    case playing
    case paused
}

/// Which way the transport last moved. Lets the UI animate a skip in the
/// direction it actually travelled, whoever asked for it — the on-screen
/// buttons, the Lock Screen, CarPlay, a headphone remote, or a track simply
/// ending and rolling into the next one.
public enum TransportDirection: String, Sendable, Hashable {
    case forward
    case backward
}

/// A snapshot of everything the UI needs to render the now-playing surface.
/// Value type so it can cross actors and be diffed cheaply by SwiftUI.
public struct PlaybackSnapshot: Sendable, Hashable {
    public var status: PlaybackStatus
    public var currentTrackID: String?
    public var elapsed: TimeInterval
    public var duration: TimeInterval
    public var repeatMode: RepeatMode
    public var isShuffled: Bool
    public var hasNext: Bool
    public var hasPrevious: Bool
    /// The direction of the most recent transport move.
    public var transportDirection: TransportDirection = .forward
    /// Bumped on every transport move — a track change, or a skip-back that
    /// restarts the current track. Purely a UI trigger: views key a one-shot
    /// animation off the change, so the glyph reacts to what playback *did*
    /// rather than to a finger, and a skip from CarPlay or the Lock Screen
    /// animates exactly like a tap on the player.
    public var transportGeneration: Int = 0

    public init(
        status: PlaybackStatus = .idle,
        currentTrackID: String? = nil,
        elapsed: TimeInterval = 0,
        duration: TimeInterval = 0,
        repeatMode: RepeatMode = .off,
        isShuffled: Bool = false,
        hasNext: Bool = false,
        hasPrevious: Bool = false
    ) {
        self.status = status
        self.currentTrackID = currentTrackID
        self.elapsed = elapsed
        self.duration = duration
        self.repeatMode = repeatMode
        self.isShuffled = isShuffled
        self.hasNext = hasNext
        self.hasPrevious = hasPrevious
    }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }
}
