import Foundation

/// How the play queue behaves when the current track finishes.
public enum RepeatMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Stop after the last track in the queue.
    case off
    /// Loop the whole queue.
    case all
    /// Loop the current track.
    case one

    /// The mode reached by cycling the repeat button once.
    public var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// Whether upcoming tracks play in queue order or shuffled.
public enum ShuffleMode: String, Codable, Sendable, Hashable, CaseIterable {
    case off
    case on

    public mutating func toggle() {
        self = self == .off ? .on : .off
    }
}
