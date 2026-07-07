import Foundation
import AVFoundation
import Combine
import MozzCore

/// A serializable snapshot of what's playing — the queue (order/shuffle/repeat/
/// position) plus the elapsed position — so the app can restore the session on a
/// later cold launch (loaded and paused, ready to resume).
public struct PlaybackPersistentState: Codable, Sendable {
    public var queue: PlayQueue
    public var elapsed: TimeInterval

    public init(queue: PlayQueue, elapsed: TimeInterval) {
        self.queue = queue
        self.elapsed = elapsed
    }
}

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

    /// The track a user "next" / "previous" would land on, without mutating —
    /// used by the island's swipe to decide whether a title/artist line will
    /// actually change (and therefore whether it should move). Respect repeat
    /// mode. `previous()` additionally restarts the current track when >3s in;
    /// that policy is applied by the caller, not reflected here.
    public var peekNextTrack: Track? { queue.peekNext }
    public var peekPreviousTrack: Track? { queue.peekPrevious }

    /// Optional scrobble / progress hook. The app wires this to
    /// `MusicBackend.reportPlayback`. Never blocks playback.
    public var onReport: (@Sendable (PlaybackReport) -> Void)?
    /// Listening-history hook. The app wires this to append to the on-device
    /// `play_event` log. Fires `started` when a track begins, then exactly one
    /// terminal event per track — `completed` (natural end) or `skipped` (the
    /// user left before the end). Never blocks playback.
    public var onPlayEvent: (@Sendable (PlayEvent) -> Void)?
    /// Called when artwork should be fetched for the lock screen.
    public var onNeedsArtwork: ((Track) -> Void)?

    /// Whether per-track loudness normalization (ReplayGain / Sound Check) is
    /// applied. When on, a track's `normalizationGainDB` is turned into an audio
    /// mix so tracks play at a consistent level. Default on.
    public var normalizationEnabled: Bool = true
    /// Global preamp (dB) added on top of each track's gain.
    public var normalizationPreampDB: Double = 0

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
    /// A position to seek to once the (paused) current item finishes loading —
    /// used to restore a saved session at the right spot.
    private var pendingSeek: TimeInterval?
    /// The id of the track we've emitted `.started` for and not yet terminated,
    /// so every start is paired with exactly one `completed`/`skipped`.
    private var loggedTrackID: String?

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
        logTerminal(.skipped, position: snapshot.elapsed)
        queue.setItems(tracks, startingAt: startIndex)
        try? session.activate()
        reload(autoplay: true)
    }

    /// Load a set of tracks and start playing a freshly balanced shuffle. The
    /// single "Shuffle" entry point for every browse/detail surface: it turns
    /// shuffle on and picks a random-feeling first track, so behavior is
    /// identical everywhere.
    ///
    /// `recencyScores` (optional, track id → 0…1) biases recently-played tracks
    /// toward the end so large shuffles (whole library / all albums) feel fresh.
    public func playShuffled(_ tracks: [Track], recencyScores: [String: Double]? = nil) {
        logTerminal(.skipped, position: snapshot.elapsed)
        queue.setItemsShuffled(tracks, recencyScores: recencyScores)
        try? session.activate()
        reload(autoplay: true)
    }

    /// A serializable snapshot of the current session (queue + position), or
    /// `nil` when nothing is loaded. The app persists this to resume on relaunch.
    public var persistentState: PlaybackPersistentState? {
        guard !queue.isEmpty, currentTrack != nil else { return nil }
        return PlaybackPersistentState(queue: queue, elapsed: snapshot.elapsed)
    }

    /// Restore a saved session WITHOUT autoplaying: loads the current track
    /// paused and seeks to the saved position, so the user (or a remote command /
    /// widget button) can pick up where they left off. No-op for an empty queue.
    public func restore(_ state: PlaybackPersistentState) {
        guard !state.queue.isEmpty, currentTrack == nil, queue.isEmpty else { return }
        queue = state.queue
        // The decoded queue has no transient reshuffle-on-wrap cache (it's
        // excluded from Codable); rebuild it so the first post-restore wrap still
        // reshuffles when parked on the last slot with shuffle + repeat-all.
        queue.rebuildTransientState()
        pendingSeek = state.elapsed > 1 ? state.elapsed : nil
        reload(autoplay: false)
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
        guard let track = currentTrack else { return }
        try? session.activate()
        player.play()
        publish(status: .playing)
        report(.playing)
        // Covers the paused-load case (e.g. `previous()` while paused): the
        // track was loaded without a `.started`, so log it now that it plays.
        if loggedTrackID == nil { logStart(track) }
    }

    public func pause() {
        player.pause()
        publish(status: .paused)
        report(.paused)
    }

    public func next() {
        // User left this track before its natural end → a skip (negative signal).
        logTerminal(.skipped, position: snapshot.elapsed)
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
        logTerminal(.skipped, position: snapshot.elapsed)
        _ = queue.previous()
        reload(autoplay: snapshot.status == .playing || snapshot.status == .buffering)
    }

    public func seek(to seconds: TimeInterval) {
        if loggedTrackID != nil, let track = currentTrack {
            onPlayEvent?(PlayEvent(trackID: track.id, kind: .seek,
                                   positionSeconds: seconds, durationSeconds: track.duration))
        }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
    }

    public func setRepeatMode(_ mode: RepeatMode) {
        queue.setRepeatMode(mode)
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

    #if DEBUG
    /// Test-only: the track ids currently pre-rolled into the player, aligned
    /// with `player.items()`. Lets tests assert the gapless lookahead matches the
    /// queue after mutations.
    var lookaheadTrackIDsForTesting: [String] { loaded.map(\.track.id) }

    /// Test-only: drain the fire-and-forget reload/refill Tasks so `loaded`
    /// reflects the current queue. The stub resolver resolves without real I/O,
    /// so yielding a handful of times is sufficient.
    func awaitPendingLoadsForTesting() async {
        for _ in 0..<50 { await Task.yield() }
    }
    #endif

    public func stop() {
        // A user-initiated stop mid-track is a skip. (When called at the natural
        // end of the queue, `handleNaturalFinish` has already logged `.completed`
        // and cleared the pending track, so this no-ops — no double count.)
        logTerminal(.skipped, position: snapshot.elapsed)
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
        // Emit `.started` on intent (synchronously), so it's paired correctly
        // with the terminal event even if the async URL resolve below is slow
        // or fails. A paused load (autoplay == false) logs its start on resume.
        if autoplay { logStart(track) }

        Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await resolver.resolve(track)
                guard generation == self.loadGeneration else { return }
                let item = AVPlayerItem(url: resolved.url)
                self.applyNormalization(to: item, gainDB: track.normalizationGainDB)
                self.player.insert(item, after: nil)
                self.loaded = [(item, track, resolved.sessionID)]
                if let seek = self.pendingSeek {
                    self.pendingSeek = nil
                    self.player.seek(to: CMTime(seconds: seek, preferredTimescale: 600),
                                     completionHandler: { _ in })
                }
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
        // If a next item was already pre-rolled but the queue's next track has
        // since changed (shuffle/repeat toggled, or a queue edit, while parked on
        // the last track), evict the now-stale item. AVQueuePlayer auto-advances
        // to the pre-rolled item at the boundary, so without this it would
        // gaplessly play the wrong track while the queue reports a different one.
        evictStaleLookahead()
        guard loaded.count == 1, let nextTrack = queue.peekNext else { return }
        // Don't double-load the same track object unless repeat-one intends it.
        do {
            let resolved = try await resolver.resolve(nextTrack)
            // Re-validate after the await: another mutation (or a second refill)
            // may have changed the next track while we were resolving. Only
            // insert if this resolve still matches the queue's next track and
            // nothing else pre-rolled meanwhile — otherwise a slow/older resolve
            // could win the race and pre-roll a stale track.
            guard generation == loadGeneration,
                  loaded.count == 1,
                  queue.peekNext?.id == nextTrack.id else { return }
            let item = AVPlayerItem(url: resolved.url)
            applyNormalization(to: item, gainDB: nextTrack.normalizationGainDB)
            if player.canInsert(item, after: loaded.last?.item) {
                player.insert(item, after: loaded.last?.item)
                loaded.append((item, nextTrack, resolved.sessionID))
            }
        } catch {
            // Leave the lookahead empty; we'll rebuild on the boundary instead.
        }
    }

    /// Remove an already pre-rolled next item when it no longer matches the
    /// queue's current `peekNext` (returns whether it evicted). Keeps the gapless
    /// pre-roll honest after mutations that change the upcoming track without a
    /// full `reload` — `setShuffle`/`setRepeatMode`/`append`/`insertNext`/
    /// `playNext`. The normal advance path (where the pre-roll matches) is a
    /// no-op, so gapless playback is preserved.
    ///
    /// Only acts when `loaded` is aligned with the player (its head is the
    /// currently playing item), so it can never remove the item the player has
    /// already auto-advanced into during the brief boundary window before
    /// `handleNaturalFinish` trims `loaded`.
    @discardableResult
    private func evictStaleLookahead() -> Bool {
        guard loaded.count == 2,
              loaded.first?.item === player.currentItem,
              loaded[1].track.id != queue.peekNext?.id else { return false }
        player.remove(loaded[1].item)
        loaded.removeLast()
        return true
    }

    /// Attach an audio mix that applies the track's loudness-normalization gain
    /// (ReplayGain / Sound Check), so tracks play at a consistent level.
    ///
    /// Works for assets that expose an audio track — local downloads and
    /// direct-play originals, which is exactly where the server reports a gain.
    /// For transcoded HLS streams (no accessible audio track) it silently
    /// no-ops. Applied off the load path so it never delays time-to-first-audio;
    /// the mix takes effect as soon as the (fast, for local files) track load
    /// resolves.
    private func applyNormalization(to item: AVPlayerItem, gainDB: Double?) {
        guard normalizationEnabled, let gainDB else { return }
        let preamp = normalizationPreampDB
        Task { @MainActor in
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(NormalizationGain.linearScalar(gainDB: gainDB, preampDB: preamp), at: .zero)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
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
        handleNaturalFinish()
    }

    /// The queue-advance + history-logging half of a natural track end, split
    /// out (and `internal`) so it can be unit-tested without a real
    /// `AVPlayerItem` end-of-playback notification.
    func handleNaturalFinish() {
        report(.stopped)
        // The track reached its natural end → a completion (positive signal).
        logTerminal(.completed, position: currentTrack?.duration)
        let advanced = queue.trackDidFinish()
        if !loaded.isEmpty { loaded.removeFirst() }

        guard advanced != nil else {
            // Reached the end of a non-repeating queue.
            stop()
            return
        }
        // The player already advanced to the pre-rolled next item.
        currentTrack = queue.current
        if let track = currentTrack {
            onNeedsArtwork?(track)
            logStart(track)
        }
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

    // MARK: Listening history (play_event log)

    /// Emit `.started` for a track and mark it as the pending (not-yet-
    /// terminated) track, so it gets exactly one later `completed`/`skipped`.
    private func logStart(_ track: Track) {
        loggedTrackID = track.id
        onPlayEvent?(PlayEvent(trackID: track.id, kind: .started,
                               positionSeconds: 0, durationSeconds: track.duration))
    }

    /// Emit the terminal event for the pending track (if any) and clear it.
    /// No-ops when there is no pending track, so it's safe to call defensively
    /// from multiple transition sites without double-counting.
    private func logTerminal(_ kind: PlayEventKind, position: TimeInterval?) {
        guard let id = loggedTrackID else { return }
        loggedTrackID = nil
        guard let track = currentTrack, track.id == id else { return }
        onPlayEvent?(PlayEvent(trackID: track.id, kind: kind,
                               positionSeconds: position, durationSeconds: track.duration))
    }

    /// Provide artwork bytes for the lock screen (called by the app once the
    /// image is loaded, in response to `onNeedsArtwork`).
    public func provideArtwork(_ data: Data, for trackID: String) {
        guard currentTrack?.id == trackID else { return }
        nowPlaying.updateArtwork(data, for: trackID)
    }
}
