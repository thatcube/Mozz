import Foundation
import Combine
import Observation
import MozzCore
import MozzAudioEngine

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

/// Why a checkpoint was emitted. Lets a consumer debounce cheaply — a periodic
/// tick can be coalesced or dropped, while a track change or a backgrounding is
/// worth a write immediately.
public enum PlaybackCheckpointReason: String, Sendable, Hashable {
    case trackChanged
    case seeked
    case transportChanged
    case queueChanged
    case periodic
}

/// A point-in-time record of the current playback run, for cross-device
/// continuity (ADR-0010).
///
/// Emitted through ``PlaybackEngine/onCheckpoint``. Deliberately expressed in
/// this module's own types: `MozzPlayback` does not depend on `MozzContinuity`,
/// so `MozzApp` — the one module that sees both — maps this onto the wire
/// format.
public struct PlaybackCheckpoint: Sendable {
    /// Identifies one continuous run of playback.
    ///
    /// Not to be confused with `PlaybackReport.sessionID`, which is the
    /// *stream* session (Jellyfin's `PlaySessionId`) used for scrobbling a
    /// particular transcode.
    public var runID: UUID
    /// Monotonic within `runID`; orders this device's own updates.
    public var sequence: UInt64
    public var queue: PlayQueue
    public var elapsed: TimeInterval
    public var status: PlaybackStatus
    public var reason: PlaybackCheckpointReason
}

/// The playback engine. Drives the shared Rust-backed
/// ``MozzAudioEngine/AudioEngine`` (decode + ReplayGain + 10-band EQ + gapless
/// joins) while a pure ``PlayQueue`` owns ordering / shuffle / repeat.
///
/// How gapless works here: the engine holds one live decoder and one *queued*
/// decoder behind it, and swaps to the queued one the instant the current runs
/// out — no ring reset, no gap, a sample-accurate join. So we keep a *logical*
/// two-item window (the current track and the one ``PlayQueue/peekNext`` says is
/// next) and hand the next track to `AudioEngine.playNext` **as soon as it is
/// known** — `playNext` merely holds it and no longer truncates the current
/// track. We re-hand it after every advance (see ``queueNext()``), and replace it
/// if the upcoming track changes. Queueing happens at the one seam where the
/// logical window gains its second item (``refillLookaheadAsync(generation:)``),
/// never on a timer.
///
/// A repeating main-actor timer is still used, but only to *observe*: it polls
/// the engine's `currentTrackID`/`state` to notice the gapless boundary being
/// crossed (so the `PlayQueue` and history can be synced) and to notice failure —
/// the engine offers no callback into Swift. It does not decide injection timing.
/// Manual skips rebuild from the new current track via `playNow`.
///
/// One residual limitation: the engine can replace its queued next but cannot
/// drop it to *nothing* (only `stop()` clears everything). So if the upcoming
/// track is removed outright mid-playback (e.g. `clearUpNext`) after it was
/// queued, the boundary poll reconciles it to a stop within one tick rather than
/// perfectly ahead of the join. Changing the next to a *different* track is exact
/// (a replacing `playNext`).
///
/// Concurrency: `@MainActor` because it drives `AudioEngine`, publishes to
/// SwiftUI, and receives remote-command callbacks — all main-thread concerns.
/// URL resolution is `async` (it may hit the network or disk) and guarded by a
/// generation counter so rapid skips can't race stale loads onto the engine.
@MainActor
@Observable
public final class PlaybackEngine {
    public private(set) var snapshot = PlaybackSnapshot()
    /// The most recent reason playback couldn't start, or `nil` once anything
    /// plays successfully.
    ///
    /// Exists because a failed load used to do nothing observable at all — it set
    /// the status to paused and returned, so tapping a track the server can't
    /// serve looked exactly like tapping nothing. The surfaces that can say
    /// something (the player, CarPlay) need to know it happened.
    public private(set) var lastFailure: PlaybackFailure?
    public private(set) var currentTrack: Track?
    public private(set) var upNext: [Track] = []
    /// Tracks played before the current one (oldest first) — the queue's history.
    public private(set) var history: [Track] = []
    /// Bumped whenever the queue is republished — a track change, a jump, a
    /// reorder, a clear, a transport state change.
    ///
    /// Exists so the UI can react to "the queue moved under me" in constant time.
    /// Watching ``upNext`` itself means an array-equality check over every queued
    /// track on each view update, which on a shuffled library is thousands of
    /// element comparisons per scroll frame. Deliberately not driven by the 0.5s
    /// position tick, so it stays a genuine signal that something changed.
    public private(set) var queueRevision = 0

    /// Which way the *next* track change is travelling. Set by whichever
    /// transport path is about to move the queue, then consumed by ``publish()``
    /// when it sees the current track actually change. Defaults to `.forward`
    /// so an unattributed advance (a track ending, a failure skip) reads as
    /// forward motion, which is what it is.
    @ObservationIgnored
    private var pendingTransportDirection: TransportDirection = .forward

    // MARK: Combine bridge (for non-SwiftUI observers)

    /// `AppEnvironment`'s now-playing-widget + session-persistence pipeline is
    /// Combine-based. The `@Observable` migration drops the `$`-projected publishers
    /// `@Published` used to synthesize, so we bridge just the two properties that
    /// pipeline reads back into Combine. SwiftUI keeps observing the stored
    /// properties *directly* and per-property — so the 0.5s elapsed tick only
    /// re-renders views that actually read `snapshot` (the seek bar), not the whole
    /// player + queue list. That narrowing is the entire point of the migration.
    @ObservationIgnored
    public private(set) lazy var currentTrackPublisher: AnyPublisher<Track?, Never> =
        makeChangePublisher(\.currentTrack)
    @ObservationIgnored
    public private(set) lazy var snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never> =
        makeChangePublisher(\.snapshot)

    /// Bridge an `@Observable` property to a Combine publisher: seed a subject with
    /// the current value, then re-arm `withObservationTracking` after every change to
    /// forward the settled value. `onChange` fires just *before* the store mutates,
    /// so we hop to the next main-queue turn to read the new value and re-arm. Several
    /// mutations in one turn coalesce to a single (latest) emission — exactly what the
    /// throttled widget/persistence sinks want. The engine lives for the whole app
    /// session, so the re-arming closure never meaningfully outlives it.
    private func makeChangePublisher<Value>(_ keyPath: KeyPath<PlaybackEngine, Value>) -> AnyPublisher<Value, Never> {
        let subject = CurrentValueSubject<Value, Never>(self[keyPath: keyPath])
        func arm(_ engine: PlaybackEngine) {
            withObservationTracking {
                _ = engine[keyPath: keyPath]
            } onChange: { [weak engine] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let engine else { return }
                        subject.send(engine[keyPath: keyPath])
                        arm(engine)
                    }
                }
            }
        }
        arm(self)
        return subject.eraseToAnyPublisher()
    }

    /// The track a user "next" / "previous" would land on, without mutating —
    /// used by the island's swipe to decide whether a title/artist line will
    /// actually change (and therefore whether it should move). Respect repeat
    /// mode. `previous()` additionally restarts the current track when >3s in;
    /// that policy is applied by the caller, not reflected here.
    public var peekNextTrack: Track? { queue.peekNext }
    public var peekPreviousTrack: Track? { queue.peekPrevious }

    /// Optional scrobble / progress hook. The app wires this to
    /// `MusicBackend.reportPlayback`. Never blocks playback.
    @ObservationIgnored
    public var onReport: (@Sendable (PlaybackReport) -> Void)?

    /// Cross-device continuity hook (ADR-0010). Fires on track changes, seeks,
    /// transport changes, queue mutations, and periodically while playing.
    ///
    /// Deliberately separate from ``onReport``, which is scrobble-shaped: it
    /// only fires on play/pause/stop transitions, never on a seek, and never
    /// during steady playback — so a checkpoint written from it would sit at a
    /// stale position for the whole of a long track.
    @ObservationIgnored
    public var onCheckpoint: (@Sendable (PlaybackCheckpoint) -> Void)?

    /// Identifies the current run of playback for continuity. Re-minted whenever
    /// a genuinely new run starts.
    @ObservationIgnored
    public private(set) var playbackRunID = UUID()
    @ObservationIgnored
    private var checkpointSequence: UInt64 = 0
    /// Wall-clock of the last periodic checkpoint, for throttling.
    @ObservationIgnored
    private var lastPeriodicCheckpoint: Date = .distantPast
    /// How often a steadily-playing track re-checkpoints.
    @ObservationIgnored
    public var checkpointInterval: TimeInterval = 20

    /// Listening-history hook. The app wires this to append to the on-device
    /// `play_event` log. Fires `started` when a track begins, then exactly one
    /// terminal event per track — `completed` (natural end) or `skipped` (the
    /// user left before the end). Never blocks playback.
    @ObservationIgnored
    public var onPlayEvent: (@Sendable (PlayEvent) -> Void)?
    /// Called when artwork should be fetched for the lock screen.
    @ObservationIgnored
    public var onNeedsArtwork: ((Track) -> Void)?

    /// Radio hook: when set, the engine calls this as the queue nears its end to
    /// fetch more tracks (an endless "station"), then appends them. Return an
    /// empty array to stop extending. Cleared to end radio mode.
    @ObservationIgnored
    public var onQueueNearEnd: (@Sendable () async -> [Track])?
    /// Guards against firing overlapping extend requests.
    @ObservationIgnored
    private var isExtendingQueue = false
    /// Bumped whenever loaded content is replaced (play / playShuffled /
    /// startStation / stop). Doubles as the station-staleness guard AND a public
    /// "transport epoch" the app captures to detect that the user changed what's
    /// playing while an async radio fetch was in flight.
    @ObservationIgnored
    public private(set) var transportEpoch = 0
    /// Extend the queue once this few tracks remain after the current one.
    private static let radioRefillThreshold = 3

    /// Whether per-track loudness normalization (ReplayGain / Sound Check) is
    /// applied. When on, each track's `normalizationGainDB` tag is applied by the
    /// engine (the tag is always handed over via `playNow`/`playNext`; this flag
    /// picks the engine's ReplayGain *mode*). Default on.
    @ObservationIgnored
    public var normalizationEnabled: Bool = true { didSet { syncReplayGain() } }
    /// Global preamp (dB) added on top of each track's gain.
    @ObservationIgnored
    public var normalizationPreampDB: Double = 0 { didSet { syncReplayGain() } }

    /// The in-app graphic equalizer. Off by default (identical playback to before
    /// EQ existed). Its curve/on-off is pushed straight to the engine's global
    /// 10-band EQ via ``syncEqualizer()`` whenever it changes — there is no longer
    /// any per-item audio processing, so toggling it never reloads a track.
    public let equalizer = EqualizerProcessor()

    /// How many unplayable tracks in a row we'll skip past before giving up.
    ///
    /// The point is to step over a gap — a few tracks in an album that aren't
    /// downloaded — not to hunt through the library for something that works. A
    /// queue where nothing plays (the server is unreachable and nothing is
    /// downloaded) must stop and say so rather than churn silently through
    /// thousands of tracks, each with its own failing network request.
    private static let maxConsecutiveLoadFailures = 8
    /// Reset by any successful load.
    private var consecutiveLoadFailures = 0

    /// Audio-engine geometry, used to construct the engine. The old
    /// buffer-relative "lead time" that decided when to inject the next track is
    /// gone: `playNext` now genuinely queues, so the next track is handed over as
    /// soon as it is known rather than timed against the current track's end.
    private static let engineSampleRate: UInt32 = 44_100
    private static let engineChannels: UInt16 = 2
    private static let engineBufferFrames: Int = 65_536

    /// The shared decode/EQ/ReplayGain engine. Optional because construction can
    /// fail if the decode thread can't start; every use is guarded. Created once
    /// and lives for the whole app session (closed in `deinit`).
    @ObservationIgnored
    private let audio: AudioEngine?
    private let resolver: TrackURLResolver
    private let session = AudioSessionController()
    private let nowPlaying = NowPlayingCenter()

    @ObservationIgnored
    private var queue = PlayQueue()
    /// One entry in the *logical* (≤2) window of loaded items. Unlike the old
    /// `AVQueuePlayer` window this does not necessarily mirror what the engine is
    /// decoding — it models what *should* be current + next, and drives when a
    /// track is handed to the engine.
    private struct LoadedItem {
        /// Stable per-load id handed to the engine as its `trackID` and reported
        /// back through `currentTrackID`. Distinct from `Track.id` (a `String`):
        /// the engine speaks `UInt64`, and the same track can be loaded twice
        /// (repeat-one), so this is a fresh monotonic key each time.
        let key: UInt64
        let track: Track
        let url: URL
        let isLocal: Bool
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

    /// The logical current (+ lookahead) window. Head is the current track.
    @ObservationIgnored
    private var loaded: [LoadedItem] = []
    @ObservationIgnored
    private var loadGeneration = 0
    /// Monotonic source of `LoadedItem.key`. Starts at 1 so keys never collide
    /// with the engine's `0` "no track" sentinel (`currentTrackID` when idle).
    @ObservationIgnored
    private var nextTrackKey: UInt64 = 0
    /// The key we've handed to `AudioEngine.playNext` for a gapless join and are
    /// waiting for `currentTrackID` to reach; `nil` when nothing is pre-rolled.
    @ObservationIgnored
    private var prerolledKey: UInt64?
    /// The repeating main-actor timer that polls engine progress + ticks the UI
    /// position. Replaces the old periodic time-observer + end/failure
    /// notifications. Deliberately a RunLoop timer: it must not fire during the
    /// cooperative `await`s that the async tests drive, so those tests exercise
    /// the deterministic seams (`handleNaturalFinish`, direct transport) without
    /// the poll racing them.
    @ObservationIgnored
    private var progressTimer: Timer?
    /// Set while a network-drop recovery is in flight, so the poll doesn't
    /// re-enter failure handling on the still-latched `hasFailed` flag before the
    /// replacement `playNow` clears it.
    @ObservationIgnored
    private var isRecovering = false
    /// A pending backoff before a recovery re-load; cancelled if the track changes.
    @ObservationIgnored
    private var recoveryTask: Task<Void, Never>?
    /// Consecutive recovery attempts for the current item, reset by a successful
    /// (re)load, capped by ``maxRecoveryRetries``.
    @ObservationIgnored
    private var recoveryRetryCount = 0
    private static let maxRecoveryRetries = 5
    @ObservationIgnored
    private var wasPlayingBeforeInterruption = false
    /// A position to seek to once the (paused) current item finishes loading —
    /// used to restore a saved session at the right spot.
    @ObservationIgnored
    private var pendingSeek: TimeInterval?
    /// The id of the track we've emitted `.started` for and not yet terminated,
    /// so every start is paired with exactly one `completed`/`skipped`.
    @ObservationIgnored
    private var loggedTrackID: String?

    public init(resolver: TrackURLResolver) {
        self.resolver = resolver
        self.audio = AudioEngine(
            sampleRate: Self.engineSampleRate,
            channels: Self.engineChannels,
            bufferFrames: Self.engineBufferFrames
        )
        configureObservers()
        configureRemote()
        // Wire the EQ/ReplayGain state into the engine, and re-push it whenever
        // the app mutates the equalizer directly (`equalizer.apply`/`isEnabled`).
        equalizer.onChange = { [weak self] in self?.syncEqualizer() }
        syncEqualizer()
        syncReplayGain()
    }

    deinit {
        progressTimer?.invalidate()
        recoveryTask?.cancel()
        audio?.close()
    }

    // MARK: Public transport

    public var repeatMode: RepeatMode { queue.repeatMode }
    public var isShuffled: Bool { queue.isShuffled }

    /// Load a set of tracks and start playing at `startIndex`.
    public func play(tracks: [Track], startAt startIndex: Int = 0) {
        invalidateStation()   // a fresh explicit play ends any active station
        logTerminal(.skipped, position: snapshot.elapsed)
        beginPlaybackRun()
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

    /// Turn the queue that is *already* playing into an endless station, without
    /// touching the current track or its position.
    ///
    /// ``startStation(_:onNearEnd:)`` replaces the queue, which is right when
    /// someone asks for radio but wrong when the content itself was the request.
    /// A spoken "play <song>" has to start that song *now*; grafting a station on
    /// a second later by reloading the queue would restart it audibly. This
    /// attaches only the refill hook, so the song plays through and similar music
    /// follows rather than the queue falling silent.
    public func continueAsStation(onNearEnd: @escaping @Sendable () async -> [Track]) {
        guard !queue.isEmpty else { return }
        onQueueNearEnd = onNearEnd
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
        reload(autoplay: false, initialElapsed: state.elapsed)
    }

    /// Restore a queue that arrived from **another device** (ADR-0010).
    ///
    /// Distinct from ``restore(_:)``, which is the cold-launch path and
    /// deliberately no-ops when anything is already loaded. A handoff happens
    /// while the app is live and usually *does* have a restored local session
    /// showing, so this clears first — otherwise "Continue here" would silently
    /// do nothing.
    ///
    /// `order` is applied verbatim: a queue shuffled on another device cannot be
    /// re-derived here, because the balanced shuffle is biased by that device's
    /// own recency/taste scores.
    public func restoreFromContinuity(
        tracks: [Track],
        realizedOrder order: [Int],
        position: Int,
        elapsed: TimeInterval,
        repeatMode: RepeatMode,
        isShuffled: Bool,
        autoplay: Bool
    ) {
        guard !tracks.isEmpty else { return }
        invalidateStation()
        logTerminal(.skipped, position: snapshot.elapsed)
        beginPlaybackRun()
        prerolledKey = nil
        audio?.stop()
        loaded.removeAll()
        currentTrack = nil
        queue = PlayQueue()
        queue.setItems(
            tracks, realizedOrder: order, position: position,
            repeatMode: repeatMode, isShuffled: isShuffled
        )
        queue.rebuildTransientState()
        pendingSeek = elapsed > 1 ? elapsed : nil
        if autoplay { try? session.activate() }
        reload(autoplay: autoplay, initialElapsed: elapsed)
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
        audio?.resume()
        publish(status: .playing)
        report(.playing)
        emitCheckpoint(.transportChanged)
        // Covers the paused-load case (e.g. `previous()` while paused): the
        // track was loaded without a `.started`, so log it now that it plays.
        if loggedTrackID == nil { logStart(track) }
    }

    public func pause() {
        audio?.pause()
        publish(status: .paused)
        report(.paused)
        emitCheckpoint(.transportChanged)
    }

    public func next() {
        // User left this track before its natural end → a skip (negative signal).
        logTerminal(.skipped, position: snapshot.elapsed)
        pendingTransportDirection = .forward
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
            // No track change, but the user did move the transport backwards —
            // signal it so the control animates instead of sitting inert.
            noteTransport(.backward)
            return
        }
        logTerminal(.skipped, position: snapshot.elapsed)
        pendingTransportDirection = .backward
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
        pendingTransportDirection = orderPosition > queue.position ? .forward : .backward
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

    /// Reorder the up-next queue: move the item at up-next offset `from` to offset
    /// `to` (both 0-based within up-next; 0 = plays next). Refills the gapless
    /// lookahead because moving the first up-next item changes the immediate next
    /// track, then republishes so the UI and persistence pick up the new order.
    public func moveUpNext(fromOffset from: Int, toOffset to: Int) {
        guard from != to else { return }
        queue.moveUpNext(fromOffset: from, toOffset: to)
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
        // Reflect the target immediately so the scrubber jumps now rather than on
        // the next 0.5s tick; the engine's own `positionSeconds` takes over after.
        snapshot.elapsed = target
        prerolledKey = nil   // a seek invalidates any in-flight gapless pre-roll
        audio?.seek(to: target)
        publish()
        emitCheckpoint(.seeked)
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
        prerolledKey = nil
        audio?.stop()
        loaded.removeAll()
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
    /// `initialElapsed == nil` preserves the current position; new tracks use 0.
    private func reload(autoplay: Bool, logStartOnLoad: Bool = true,
                        initialElapsed: TimeInterval? = 0) {
        loadGeneration += 1
        let generation = loadGeneration
        cancelRecovery()          // a fresh load abandons any in-flight recovery
        prerolledKey = nil
        audio?.stop()
        loaded.removeAll()
        if let initialElapsed {
            if initialElapsed == 0 { pendingSeek = nil }
            // Publish the new track with its own starting position immediately.
            // Otherwise a rapid skip after seeking briefly gives the incoming
            // track the outgoing track's seek target until the next 0.5s tick.
            snapshot.elapsed = initialElapsed
        }

        guard let track = queue.current else {
            currentTrack = nil
            publish(status: .idle)
            return
        }
        currentTrack = track
        publish(status: .buffering)
        onNeedsArtwork?(track)
        emitCheckpoint(.trackChanged)
        // Emit `.started` on intent (synchronously), so it's paired correctly
        // with the terminal event even if the async URL resolve below is slow
        // or fails. A paused load (autoplay == false) logs its start on resume.
        if autoplay && logStartOnLoad { logStart(track) }

        Task { [weak self] in
            guard let self else { return }
            do {
                let loadedItem = try await self.makeLoadedItem(for: track, startSeconds: 0)
                guard generation == self.loadGeneration else { return }
                let seek = self.pendingSeek
                // A saved transcode session can't be range-seeked to the resume
                // point; re-request it at the server offset instead.
                if loadedItem.requiresServerSeek, let seek, seek > 0 {
                    self.pendingSeek = nil
                    self.loaded = [loadedItem]
                    self.reloadCurrent(atElapsed: seek, reason: .seek, autoplay: autoplay)
                    return
                }
                self.pendingSeek = nil
                self.loaded = [loadedItem]
                self.startEngine(with: loadedItem, autoplay: autoplay,
                                 seekTo: (seek ?? 0) > 0 ? seek : nil)
                self.consecutiveLoadFailures = 0
                self.lastFailure = nil
                if autoplay {
                    self.publish(status: .playing)
                    self.report(.playing)
                } else {
                    self.publish(status: .paused)
                }
                await self.refillLookaheadAsync(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.loadGeneration else { return }
                self.handleLoadFailure(track: track, error: error, autoplay: autoplay)
            }
        }
    }

    /// Hand a resolved item to the engine as the current track. Builds a stream
    /// from the resolved URL (`FileStream` for a local file, `HTTPStream` for a
    /// remote one) and starts it via `playNow`; a non-zero `seekTo` moves the
    /// playhead after starting, and a non-autoplay load is immediately paused so
    /// it sits ready. A `nil` stream (e.g. a local file that no longer exists) is
    /// NOT a failure here — the logical `loaded`/`currentTrack` state stands and
    /// the poll/advance path handles the silence.
    private func startEngine(with item: LoadedItem, autoplay: Bool, seekTo: TimeInterval?) {
        isRecovering = false
        prerolledKey = nil
        guard let audio, let stream = makeStream(url: item.url, isLocal: item.isLocal) else { return }
        let ext = item.url.pathExtension.isEmpty ? nil : item.url.pathExtension
        audio.playNow(stream: stream, trackID: item.key,
                      gainDB: item.track.normalizationGainDB, fileExtension: ext)
        if let seekTo, seekTo > 0 { audio.seek(to: seekTo) }
        if !autoplay { audio.pause() }
    }

    /// Build an engine stream for a resolved URL, or `nil` when one can't be made
    /// (a local file that can't be opened). Remote URLs always build a stream.
    private func makeStream(url: URL, isLocal: Bool) -> AudioEngine.Stream? {
        if isLocal {
            return FileStream(url: url)
        }
        return HTTPStream(request: URLRequest(url: url))
    }

    // MARK: Item construction & network-drop recovery

    /// Resolve `track` (at an optional server-side offset) into the metadata the
    /// engine needs to stream, seek, and recover it. Does not touch the engine —
    /// the caller decides whether to `playNow`/`playNext` it.
    private func makeLoadedItem(for track: Track, startSeconds: TimeInterval) async throws -> LoadedItem {
        let resolved = try await resolver.resolve(track, startSeconds: startSeconds)
        nextTrackKey += 1
        return LoadedItem(
            key: nextTrackKey,
            track: track,
            url: resolved.url,
            isLocal: resolved.isLocal,
            sessionID: resolved.sessionID,
            // The offset only "took" if this is a server-seek transcode; otherwise
            // the URL is unchanged and we seek natively (base offset stays 0).
            startOffset: resolved.requiresServerSeek ? startSeconds : 0,
            requiresServerSeek: resolved.requiresServerSeek,
            isStreamed: !resolved.isLocal
        )
    }

    // MARK: Network-drop recovery

    /// Cancel any pending recovery backoff (called when the track changes).
    private func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryRetryCount = 0
        isRecovering = false
    }

    /// The engine reported a decode/stream failure (`hasFailed`). Retry only when
    /// the engine classifies the failure as *retryable* (a transient stream
    /// interruption) — and then only for a streamed item under the retry cap,
    /// rebuilding it at the last position after an exponential backoff. An
    /// unsupported or corrupt file is permanent: skip straight to the next track
    /// rather than retrying something that will never decode.
    ///
    /// The transient-vs-permanent judgement comes from the engine
    /// (`failureIsRetryable`), not from mapping error codes here — so the two
    /// shells can't drift on which failures are worth retrying.
    private func handleEngineFailure() {
        guard recoveryTask == nil else { return }   // a retry is already scheduled
        isRecovering = true
        guard audio?.failureIsRetryable == true,
              loaded.first?.isStreamed == true,
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

    /// A track that wouldn't load at all — most often the server being
    /// unreachable for something that isn't downloaded.
    ///
    /// Rather than stopping dead on the first gap, step over it: the user asked
    /// for this queue, and skipping to the next track they chose is far less
    /// surprising than silence (and much less than substituting something they
    /// didn't choose). Bounded by `maxConsecutiveLoadFailures`, so a queue where
    /// nothing is playable reports the failure instead of grinding through it.
    private func handleLoadFailure(track: Track, error: Error, autoplay: Bool) {
        consecutiveLoadFailures += 1
        let reason = PlaybackFailure.Reason(error)
        // Only skip while playback was actually meant to be running. A paused
        // session restore that fails should just stay put.
        guard autoplay,
              consecutiveLoadFailures < Self.maxConsecutiveLoadFailures,
              queue.peekNext != nil else {
            lastFailure = PlaybackFailure(
                track: track, reason: reason, skippedTracks: consecutiveLoadFailures - 1
            )
            consecutiveLoadFailures = 0
            publish(status: .paused)
            return
        }
        lastFailure = PlaybackFailure(track: track, reason: reason, skippedTracks: 0)
        logTerminal(.skipped, position: 0)
        guard queue.advance() != nil else {
            publish(status: .paused)
            return
        }
        reload(autoplay: true)
        maybeExtendQueue()
    }

    /// Recovery is exhausted (or the error isn't a transient network blip): treat
    /// the track as un-completable and advance, so playback doesn't dead-end.
    private func advanceAfterUnrecoverableFailure() {
        cancelRecovery()
        logTerminal(.skipped, position: snapshot.elapsed)
        pendingTransportDirection = .forward
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
        prerolledKey = nil
        audio?.stop()
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
                self.loaded = [loadedItem]
                // A server-seek transcode already starts at `elapsed` (its
                // playhead 0 = startOffset); a range-seekable stream is started
                // then native-seeked to `elapsed`.
                self.startEngine(with: loadedItem, autoplay: wasPlaying,
                                 seekTo: (!useServerSeek && elapsed > 0) ? elapsed : nil)
                if wasPlaying {
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
                self.isRecovering = false
                self.publish(status: .paused)
            }
        }
    }

    /// Ensure the logical window holds the next track for gapless advance.
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
            // may have changed the next track while we were resolving. Only append
            // if this resolve still matches the queue's next track and nothing
            // else was appended meanwhile — otherwise a slow/older resolve could
            // win the race and pre-roll a stale track.
            guard generation == loadGeneration,
                  loaded.count == 1,
                  queue.peekNext?.id == nextTrack.id else { return }
            loaded.append(loadedItem)
            // The logical window now has its next item, so hand it to the engine
            // right away: `playNext` holds it behind the current decoder and swaps
            // in gaplessly at the boundary. This is the single seam where the next
            // is queued — startup, advance, and post-eviction all flow through the
            // append above, so none of them time the hand-over.
            queueNext()
        } catch {
            // Leave the lookahead empty; we'll build it on the boundary instead.
        }
    }

    /// Drop an already-modelled next item when it no longer matches the queue's
    /// current `peekNext` (returns whether it evicted). Keeps the logical lookahead
    /// honest after mutations that change the upcoming track without a full
    /// `reload` — `setShuffle`/`setRepeatMode`/`append`/`insertNext`/`playNext`.
    /// The normal advance path (where the model matches) is a no-op.
    ///
    /// Clearing `prerolledKey` here is what lets the next ``queueNext()`` re-hand
    /// the replacement: a fresh `playNext` replaces the decoder the engine was
    /// holding. If the upcoming track is instead removed *outright* (no
    /// replacement resolves), the engine keeps holding the now-stale decoder — it
    /// has no single-item dequeue — and the boundary poll reconciles that to a
    /// stop within one tick.
    @discardableResult
    private func evictStaleLookahead() -> Bool {
        guard loaded.count == 2,
              loaded[1].track.id != queue.peekNext?.id else { return false }
        if prerolledKey == loaded[1].key { prerolledKey = nil }
        loaded.removeLast()
        return true
    }

    // MARK: Equalizer & normalization

    /// Push the current ReplayGain mode + preamp to the engine. The per-track gain
    /// *tag* is always handed over at `playNow`/`playNext`; this decides whether
    /// the engine applies it (mode `.track` when on, `.off` when off). Live —
    /// toggling normalization mid-track needs no reload.
    private func syncReplayGain() {
        audio?.setReplayGain(mode: normalizationEnabled ? .track : .off,
                             preampDB: normalizationPreampDB)
    }

    /// Push the current EQ curve + on/off to the engine's global 10-band EQ. Live
    /// and glitch-free — no per-item processing, so this never reloads a track.
    private func syncEqualizer() {
        audio?.setEqualizer(gainsDB: equalizer.settings.gains,
                            preampDB: equalizer.settings.preampDB,
                            enabled: equalizer.isEnabled)
    }

    /// Whether the graphic EQ is on / the current curve.
    public var equalizerEnabled: Bool { equalizer.isEnabled }
    public var equalizerSettings: EqualizerSettings { equalizer.settings }

    /// Turn the EQ on or off. The engine applies EQ globally, so this is a live,
    /// glitch-free toggle — it pushes the new state to the engine (via the
    /// `equalizer.onChange` hook) with no reload, preserving track and position.
    public func setEqualizerEnabled(_ enabled: Bool) {
        guard equalizer.isEnabled != enabled else { return }
        equalizer.isEnabled = enabled   // fires onChange → syncEqualizer()
    }

    /// Apply a new EQ curve — a live, glitch-free update pushed straight to the
    /// engine's global EQ (via `equalizer.onChange`), no reload.
    public func updateEqualizer(_ settings: EqualizerSettings) {
        equalizer.apply(settings)       // fires onChange → syncEqualizer()
    }

    // MARK: Observers

    private func configureObservers() {
        // A RunLoop timer (not a DispatchQueue source) so it fires on the app's
        // main runloop but NOT during the cooperative `await`s that the async
        // tests drive — those exercise the deterministic seams directly. It polls
        // the engine for boundary/failure and ticks the UI position.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pollEngineProgress()
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer

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

    /// Poll the engine for the two things the AVFoundation notifications used to
    /// tell us — there is no callback into Swift: that the audio crossed into the
    /// queued next track (a natural finish) or that it failed. Runs off the 0.5s
    /// timer while a track is loaded. It does NOT decide when to queue the next
    /// track; that happens eagerly in ``queueNext()`` the moment the next is known.
    private func pollEngineProgress() {
        guard let audio, currentTrack != nil else { return }
        if audio.hasFailed {
            if !isRecovering { handleEngineFailure() }
            return
        }
        // The audio crossed gaplessly into the track we queued: the engine now
        // reports that track's id. Reconcile the queue/history to match.
        if let key = prerolledKey, audio.currentTrackID == key {
            prerolledKey = nil
            handleNaturalFinish()
            return
        }
        if audio.state == .ended {
            if loaded.count >= 2 {
                // The next track was modelled but never actually queued into the
                // engine (its stream couldn't be built — e.g. a local file that
                // vanished), so the decoder ran dry instead of swapping. Advance
                // and start it explicitly — a rare, small gap rather than silence.
                prerolledKey = nil
                handleNaturalFinish()
                if currentTrack != nil, let current = loaded.first {
                    startEngine(with: current, autoplay: true, seekTo: nil)
                }
            } else {
                // End of a non-repeating queue → stop().
                handleNaturalFinish()
            }
            return
        }
    }

    /// Hand the modelled next track to the engine so its decoder is held ready and
    /// swaps in with no gap when the current track ends. Called the moment the
    /// logical window gains its second item (and after every advance), NOT on a
    /// timer: `playNext` now genuinely queues — it holds the decoder behind the
    /// current one and no longer truncates anything — so queueing early is exactly
    /// what makes the join sample-accurate.
    ///
    /// Idempotent: `prerolledKey` guards against re-queueing the same track. When
    /// the upcoming track *changes*, ``evictStaleLookahead()`` clears that guard so
    /// the next `queueNext` hands over the replacement — a fresh `playNext`
    /// replaces the engine's held decoder.
    private func queueNext() {
        guard prerolledKey == nil, loaded.count >= 2, let audio else { return }
        let next = loaded[1]
        guard next.track.id == queue.peekNext?.id else { return }
        guard let stream = makeStream(url: next.url, isLocal: next.isLocal) else { return }
        let ext = next.url.pathExtension.isEmpty ? nil : next.url.pathExtension
        audio.playNext(stream: stream, trackID: next.key,
                       gainDB: next.track.normalizationGainDB, fileExtension: ext)
        prerolledKey = next.key
    }

    /// The queue-advance + history-logging half of a natural track end. Kept
    /// `internal` and free of any engine calls so it can be unit-tested directly,
    /// and so both the gapless-boundary and end-of-queue poll paths can drive it.
    func handleNaturalFinish() {
        report(.stopped)
        // The track reached its natural end → a completion (positive signal).
        logTerminal(.completed, position: currentTrack?.duration)
        pendingTransportDirection = .forward
        let advanced = queue.trackDidFinish()
        if !loaded.isEmpty { loaded.removeFirst() }

        guard advanced != nil else {
            // Reached the end of a non-repeating queue.
            stop()
            return
        }
        // The engine already advanced into the pre-rolled next track (gapless), or
        // the caller will start it (`.ended` fallback). `loaded.first` is now that
        // next item; only the queue + history bookkeeping happens here.
        currentTrack = queue.current
        // Re-arm the recovery budget for the newly-current item.
        cancelRecovery()
        if let track = currentTrack {
            onNeedsArtwork?(track)
            logStart(track)
        }
        snapshot.elapsed = 0
        publish(status: .playing)
        report(.playing)
        refillLookahead()
        maybeExtendQueue()
    }

    private func tick() {
        guard currentTrack != nil else { return }
        // A server-seeked/recovered transcode's playhead 0 is `startOffset` into
        // the track, so add it back to keep the reported position absolute.
        let base = loaded.first?.startOffset ?? 0
        let raw = audio?.positionSeconds ?? 0
        let elapsed = (raw.isFinite ? raw : 0) + base
        // The engine exposes no track duration, so the absolute duration comes
        // from the track's own metadata (a behavior change from the old engine,
        // which refined it from the decoded asset). Fall back to the last-known
        // snapshot duration if the track somehow carries none.
        var duration = currentTrack?.duration ?? 0
        if duration <= 0 { duration = snapshot.duration }
        snapshot.elapsed = elapsed.isFinite ? elapsed : 0
        snapshot.duration = duration
        if let track = currentTrack {
            nowPlaying.update(
                track: track, elapsed: snapshot.elapsed, duration: duration,
                isPlaying: snapshot.status == .playing
            )
        }
        // Steady playback produces no other signal, so the periodic checkpoint
        // has to come from here — otherwise a long track's stored position stays
        // where it was when the track started.
        if snapshot.status == .playing,
           Date().timeIntervalSince(lastPeriodicCheckpoint) >= checkpointInterval {
            emitCheckpoint(.periodic)
        }
    }

    // MARK: Publishing

    private func publish(status: PlaybackStatus? = nil) {
        upNext = queue.upNext
        history = queue.history
        queueRevision &+= 1
        var snap = snapshot
        if let status { snap.status = status }
        snap.currentTrackID = queue.current?.id
        snap.repeatMode = queue.repeatMode
        snap.isShuffled = queue.isShuffled
        snap.hasNext = queue.hasNext
        snap.hasPrevious = queue.hasPrevious
        if queue.current?.id != snapshot.currentTrackID {
            snap.duration = queue.current?.duration ?? 0
            // A move between two tracks is a transport event the UI animates.
            // Starting playback from nothing isn't — there's no outgoing glyph
            // to hand over from, so the player would animate on first play.
            if snapshot.currentTrackID != nil, queue.current != nil {
                snap.transportDirection = pendingTransportDirection
                snap.transportGeneration &+= 1
            }
        }
        pendingTransportDirection = .forward
        snapshot = snap
        nowPlaying.setSkipEnabled(next: queue.hasNext, previous: true)
        if let track = currentTrack {
            nowPlaying.update(
                track: track, elapsed: snapshot.elapsed, duration: snapshot.duration,
                isPlaying: snapshot.status == .playing
            )
        }
    }

    /// Record a transport move that didn't change the current track (a skip-back
    /// that restarts the song), so the UI still animates the control.
    private func noteTransport(_ direction: TransportDirection) {
        var snap = snapshot
        snap.transportDirection = direction
        snap.transportGeneration &+= 1
        snapshot = snap
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

    /// Emit a continuity checkpoint. Cheap and non-blocking; the consumer owns
    /// debouncing and any network write.
    func emitCheckpoint(_ reason: PlaybackCheckpointReason) {
        guard let onCheckpoint, !queue.isEmpty else { return }
        checkpointSequence &+= 1
        if reason == .periodic { lastPeriodicCheckpoint = Date() }
        onCheckpoint(PlaybackCheckpoint(
            runID: playbackRunID,
            sequence: checkpointSequence,
            queue: queue,
            elapsed: snapshot.elapsed,
            status: snapshot.status,
            reason: reason
        ))
    }

    /// Start a new continuity run. Called when playback begins from a genuinely
    /// new source rather than continuing the current one.
    private func beginPlaybackRun() {
        playbackRunID = UUID()
        checkpointSequence = 0
        lastPeriodicCheckpoint = .distantPast
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

/// The coordinator the app and ``PlaybackEngine`` talk to for the graphic EQ.
///
/// Owns the authoritative ``EqualizerSettings`` and the master on/off switch. The
/// Rust ``AudioEngine`` does the actual ten-band equalisation globally, so this no
/// longer mints per-item DSP taps (the old `AudioEqualizerTap` did) — it just
/// holds state and notifies its owner via `onChange` whenever the curve or the
/// master switch moves, so `PlaybackEngine` can push the new state to the engine.
@MainActor
public final class EqualizerProcessor {
    /// The master switch. Toggling it notifies the owner so the engine's global EQ
    /// is enabled/disabled live (no reload, no gap).
    public var isEnabled: Bool { didSet { onChange?() } }

    /// The current curve. `apply(_:)` mutates this and notifies the owner.
    public private(set) var settings: EqualizerSettings

    /// Set by ``PlaybackEngine`` after construction to route changes to the engine.
    /// nil during `init`, so mutating `isEnabled`/`settings` at construction time
    /// does not fire.
    var onChange: (() -> Void)?

    public init(settings: EqualizerSettings = .flat, enabled: Bool = false) {
        self.settings = settings
        self.isEnabled = enabled
    }

    /// Replace the curve and notify the owner — a glitch-free live update pushed
    /// straight to the engine's global EQ (no reload, no gap).
    public func apply(_ newSettings: EqualizerSettings) {
        settings = newSettings
        onChange?()
    }
}
