import Foundation
import AVFoundation
import Combine
import MozzCore

/// The playback engine. Wraps an `AVQueuePlayer` to get **gapless** playback
/// (the player pre-rolls the next item so there is no silence at track
/// boundaries), while a pure ``PlayQueue`` owns ordering / shuffle / repeat.
///
/// How gapless works here: the player is kept loaded with at most two items —
/// the current track and the one ``PlayQueue/peekNext`` says comes next. When a
/// track plays to its end the player advances seamlessly; we observe that, sync
/// the `PlayQueue`, and top the player back up to two items. Manual skips
/// rebuild from the new current track (a hair of latency there is fine; gapless
/// only matters for uninterrupted sequential listening).
///
/// Concurrency: `@MainActor` because it drives `AVQueuePlayer`, publishes to
/// SwiftUI, and receives remote-command callbacks — all main-thread concerns.
/// URL resolution is `async` (it may hit the network or disk) and guarded by a
/// generation counter so rapid skips can't race stale loads onto the player.
@MainActor
public final class PlaybackEngine: ObservableObject {
    @Published public private(set) var snapshot = PlaybackSnapshot()
    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var upNext: [Track] = []

    /// Optional scrobble / progress hook. The app wires this to
    /// `MusicBackend.reportPlayback`. Never blocks playback.
    public var onReport: (@Sendable (PlaybackReport) -> Void)?
    /// Called when artwork should be fetched for the lock screen.
    public var onNeedsArtwork: ((Track) -> Void)?

    private let player = AVQueuePlayer()
    private let resolver: TrackURLResolver
    private let session = AudioSessionController()
    private let nowPlaying = NowPlayingCenter()

    private var queue = PlayQueue()
    /// Tracks currently loaded into the player, aligned with `player.items()`.
    private var loaded: [(item: AVPlayerItem, track: Track, sessionID: String?)] = []
    private var loadGeneration = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var wasPlayingBeforeInterruption = false

    public init(resolver: TrackURLResolver) {
        self.resolver = resolver
        self.player.actionAtItemEnd = .advance
        self.player.automaticallyWaitsToMinimizeStalling = true
        configureObservers()
        configureRemote()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: Public transport

    public var repeatMode: RepeatMode { queue.repeatMode }
    public var isShuffled: Bool { queue.isShuffled }

    /// Load a set of tracks and start playing at `startIndex`.
    public func play(tracks: [Track], startAt startIndex: Int = 0) {
        queue.setItems(tracks, startingAt: startIndex)
        try? session.activate()
        reload(autoplay: true)
    }

    /// Enqueue tracks to play after the current track.
    public func playNext(_ tracks: [Track]) {
        let wasEmpty = queue.isEmpty
        queue.insertNext(tracks)
        if wasEmpty { reload(autoplay: true) } else { refillLookahead() }
        publish()
    }

    /// Append tracks to the end of the queue.
    public func append(_ tracks: [Track]) {
        let wasEmpty = queue.isEmpty
        queue.append(tracks)
        if wasEmpty { reload(autoplay: true) } else { refillLookahead() }
        publish()
    }

    public func togglePlayPause() {
        switch snapshot.status {
        case .playing, .buffering: pause()
        case .paused, .idle: resume()
        }
    }

    public func resume() {
        guard currentTrack != nil else { return }
        try? session.activate()
        player.play()
        publish(status: .playing)
        report(.playing)
    }

    public func pause() {
        player.pause()
        publish(status: .paused)
        report(.paused)
    }

    public func next() {
        guard queue.advance() != nil else {
            // End of a non-repeating queue.
            stop()
            return
        }
        reload(autoplay: snapshot.status == .playing || snapshot.status == .buffering)
    }

    public func previous() {
        // Restart the current track if we're more than 3s in (standard behavior).
        if snapshot.elapsed > 3 {
            seek(to: 0)
            return
        }
        _ = queue.previous()
        reload(autoplay: snapshot.status == .playing || snapshot.status == .buffering)
    }

    public func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
    }

    public func setRepeatMode(_ mode: RepeatMode) {
        queue.repeatMode = mode
        refillLookahead()
        publish()
    }

    public func cycleRepeatMode() { setRepeatMode(queue.repeatMode.next) }

    public func setShuffle(_ enabled: Bool) {
        queue.setShuffle(enabled)
        refillLookahead()
        publish()
    }

    public func toggleShuffle() { setShuffle(!queue.isShuffled) }

    public func stop() {
        player.pause()
        player.removeAllItems()
        loaded.removeAll()
        report(.stopped)
        currentTrack = nil
        upNext = []
        snapshot = PlaybackSnapshot(repeatMode: queue.repeatMode, isShuffled: queue.isShuffled)
        nowPlaying.clear()
        session.deactivate()
    }

    // MARK: Loading

    /// Rebuild the player from the queue's current track (+ lookahead).
    private func reload(autoplay: Bool) {
        loadGeneration += 1
        let generation = loadGeneration
        player.pause()
        player.removeAllItems()
        loaded.removeAll()

        guard let track = queue.current else {
            currentTrack = nil
            publish(status: .idle)
            return
        }
        currentTrack = track
        publish(status: .buffering)
        onNeedsArtwork?(track)

        Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await resolver.resolve(track)
                guard generation == self.loadGeneration else { return }
                let item = AVPlayerItem(url: resolved.url)
                self.player.insert(item, after: nil)
                self.loaded = [(item, track, resolved.sessionID)]
                if autoplay {
                    self.player.play()
                    self.publish(status: .playing)
                    self.report(.playing)
                } else {
                    self.publish(status: .paused)
                }
                await self.refillLookaheadAsync(generation: generation)
            } catch {
                guard generation == self.loadGeneration else { return }
                self.publish(status: .paused)
            }
        }
    }

    /// Ensure the player holds the next track for gapless advance.
    private func refillLookahead() {
        let generation = loadGeneration
        Task { [weak self] in await self?.refillLookaheadAsync(generation: generation) }
    }

    private func refillLookaheadAsync(generation: Int) async {
        guard generation == loadGeneration else { return }
        guard loaded.count == 1, let nextTrack = queue.peekNext else { return }
        // Don't double-load the same track object unless repeat-one intends it.
        do {
            let resolved = try await resolver.resolve(nextTrack)
            guard generation == loadGeneration, loaded.count == 1 else { return }
            let item = AVPlayerItem(url: resolved.url)
            if player.canInsert(item, after: loaded.last?.item) {
                player.insert(item, after: loaded.last?.item)
                loaded.append((item, nextTrack, resolved.sessionID))
            }
        } catch {
            // Leave the lookahead empty; we'll rebuild on the boundary instead.
        }
    }

    // MARK: Observers

    private func configureObservers() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.itemDidFinish(note.object as? AVPlayerItem) }
        }

        session.onInterruptionBegan = { [weak self] in
            guard let self else { return }
            self.wasPlayingBeforeInterruption = self.snapshot.status == .playing
            self.pause()
        }
        session.onInterruptionEnded = { [weak self] shouldResume in
            guard let self, shouldResume, self.wasPlayingBeforeInterruption else { return }
            self.resume()
        }
        session.onOldDeviceUnavailable = { [weak self] in
            self?.pause()
        }
    }

    private func configureRemote() {
        nowPlaying.configureCommands()
        nowPlaying.onPlay = { [weak self] in self?.resume() }
        nowPlaying.onPause = { [weak self] in self?.pause() }
        nowPlaying.onToggle = { [weak self] in self?.togglePlayPause() }
        nowPlaying.onNext = { [weak self] in self?.next() }
        nowPlaying.onPrevious = { [weak self] in self?.previous() }
        nowPlaying.onSeek = { [weak self] time in self?.seek(to: time) }
    }

    /// A loaded track played to its end: sync the queue and refill lookahead.
    private func itemDidFinish(_ item: AVPlayerItem?) {
        guard let item, loaded.first?.item === item else { return }
        report(.stopped)
        let finished = queue.trackDidFinish()
        loaded.removeFirst()

        guard finished != nil else {
            // Reached the end of a non-repeating queue.
            stop()
            return
        }
        // The player already advanced to the pre-rolled next item.
        currentTrack = queue.current
        if let track = currentTrack { onNeedsArtwork?(track) }
        publish(status: .playing)
        report(.playing)
        refillLookahead()
    }

    private func tick() {
        let elapsed = player.currentTime().seconds
        var duration = player.currentItem?.duration.seconds ?? 0
        if !duration.isFinite || duration <= 0 { duration = currentTrack?.duration ?? 0 }
        snapshot.elapsed = elapsed.isFinite ? elapsed : 0
        snapshot.duration = duration
        if let track = currentTrack {
            nowPlaying.update(
                track: track, elapsed: snapshot.elapsed, duration: duration,
                isPlaying: snapshot.status == .playing
            )
        }
    }

    // MARK: Publishing

    private func publish(status: PlaybackStatus? = nil) {
        upNext = queue.upNext
        var snap = snapshot
        if let status { snap.status = status }
        snap.currentTrackID = queue.current?.id
        snap.repeatMode = queue.repeatMode
        snap.isShuffled = queue.isShuffled
        snap.hasNext = queue.hasNext
        snap.hasPrevious = queue.hasPrevious
        if queue.current?.id != snapshot.currentTrackID {
            snap.duration = queue.current?.duration ?? 0
        }
        snapshot = snap
        nowPlaying.setSkipEnabled(next: queue.hasNext, previous: true)
        if let track = currentTrack {
            nowPlaying.update(
                track: track, elapsed: snapshot.elapsed, duration: snapshot.duration,
                isPlaying: snapshot.status == .playing
            )
        }
    }

    private func report(_ state: PlaybackState) {
        guard let track = currentTrack, let onReport else { return }
        let report = PlaybackReport(
            track: track, state: state,
            positionSeconds: snapshot.elapsed,
            sessionID: loaded.first?.sessionID
        )
        onReport(report)
    }

    /// Provide artwork bytes for the lock screen (called by the app once the
    /// image is loaded, in response to `onNeedsArtwork`).
    public func provideArtwork(_ data: Data, for trackID: String) {
        guard currentTrack?.id == trackID else { return }
        nowPlaying.updateArtwork(data)
    }
}
