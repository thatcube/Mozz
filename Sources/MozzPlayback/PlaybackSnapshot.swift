import Foundation

/// High-level transport state the UI binds to.
public enum PlaybackStatus: String, Sendable, Hashable {
    case idle
    case buffering
    case playing
    case paused
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
