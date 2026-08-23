import Foundation
import MozzCore

#if canImport(MediaPlayer)
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/// Bridges the engine to the lock screen / Control Center: publishes
/// now-playing metadata to `MPNowPlayingInfoCenter` and routes the hardware /
/// remote transport buttons through `MPRemoteCommandCenter` back into the
/// engine via closures.
@MainActor
public final class NowPlayingCenter {
    public var onPlay: (() -> Void)?
    public var onPause: (() -> Void)?
    public var onToggle: (() -> Void)?
    public var onNext: (() -> Void)?
    public var onPrevious: (() -> Void)?
    public var onSeek: ((TimeInterval) -> Void)?

    private var commandsConfigured = false

    /// The current track's cover art, cached so it survives republishing (the
    /// info dict is rebuilt from our own copy). Keyed by track id so a stale
    /// image is never re-applied to a newly-started track.
    private var currentArtwork: MPMediaItemArtwork?
    private var artworkTrackID: String?

    /// The last dict handed to the system, kept locally so artwork can be
    /// attached without reading `nowPlayingInfo` back (that getter round-trips
    /// to the media daemon and can hand back a stale dict).
    private var info: [String: Any] = [:]

    /// Everything that forces a republish when it changes. Position is handled
    /// separately because the system extrapolates it — see `update`.
    private struct Anchor: Equatable {
        var trackID: String
        var isPlaying: Bool
        var duration: TimeInterval
    }
    private var anchor: Anchor?
    /// The position we last published, and when, so a seek can be told apart
    /// from the playhead simply advancing on its own.
    private var anchorElapsed: TimeInterval = 0
    private var anchorAt = Date.distantPast

    public func configureCommands() {
        guard !commandsConfigured else { return }
        commandsConfigured = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.onPlay?(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.onPause?(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onToggle?(); return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNext?(); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPrevious?(); return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.onSeek?(positionEvent.positionTime)
            return .success
        }
    }

    /// Enable/disable the skip commands so the lock screen greys them out to
    /// match the queue (e.g. no previous at the start of a non-repeating queue).
    public func setSkipEnabled(next: Bool, previous: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = next
        center.previousTrackCommand.isEnabled = previous
    }

    public func update(track: Track, elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        let next = Anchor(trackID: track.id, isPlaying: isPlaying,
                          duration: duration > 0 ? duration : track.duration)
        // The system advances the playhead itself from the position and rate we
        // publish, so pushing a new dict on every progress tick is just churn —
        // and republishing that fast is a known cause of the artwork flickering
        // back out. Publish when something actually changes, plus whenever the
        // position stops matching what the system would have extrapolated, which
        // is what a seek looks like from here.
        var shouldPublish = anchor != next
        if !shouldPublish {
            let expected = isPlaying
                ? anchorElapsed + Date().timeIntervalSince(anchorAt)
                : anchorElapsed
            shouldPublish = abs(elapsed - expected) > 1.5
        }
        guard shouldPublish else { return }

        anchor = next
        anchorElapsed = elapsed
        anchorAt = Date()

        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artistName
        if let album = track.albumTitle { info[MPMediaItemPropertyAlbumTitle] = album }
        info[MPMediaItemPropertyPlaybackDuration] = next.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        // Only re-apply art that belongs to the track being published.
        if let art = currentArtwork, artworkTrackID == track.id {
            info[MPMediaItemPropertyArtwork] = art
        }
        self.info = info
        publish(isPlaying: isPlaying)
    }

    /// Attach downsampled artwork once it has loaded (kept separate so the text
    /// metadata can appear instantly without waiting on an image fetch).
    public func updateArtwork(_ data: Data, for trackID: String) {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return }
        let art = MPMediaItemArtwork(boundsSize: image.size,
                                     requestHandler: ArtworkResizer(image: image).image(at:))
        currentArtwork = art
        artworkTrackID = trackID
        // Cache it either way, so the next publish picks it up; only push it out
        // now if it belongs to the track currently on screen.
        guard let anchor, anchor.trackID == trackID else { return }
        info[MPMediaItemPropertyArtwork] = art
        publish(isPlaying: anchor.isPlaying)
        #endif
    }

    public func clear() {
        currentArtwork = nil
        artworkTrackID = nil
        anchor = nil
        anchorElapsed = 0
        anchorAt = .distantPast
        info = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// `playbackState` is what CarPlay reads to decide whether to draw play or
    /// pause, and whether to run the progress bar. The lock screen gets by on
    /// the playback rate in the dict alone, which is why this was only ever
    /// visibly wrong in the car. Set both.
    private func publish(isPlaying: Bool) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
}

#if canImport(UIKit)
/// Redraws cover art at whatever size the system asks for.
///
/// `MPMediaItemArtwork`'s handler is documented as having to return an image of
/// exactly the requested size; hand back the original instead and CarPlay
/// quietly shows nothing at all. The last result is memoised because the
/// handler is called repeatedly, often at one or two sizes, and off the main
/// thread — hence the lock.
private final class ArtworkResizer: @unchecked Sendable {
    private let image: UIImage
    private let lock = NSLock()
    private var cachedSize: CGSize = .zero
    private var cached: UIImage?

    init(image: UIImage) { self.image = image }

    func image(at size: CGSize) -> UIImage {
        guard size.width > 0, size.height > 0 else { return image }
        lock.lock()
        defer { lock.unlock() }
        if let cached, cachedSize == size { return cached }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        cachedSize = size
        cached = resized
        return resized
    }
}
#endif

#else

/// Non-MediaPlayer stub for host-side testing.
@MainActor
public final class NowPlayingCenter {
    public var onPlay: (() -> Void)?
    public var onPause: (() -> Void)?
    public var onToggle: (() -> Void)?
    public var onNext: (() -> Void)?
    public var onPrevious: (() -> Void)?
    public var onSeek: ((TimeInterval) -> Void)?
    public init() {}
    public func configureCommands() {}
    public func setSkipEnabled(next: Bool, previous: Bool) {}
    public func update(track: Track, elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool) {}
    public func updateArtwork(_ data: Data, for trackID: String) {}
    public func clear() {}
}

#endif
