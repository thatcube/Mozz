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

    public init() {}

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
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artistName
        if let album = track.albumTitle { info[MPMediaItemPropertyAlbumTitle] = album }
        info[MPMediaItemPropertyPlaybackDuration] = duration > 0 ? duration : track.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Attach downsampled artwork once it has loaded (kept separate so the text
    /// metadata can appear instantly without waiting on an image fetch).
    public func updateArtwork(_ data: Data) {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    public func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

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
    public func updateArtwork(_ data: Data) {}
    public func clear() {}
}

#endif
