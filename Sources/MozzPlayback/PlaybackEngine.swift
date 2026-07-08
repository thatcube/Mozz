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
    /// Tracks played before the current one (oldest first) — the queue's history.
    @Published public private(set) var history: [Track] = []

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

    /// Radio hook: when set, the engine calls this as the queue nears its end to
    /// fetch more tracks (an endless "station"), then appends them. Return an
    /// empty array to stop extending. Cleared to end radio mode.
    public var onQueueNearEnd: (@Sendable () async -> [Track])?
    /// Guards against firing overlapping extend requests.
    private var isExtendingQueue = false
    /// Bumped whenever loaded content is replaced (play / playShuffled /
    /// startStation / stop). Doubles as the station-staleness guard AND a public
    /// "transport epoch" the app captures to detect that the user changed what's
    /// playing while an async radio fetch was in flight.
    public private(set) var transportEpoch = 0
    /// Extend the queue once this few tracks remain after the current one.
    private static let radioRefillThreshold = 3

    /// Whether per-track loudness normalization (ReplayGain / Sound Check) is
    /// applied. When on, a track's `normalizationGainDB` is turned into an audio
    /// mix so tracks play at a consistent level. Default on.
    public var normalizationEnabled: Bool = true
    /// Global preamp (dB) added on top of each track's gain.
    public var normalizationPreampDB: Double = 0

    /// The in-app graphic equalizer. Off by default (identical playback to before
    /// EQ existed). When enabled, an `MTAudioProcessingTap` is attached per item
    /// alongside the normalization volume in a single audio mix. Drive it through
    /// `setEqualizerEnabled(_:)` / `updateEqualizer(_:)` so master on/off rebuilds
    /// loaded items (a hard requirement for gapless: all queued items must be
    /// homogeneously tapped or untapped).
    public let equalizer = EqualizerProcessor()

    private let player = AVQueuePlayer()
    private let resolver: TrackURLResolver
    private let session = AudioSessionController()
    private let nowPlaying = NowPlayingCenter()

    private var queue = PlayQueue()
    /// One entry in the player's small (≤2) window of loaded items.
    private struct LoadedItem {
        let item: AVPlayerItem
        let track: Track
        let sessionID: String?
        /// Absolute seconds into the track at which this item's playhead 0 sits.
        /// Non-zero only for a server-side-seeked/recovered progressive transcode
        /// (which is re-requested at an offset); `tick()` adds it back so the UI
        /// position stays absolute.
        var startOffset: TimeInterval = 0
        /// This item is a non-range-seekable transcode: seek/recovery must
        /// re-resolve the URL with a server offset rather than seek natively.
        var requiresServerSeek: Bool = false
        /// Streamed (not a local file) — eligible for network-drop recovery.
        var isStreamed: Bool = false
    }

    /// Tracks currently loaded into the player, aligned with `player.items()`.
    private var loaded: [LoadedItem] = []
    private var loadGeneration = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// Belt-and-suspenders failure signal alongside the item-status KVO: some
    /// mid-stream drops surface as this notification. Routed to the same recovery.
    private var failedObserver: NSObjectProtocol?
    /// KVO on the current item's `status`, to detect a terminal `.failed` (a
    /// dropped stream) and recover. Re-pointed whenever the current item changes.
    private var currentItemStatusObserver: AnyCancellable?
    /// A pending backoff before a recovery re-load; cancelled if the track changes.
    private var recoveryTask: Task<Void, Never>?
    /// Consecutive recovery attempts for the current item; reset once an item
    /// reaches `.readyToPlay` (so a stream that plays then drops later gets a
    /// fresh budget), capped by ``maxRecoveryRetries``.
    private var recoveryRetryCount = 0
    private static let maxRecoveryRetries = 5
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
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        currentItemStatusObserver?.cancel()
        recoveryTask?.cancel()
    }

    // MARK: Public transport

    public var repeatMode: RepeatMode { queue.repeatMode }
    public var isShuffled: Bool { queue.isShuffled }

    /// Load a set of tracks and start playing at `startIndex`.
    public func play(tracks: [Track], startAt startIndex: Int = 0) {
        invalidateStation()   // a fresh explicit play ends any active station
        logTerminal(.skipped, position: snapshot.elapsed)
        queue.setItems(tracks, startingAt: startIndex)
        try? session.activate()
        reload(autoplay: true)
    }

    /// Start an endless "station": load an initial batch and keep it topped up
    /// via `onNearEnd` as it plays down. Forces shuffle + repeat off (the queue
    /// extends rather than loops, and the batch is already ranked); a normal
    /// `play`/`playShuffled` ends the station.
    public func startStation(_ tracks: [Track],
                             onNearEnd: @escaping @Sendable () async -> [Track]) {
        invalidateStation()
        logTerminal(.skipped, position: snapshot.elapsed)
        queue.setShuffle(false)
        queue.setRepeatMode(.off)
        queue.setItems(tracks, startingAt: 0)
        onQueueNearEnd = onNearEnd
        try? session.activate()
        reload(autoplay: true)
        maybeExtendQueue()
    }

    /// Load a set of tracks and start playing a freshly balanced shuffle. The
    /// single "Shuffle" entry point for every browse/detail surface: it turns
    /// shuffle on and picks a random-feeling first track, so behavior is
    /// identical everywhere.
    ///
    /// `recencyScores` (track id → 0…1) biases recently-played tracks toward the
    /// end so large shuffles feel fresh. `tasteScores` (track id → 0…1) biases
    /// higher-affinity tracks toward the front ("Smart Shuffle").
    public func playShuffled(_ tracks: [Track],
                             recencyScores: [String: Double]? = nil,
                             tasteScores: [String: Double]? = nil) {
        invalidateStation()   // a fresh explicit shuffle ends any active station
        logTerminal(.skipped, position: snapshot.elapsed)
        queue.setItemsShuffled(tracks, recencyScores: recencyScores, tasteScores: tasteScores)
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
        // Starting fresh playback from an empty queue is a new session — end any
        // pending/active station so a slow radio fetch can't hijack it. (Adding
        // to a non-empty queue, incl. a live station's own extend, must not.)
        if wasEmpty { invalidateStation() }
        queue.insertNext(tracks)
        if wasEmpty { reload(autoplay: true) } else { refillLookahead() }
        publish()
    }

    /// Append tracks to the end of the queue.
    public func append(_ tracks: [Track]) {
        let wasEmpty = queue.isEmpty
        if wasEmpty { invalidateStation() }
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
        maybeExtendQueue()
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

    /// Jump to a specific row in the queue (an index into the play order, as the
    /// history / up-next lists present it) and play it. Mirrors ``next()``: the
    /// outgoing track counts as a skip, then we reload from the new position.
    public func jump(toOrderPosition orderPosition: Int) {
        // Tapping the currently-playing row is a no-op: don't restart it or log a
        // phantom skip (which would bias shuffle history).
        guard orderPosition != queue.position else { return }
        logTerminal(.skipped, position: snapshot.elapsed)
        _ = queue.jump(toOrderPosition: orderPosition)
        reload(autoplay: snapshot.status == .playing || snapshot.status == .buffering)
        maybeExtendQueue()
    }

    /// Drop the queue's played history, keeping the current track + up-next.
    public func clearHistory() {
        queue.clearHistory()
        // Base `tracks`/`order` were rebuilt, so any prefetched pre-roll keyed on
        // old base indices is stale — refill against the new set.
        refillLookahead()
        publish()
    }

    /// Drop the queue's up-next, keeping the played history + current track.
    public func clearUpNext() {
        queue.clearUpNext()
        refillLookahead()
        publish()
    }

    public func seek(to seconds: TimeInterval) {
        let target = max(0, seconds)
        if loggedTrackID != nil, let track = currentTrack {
            onPlayEvent?(PlayEvent(trackID: track.id, kind: .seek,
                                   positionSeconds: target, durationSeconds: track.duration))
        }
        // A progressive transcode isn't byte-range seekable (Jellyfin serves it
        // `Accept-Ranges: none`); the only way to move the playhead is to
        // re-request the stream at a server-side offset and rebuild the item.
        if loaded.first?.requiresServerSeek == true {
            reloadCurrent(atElapsed: target, reason: .seek)
            return
        }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
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
        cancelRecovery()
        player.pause()
        player.removeAllItems()
        loaded.removeAll()
        currentItemStatusObserver = nil
        invalidateStation()   // stopping ends any active station
        report(.stopped)
        currentTrack = nil
        upNext = []
        snapshot = PlaybackSnapshot(repeatMode: queue.repeatMode, isShuffled: queue.isShuffled)
        nowPlaying.clear()
        session.deactivate()
    }

    // MARK: Loading

    /// Rebuild the player from the queue's current track (+ lookahead).
    ///
    /// `logStartOnLoad` is `false` only for an in-place rebuild (e.g. superseding
    /// an in-flight load when the equalizer is toggled mid-load) where the same
    /// track keeps playing and must not emit a fresh `.started` listening event.
    private func reload(autoplay: Bool, logStartOnLoad: Bool = true) {
        loadGeneration += 1
        let generation = loadGeneration
        cancelRecovery()          // a fresh load abandons any in-flight recovery
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
        if autoplay && logStartOnLoad { logStart(track) }

        Task { [weak self] in
            guard let self else { return }
            do {
                let loadedItem = try await self.makeLoadedItem(for: track, startSeconds: 0)
                guard generation == self.loadGeneration else { return }
                self.player.insert(loadedItem.item, after: nil)
                self.loaded = [loadedItem]
                self.observeCurrentItemStatus()
                if let seek = self.pendingSeek, seek > 0 {
                    self.pendingSeek = nil
                    // A saved transcode session can't be range-seeked to the
                    // resume point; re-request it at the server offset instead.
                    if loadedItem.requiresServerSeek {
                        self.reloadCurrent(atElapsed: seek, reason: .seek, autoplay: autoplay)
                        return
                    }
                    self.player.seek(to: CMTime(seconds: seek, preferredTimescale: 600),
                                     completionHandler: { _ in })
                } else {
                    self.pendingSeek = nil
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

    // MARK: Item construction & network-drop recovery

    /// Resolve `track` (at an optional server-side offset) and build a normalized
    /// player item plus the metadata the engine needs to seek/recover it.
    private func makeLoadedItem(for track: Track, startSeconds: TimeInterval) async throws -> LoadedItem {
        let resolved = try await resolver.resolve(track, startSeconds: startSeconds)
        let item = AVPlayerItem(url: resolved.url)
        // Attach normalization (+ the EQ tap when enabled). When EQ is on this
        // awaits the audio-track load and builds the mix BEFORE the caller enqueues
        // the item, so the tap fires on AVQueuePlayer's pre-rolled item.
        await installAudioProcessing(on: item, gainDB: track.normalizationGainDB)
        return LoadedItem(
            item: item,
            track: track,
            sessionID: resolved.sessionID,
            // The offset only "took" if this is a server-seek transcode; otherwise
            // the URL is unchanged and we seek natively (base offset stays 0).
            startOffset: resolved.requiresServerSeek ? startSeconds : 0,
            requiresServerSeek: resolved.requiresServerSeek,
            isStreamed: !resolved.isLocal
        )
    }

    /// Observe the current item's `status` so a terminal `.failed` (a dropped
    /// stream) triggers recovery, and a `.readyToPlay` refreshes the retry budget.
    /// Only streamed items are watched — a local file failing isn't worth retrying.
    private func observeCurrentItemStatus() {
        currentItemStatusObserver = nil
        guard let entry = loaded.first, entry.isStreamed else { return }
        let item = entry.item
        currentItemStatusObserver = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch status {
                    case .failed: self.handleItemFailure(item)
                    case .readyToPlay: self.recoveryRetryCount = 0
                    default: break
                    }
                }
            }
    }

    /// Cancel any pending recovery backoff (called when the track changes).
    private func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryRetryCount = 0
    }

    /// The current item hit a terminal `.failed`. If it's a transient network
    /// error and we're under the retry cap, rebuild the item (at the last
    /// position) after an exponential backoff; otherwise skip to the next track.
    private func handleItemFailure(_ item: AVPlayerItem) {
        guard loaded.first?.item === item else { return }   // stale / lookahead item
        guard recoveryTask == nil else { return }           // a retry is already scheduled
        guard let nsError = item.error as NSError?,
              Self.isTransientNetworkError(nsError),
              recoveryRetryCount < Self.maxRecoveryRetries else {
            advanceAfterUnrecoverableFailure()
            return
        }
        recoveryRetryCount += 1
        let delay = min(pow(2.0, Double(recoveryRetryCount - 1)), 30.0)  // 1,2,4,8,16s (cap 30)
        let targetElapsed = snapshot.elapsed
        let generation = loadGeneration
        publish(status: .buffering)
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
            self.recoveryTask = nil
            self.reloadCurrent(atElapsed: targetElapsed, reason: .recovery)
        }
    }

    /// Recovery is exhausted (or the error isn't a transient network blip): treat
    /// the track as un-completable and advance, so playback doesn't dead-end.
    private func advanceAfterUnrecoverableFailure() {
        cancelRecovery()
        logTerminal(.skipped, position: snapshot.elapsed)
        guard queue.advance() != nil else { stop(); return }
        reload(autoplay: true)
        maybeExtendQueue()
    }

    private enum ReloadReason { case seek, recovery }

    /// Rebuild only the current item, keeping the queue position — used to seek a
    /// non-range-seekable transcode (`.seek`) and to recover a dropped stream
    /// (`.recovery`). A server-seek transcode is re-requested at `elapsed`; a
    /// range-seekable stream is rebuilt and native-seeked to `elapsed`. `autoplay`
    /// overrides the derived play state (used by a paused saved-session restore).
    private func reloadCurrent(atElapsed elapsed: TimeInterval, reason: ReloadReason, autoplay: Bool? = nil) {
        guard let track = currentTrack, let existing = loaded.first else { return }
        let useServerSeek = existing.requiresServerSeek
        let wasPlaying = autoplay ?? (snapshot.status == .playing || snapshot.status == .buffering)
        loadGeneration += 1
        let generation = loadGeneration
        recoveryTask?.cancel(); recoveryTask = nil
        currentItemStatusObserver = nil
        player.pause()
        player.removeAllItems()
        loaded.removeAll()
        // Reflect the target position immediately so the scrubber jumps now (not
        // on the first tick after the rebuild) and a failure before playback
        // recovers at the right spot rather than the stale pre-seek position.
        snapshot.elapsed = elapsed
        publish(status: .buffering)

        Task { [weak self] in
            guard let self else { return }
            do {
                let loadedItem = try await self.makeLoadedItem(
                    for: track,
                    startSeconds: useServerSeek ? elapsed : 0
                )
                guard generation == self.loadGeneration else { return }
                self.player.insert(loadedItem.item, after: nil)
                self.loaded = [loadedItem]
                self.observeCurrentItemStatus()
                if !useServerSeek, elapsed > 0 {
                    self.player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600),
                                     completionHandler: { _ in })
                }
                if wasPlaying {
                    self.player.play()
                    self.publish(status: .playing)
                    self.report(.playing)
                } else {
                    self.publish(status: .paused)
                }
                await self.refillLookaheadAsync(generation: generation)
            } catch {
                guard generation == self.loadGeneration else { return }
                // Resolving is pure URL-building (or a local DB lookup) for every
                // backend — it doesn't hit the network — so a throw here isn't the
                // stream outage and retrying wouldn't help; just settle paused.
                self.publish(status: .paused)
            }
        }
    }

    /// NSURLError codes worth an automatic retry — transient connectivity, not a
    /// 4xx/decoding/fatal error. Unwraps AVFoundation's wrapper error if present.
    private static func isTransientNetworkError(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain {
            return [
                NSURLErrorTimedOut,
                NSURLErrorCannotConnectToHost,
                NSURLErrorCannotFindHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorDNSLookupFailed,
                NSURLErrorResourceUnavailable,
                NSURLErrorBadServerResponse,
            ].contains(error.code)
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isTransientNetworkError(underlying)
        }
        return false
    }

    /// Ensure the player holds the next track for gapless advance.
    private func refillLookahead() {
        let generation = loadGeneration
        Task { [weak self] in await self?.refillLookaheadAsync(generation: generation) }
    }

    /// If a radio station is active and the queue is running low, fetch and
    /// append the next batch so playback never runs dry. Guarded so overlapping
    /// low-water marks don't fire duplicate fetches, and stamped with the current
    /// station generation so a fetch that resolves after the station was
    /// replaced/stopped discards its result instead of appending into the wrong
    /// queue.
    private func maybeExtendQueue() {
        guard let onQueueNearEnd, !isExtendingQueue else { return }
        guard queue.upNext.count <= Self.radioRefillThreshold else { return }
        isExtendingQueue = true
        let epoch = transportEpoch
        Task { [weak self] in
            let more = await onQueueNearEnd()
            guard let self, epoch == self.transportEpoch else { return }
            if !more.isEmpty { self.append(more) }
            self.isExtendingQueue = false
        }
    }

    /// End any active station: clear the hook, release the extend guard, and bump
    /// the transport epoch so an in-flight extend fetch discards its (now stale)
    /// result. Called whenever loaded content is replaced.
    private func invalidateStation() {
        onQueueNearEnd = nil
        isExtendingQueue = false
        transportEpoch += 1
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
            let loadedItem = try await makeLoadedItem(for: nextTrack, startSeconds: 0)
            // Re-validate after the await: another mutation (or a second refill)
            // may have changed the next track while we were resolving. Only
            // insert if this resolve still matches the queue's next track and
            // nothing else pre-rolled meanwhile — otherwise a slow/older resolve
            // could win the race and pre-roll a stale track.
            guard generation == loadGeneration,
                  loaded.count == 1,
                  queue.peekNext?.id == nextTrack.id else { return }
            if player.canInsert(loadedItem.item, after: loaded.last?.item) {
                player.insert(loadedItem.item, after: loaded.last?.item)
                loaded.append(loadedItem)
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

    // MARK: Equalizer

    /// Attach the per-item audio mix carrying loudness normalization and, when the
    /// EQ is on, the EQ tap — consolidated into ONE mix (an input-parameters block
    /// has a single tap slot).
    ///
    ///  - **EQ off** (default; behaves exactly as before EQ existed): normalization
    ///    is attached asynchronously *after* enqueue; returns immediately.
    ///  - **EQ on**: the tap must be installed *before* the item is enqueued (or it
    ///    won't fire on the pre-rolled item), so this awaits the audio-track load
    ///    and builds the combined mix. `makeLoadedItem` awaits this before its
    ///    caller inserts.
    ///
    /// Silently no-ops for assets with no accessible audio track (HLS).
    private func installAudioProcessing(on item: AVPlayerItem, gainDB: Double?) async {
        if equalizer.isEnabled {
            await buildCombinedMix(on: item, gainDB: gainDB)
        } else {
            applyNormalization(to: item, gainDB: gainDB)
        }
    }

    /// The EQ-on path: load the audio track (bounded by a timeout so a stalled
    /// asset can't wedge enqueue), then build a single mix with the normalization
    /// volume ramp and the EQ tap.
    private func buildCombinedMix(on item: AVPlayerItem, gainDB: Double?) async {
        guard let track = await loadAudioTrack(from: item.asset, timeout: 4) else { return }
        let params = AVMutableAudioMixInputParameters(track: track)
        if normalizationEnabled, let gainDB {
            params.setVolume(NormalizationGain.linearScalar(gainDB: gainDB, preampDB: normalizationPreampDB), at: .zero)
        }
        equalizer.attach(to: params)
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }

    /// Load the first audio track of an asset, giving up after `timeout` seconds so
    /// a slow/broken asset can't block enqueue indefinitely.
    private func loadAudioTrack(from asset: AVAsset, timeout: TimeInterval) async -> AVAssetTrack? {
        await withTaskGroup(of: AVAssetTrack?.self) { group in
            group.addTask { try? await asset.loadTracks(withMediaType: .audio).first }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Whether the graphic EQ is on / the current curve.
    public var equalizerEnabled: Bool { equalizer.isEnabled }
    public var equalizerSettings: EqualizerSettings { equalizer.settings }

    /// Turn the EQ on or off. Rebuilds the loaded item(s) in place — preserving
    /// track, position, and play/pause — so the tap is added to / removed from
    /// every queued item consistently (homogeneous taps keep gapless intact). A
    /// brief re-buffer on this explicit toggle is fine; ordinary playback stays
    /// gapless.
    public func setEqualizerEnabled(_ enabled: Bool) {
        guard equalizer.isEnabled != enabled else { return }
        equalizer.isEnabled = enabled
        rebuildAudioProcessing()
    }

    /// Apply a new EQ curve — a live, glitch-free update pushed straight to the
    /// active tap(s), no reload.
    public func updateEqualizer(_ settings: EqualizerSettings) {
        equalizer.apply(settings)
    }

    /// Rebuild the current item (and its lookahead) so a master EQ on/off change
    /// takes effect while keeping the same track and position. No new listening
    /// event is emitted.
    private func rebuildAudioProcessing() {
        guard currentTrack != nil else { return }
        // If the player already auto-advanced into the pre-rolled next item but
        // `handleNaturalFinish` hasn't run yet, reconcile first so we rebuild the
        // new current track instead of restarting the one that just finished.
        if loaded.count == 2,
           loaded.first?.item !== player.currentItem,
           loaded[1].item === player.currentItem {
            handleNaturalFinish()
            guard currentTrack != nil else { return }
        }
        if loaded.first != nil {
            // Steady state: rebuild current + lookahead in place, preserving the
            // position and play/pause, and refilling the lookahead (homogeneous
            // taps). Reuses the seek path; emits no listening event.
            reloadCurrent(atElapsed: snapshot.elapsed, reason: .seek)
        } else {
            // A load is in flight (loaded not yet populated) — it already built its
            // item with the pre-toggle EQ state. Supersede it with a fresh load
            // carrying the new state, without re-logging the start.
            reload(autoplay: snapshot.status == .playing || snapshot.status == .buffering,
                   logStartOnLoad: false)
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
        failedObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let item = note.object as? AVPlayerItem else { return }
                self.handleItemFailure(item)
            }
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
        // Re-point failure recovery at the newly-current item (the old one is
        // gone). A fresh item also resets the retry budget once it plays.
        cancelRecovery()
        observeCurrentItemStatus()
        if let track = currentTrack {
            onNeedsArtwork?(track)
            logStart(track)
        }
        publish(status: .playing)
        report(.playing)
        refillLookahead()
        maybeExtendQueue()
    }

    private func tick() {
        // A server-seeked/recovered transcode's playhead 0 is `startOffset` into
        // the track, so add it back to keep the reported position absolute.
        let base = loaded.first?.startOffset ?? 0
        let raw = player.currentTime().seconds
        let elapsed = (raw.isFinite ? raw : 0) + base
        var duration = player.currentItem?.duration.seconds ?? 0
        // A server-seeked transcode's item spans only the remainder (the server
        // restarts ffmpeg at the offset), so its finite duration is
        // `total − startOffset`. Use the track's absolute duration so `elapsed`
        // (which is absolute) never exceeds it.
        if base > 0, let trackDuration = currentTrack?.duration, trackDuration > 0 {
            duration = trackDuration
        } else if !duration.isFinite || duration <= 0 {
            duration = currentTrack?.duration ?? 0
        }
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
        history = queue.history
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
