import Foundation
import Observation
import MozzCore
import MozzEnrichment
import MozzPlayback

/// Drives the Now Playing lyrics panel: resolves the current track's lyrics, and
/// publishes which line is being sung right now.
///
/// ### Why this owns a clock
/// ``PlaybackEngine`` samples the player every 0.5s, which is plenty for a seek
/// bar but visibly late for lyrics — a line would light up as much as half a
/// second after it's sung. Rather than double the engine's tick rate (and with it
/// the re-render cost of every view that reads the snapshot), this object runs its
/// own light ticker *only while the panel is on screen*, extrapolating between
/// engine samples from a wall-clock anchor.
///
/// Crucially it publishes ``activeIndex`` — not a time. The ticker runs at 10 Hz
/// but the index changes only once per lyric line, so SwiftUI re-renders the panel
/// a handful of times per song instead of ten times a second.
@MainActor
@Observable
final class LyricsController {
    /// What the panel should be showing.
    enum State: Equatable {
        /// Nothing requested yet.
        case idle
        /// A lookup is in flight.
        case loading
        /// Lyrics were found.
        case loaded(Lyrics)
        /// The lookup finished and this track definitively has none — say so.
        case unavailable
        /// We already knew this track has none (a cached negative), or the answer
        /// couldn't be trusted. Stay quiet: no spinner, no "No lyrics found",
        /// while a background re-check quietly looks again.
        case silent

        var lyrics: Lyrics? {
            if case let .loaded(lyrics) = self { return lyrics }
            return nil
        }

        var isResolving: Bool {
            switch self {
            case .idle, .loading: return true
            case .loaded, .unavailable, .silent: return false
            }
        }
    }

    private(set) var state: State = .idle
    /// Index of the line currently being sung, or `nil` for unsynced lyrics and
    /// for the run-up before the first timestamp.
    private(set) var activeIndex: Int?

    /// A small anticipation lead (seconds) so a line highlights right as it's sung
    /// rather than a beat late. Absorbs the residual latency between sampling the
    /// player's position and the pixels landing on screen.
    static let lead: TimeInterval = 0.3

    /// How often the panel re-evaluates which line is active while visible.
    private static let tickInterval: TimeInterval = 0.1

    /// Upper bound on how far the wall-clock extrapolation may run past the last
    /// engine sample. One engine tick (0.5s) plus slack: if samples stop arriving
    /// (a stall, a background suspension) the estimate freezes instead of racing
    /// ahead of the audio.
    private static let maxExtrapolation: TimeInterval = 0.75

    /// The backend that owns the current track. Set by the player from the app
    /// environment and kept up to date, so signing into a different server needs no
    /// rebuild. `@ObservationIgnored` because nothing renders from it — writing it
    /// must not invalidate the player.
    @ObservationIgnored var backend: (any MusicBackend)?
    /// The user's "look up lyrics online" preference, mirrored from `@AppStorage`.
    @ObservationIgnored var useOnlineLookup = true

    @ObservationIgnored private let playback: PlaybackEngine
    @ObservationIgnored private let service: LyricsService

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Non-nil while the panel is on screen; the ticker only runs then.
    @ObservationIgnored private var visible = false

    /// The last engine sample we saw, and the wall-clock instant we saw it at.
    @ObservationIgnored private var anchorElapsed: TimeInterval = 0
    @ObservationIgnored private var anchorDate = Date()
    @ObservationIgnored private var lastSampledElapsed: TimeInterval = -1

    init(playback: PlaybackEngine, service: LyricsService = LyricsService()) {
        self.playback = playback
        self.service = service
    }

    deinit {
        loadTask?.cancel()
        refreshTask?.cancel()
        prefetchTask?.cancel()
        ticker?.cancel()
    }

    // MARK: Visibility

    /// Starts/stops the line ticker. Called by the panel as it appears and
    /// disappears, so a closed panel costs nothing.
    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        if visible {
            resetAnchor()
            updateActiveLine()
            startTicker()
        } else {
            ticker?.cancel()
            ticker = nil
        }
    }

    // MARK: Loading

    /// Resolves lyrics for `track`, cancelling any in-flight lookup so a fast
    /// next/previous never leaves a stale track's words on screen.
    func load(track: Track?) {
        loadTask?.cancel()
        refreshTask?.cancel()
        prefetchTask?.cancel()
        activeIndex = nil
        resetAnchor()

        guard let track else {
            state = .idle
            return
        }
        state = .loading
        let backend = self.backend
        let useLRCLIB = useOnlineLookup
        let trackID = track.id
        let service = self.service

        loadTask = Task { [weak self] in
            let resolution = await service.resolve(
                track: track, backend: backend, context: .visible, useLRCLIB: useLRCLIB
            )
            guard !Task.isCancelled, let self else { return }
            // Ignore a result that arrived after the user moved on.
            guard self.playback.currentTrack?.id == trackID else { return }

            if let lyrics = resolution.lyrics, !lyrics.isEmpty {
                self.state = .loaded(lyrics)
                self.resetAnchor()
                self.updateActiveLine()
            } else if resolution.staySilent {
                // A remembered or untrustworthy negative: stay quiet and re-check
                // quietly in the background, so a song that has since gained an
                // upload surfaces without the user doing anything.
                self.state = .silent
                self.refreshInBackground(track: track, backend: backend, useLRCLIB: useLRCLIB)
            } else {
                // A first-time resolution that really came up empty — say so once.
                self.state = .unavailable
            }
            self.prefetchNext(backend: backend, useLRCLIB: useLRCLIB)
        }
    }

    /// Re-resolves the current track from scratch. Used when the user turns the
    /// online-lookup setting back on: the resolve that ran while it was off
    /// deliberately skipped LRCLIB, so the cached answer is incomplete.
    func reload() {
        load(track: playback.currentTrack)
    }

    /// Silent re-check for a track whose visible state is `.silent`. Promotes to
    /// `.loaded` if the fresh lookup finds something; otherwise leaves the state
    /// alone so the user never sees a flash. The service debounces, so this is
    /// safe to call on every play.
    private func refreshInBackground(
        track: Track, backend: (any MusicBackend)?, useLRCLIB: Bool
    ) {
        let trackID = track.id
        let service = self.service
        refreshTask = Task { [weak self] in
            let refreshed = await service.refresh(
                track: track, backend: backend, useLRCLIB: useLRCLIB
            )
            guard !Task.isCancelled, let self else { return }
            guard self.playback.currentTrack?.id == trackID else { return }
            guard let refreshed, !refreshed.isEmpty else { return }
            // Only promote while we're still silent — another load may have
            // superseded us.
            guard case .silent = self.state else { return }
            self.state = .loaded(refreshed)
            self.resetAnchor()
            self.updateActiveLine()
        }
    }

    /// Warms the cache for the next queued track so advancing is instant.
    private func prefetchNext(backend: (any MusicBackend)?, useLRCLIB: Bool) {
        guard let next = playback.upNext.first else { return }
        let service = self.service
        prefetchTask = Task {
            _ = await service.resolve(
                track: next, backend: backend, context: .prefetch, useLRCLIB: useLRCLIB
            )
        }
    }

    // MARK: Line tracking

    /// The estimated playback position, interpolated between engine samples.
    ///
    /// While paused (or between tracks) this is just the sampled value; while
    /// playing it advances with the wall clock from the last sample, clamped so a
    /// stalled engine can't let the estimate run away from the audio.
    var estimatedElapsed: TimeInterval {
        let snapshot = playback.snapshot
        guard snapshot.status == .playing else { return snapshot.elapsed }
        let drift = min(Date().timeIntervalSince(anchorDate), Self.maxExtrapolation)
        return anchorElapsed + max(0, drift)
    }

    private func resetAnchor() {
        anchorElapsed = playback.snapshot.elapsed
        anchorDate = Date()
        lastSampledElapsed = anchorElapsed
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.tickInterval * 1_000_000_000)
                )
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        // Re-anchor whenever the engine publishes a fresh sample (including after
        // a seek, which moves it backwards).
        let sampled = playback.snapshot.elapsed
        if sampled != lastSampledElapsed {
            lastSampledElapsed = sampled
            anchorElapsed = sampled
            anchorDate = Date()
        }
        updateActiveLine()
    }

    /// Recomputes the active line and publishes it **only when it changes**, so
    /// the 10 Hz ticker doesn't re-render the panel ten times a second.
    private func updateActiveLine() {
        guard let lyrics = state.lyrics, lyrics.isSynced else {
            if activeIndex != nil { activeIndex = nil }
            return
        }
        let index = lyrics.activeLineIndex(at: estimatedElapsed, lead: Self.lead)
        if index != activeIndex { activeIndex = index }
    }

    // MARK: Seeking

    /// Jumps playback to the start of `index`, for tap-to-seek on a lyric line.
    /// No-op for unsynced lyrics (there is nothing to seek to).
    func seek(toLine index: Int) {
        guard let lyrics = state.lyrics,
              lyrics.lines.indices.contains(index),
              let start = lyrics.lines[index].start else { return }
        playback.seek(to: start)
        anchorElapsed = start
        anchorDate = Date()
        lastSampledElapsed = start
        updateActiveLine()
    }
}
