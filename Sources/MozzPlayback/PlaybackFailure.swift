import Foundation
import MozzCore

/// Why playback couldn't start.
///
/// A failed load used to be entirely invisible: the engine set its status to
/// paused and returned, so tapping a track the server couldn't serve was
/// indistinguishable from tapping nothing at all. That silence is the single
/// most complained-about behaviour in offline music apps, and it is worst in the
/// car, where the driver has no way to investigate. This is the value the
/// surfaces need in order to say something useful.
public struct PlaybackFailure: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// The server couldn't be reached — the usual case for a self-hosted
        /// library in a car, where the LAN is out of range.
        case serverUnreachable
        /// The server answered but wouldn't serve this track.
        case unavailable
        /// Anything else.
        case other(String)

        public init(_ error: Error) {
            guard let mozzError = error as? MozzError else {
                self = .other(error.localizedDescription)
                return
            }
            switch mozzError {
            case .serverUnreachable, .transport:
                self = .serverUnreachable
            case .notFound, .unsupported:
                self = .unavailable
            default:
                self = .other(mozzError.localizedDescription)
            }
        }
    }

    /// The track that wouldn't play.
    public let track: Track
    public let reason: Reason
    /// How many tracks were skipped past before giving up, so a message can say
    /// "nothing in this queue could play" rather than naming one track when the
    /// whole queue was unplayable.
    public let skippedTracks: Int

    public init(track: Track, reason: Reason, skippedTracks: Int) {
        self.track = track
        self.reason = reason
        self.skippedTracks = skippedTracks
    }

    /// Whether this looks like "your server isn't reachable" rather than a
    /// problem with one particular track — which is what decides whether it's
    /// worth suggesting downloads.
    public var isConnectivity: Bool { reason == .serverUnreachable }

    /// A short line suitable for a CarPlay alert or a toast.
    public var message: String {
        switch reason {
        case .serverUnreachable:
            return skippedTracks > 0
                ? "Can't reach your server. Nothing in this queue is downloaded."
                : "Can't reach your server. This song isn't downloaded."
        case .unavailable:
            return "This song isn't available."
        case .other(let detail):
            return detail
        }
    }
}
