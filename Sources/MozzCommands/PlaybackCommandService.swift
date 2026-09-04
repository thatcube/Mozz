import Foundation
#if canImport(FoundationNetworking)
// Off Apple the URL loading system is its own module, and this service builds
// a URLRequest to hand the engine an HTTP stream.
import FoundationNetworking
#endif
import MozzAudioEngine
import MozzCore

/// One observation of the running engine, returned by every playback command.
///
/// Request/response is the wrong shape for a continuous thing, so a command
/// cannot stream progress; it can only answer "here is the engine right now."
/// Every transport command returns this so the caller sees the result of what it
/// just did, and the state query returns the identical value.
///
/// It carries the failure *kind* and the engine's own retryable verdict
/// side-by-side on purpose. A caller must never re-derive "should I retry" from
/// the kind — that mapping is the engine's, and duplicating it is exactly the
/// bug (transient collapsed into permanent) that was already fixed once.
public struct PlaybackStateSnapshot: Sendable, Equatable {
    public var state: AudioEngine.State
    /// Seconds actually heard, read from the engine's output — never a clock.
    /// The two diverge by the whole buffer, so a clock would run ahead of sound.
    public var positionSeconds: Double
    /// The engine's key for the track currently sounding (the internal track id
    /// handed to `playNow`/`playNext`). 0 when nothing is loaded.
    public var currentTrackID: UInt64
    public var hasFailed: Bool
    public var failureKind: AudioEngine.FailureKind
    public var failureIsRetryable: Bool

    public init(
        state: AudioEngine.State,
        positionSeconds: Double,
        currentTrackID: UInt64,
        hasFailed: Bool,
        failureKind: AudioEngine.FailureKind,
        failureIsRetryable: Bool
    ) {
        self.state = state
        self.positionSeconds = positionSeconds
        self.currentTrackID = currentTrackID
        self.hasFailed = hasFailed
        self.failureKind = failureKind
        self.failureIsRetryable = failureIsRetryable
    }

    /// The honest answer before any engine exists (no session has started, so no
    /// device is open): idle, silent, no failure.
    public static let idle = PlaybackStateSnapshot(
        state: .idle,
        positionSeconds: 0,
        currentTrackID: 0,
        hasFailed: false,
        failureKind: .none,
        failureIsRetryable: false
    )
}

/// Why a playback command could not be carried out. Surfaced to a shell as a
/// `Failure` (the dispatcher turns a thrown error into one) rather than a crash.
public enum PlaybackCommandError: Error, CustomStringConvertible {
    /// No track with this (server, remote) identity exists in the catalog, so
    /// there is nothing to play.
    case unknownTrack(serverId: ServerID, remoteId: String)
    /// Playback is not wired into this process. The live FFI session does not yet
    /// own a persistent engine (it builds a fresh command service per request, so
    /// one engine cannot survive between commands), so playback commands answer
    /// with this honest failure there rather than silently doing nothing. An
    /// in-process Swift shell that injects a ``PlaybackCommandService`` never
    /// sees it.
    case unavailable

    public var description: String {
        switch self {
        case .unknownTrack(let serverId, let remoteId):
            return "no track \(remoteId) on server \(serverId) to play"
        case .unavailable:
            return "playback is not available in this process"
        }
    }
}

/// Drives the one shared audio engine behind the command surface.
///
/// This is the whole point of ADR-0016: a shell that links the engine is a shell
/// that can decide how music sounds, and two of those drift. So the engine lives
/// here, behind the Facade, and reaches it through commands. The core already
/// holds the server credentials, so the core builds the authenticated byte
/// stream (via the injected ``TrackURLResolver`` and the same FileStream/
/// HTTPStream split the Apple shell uses) — no shell re-implements streaming.
///
/// An `actor` because the engine is a non-Sendable class shared across the
/// command surface; serialising every touch through the actor is how it crosses
/// into `Sendable` command land safely.
public actor PlaybackCommandService {
    /// Builds the engine. Injected so a test can supply one that does not open a
    /// real output device; the default constructs the real shared engine with
    /// the same parameters the Apple shell's PlaybackEngine uses (they are the
    /// AudioEngine initialiser defaults).
    public typealias EngineFactory = @Sendable () -> AudioEngine?

    /// Builds the byte stream for a resolved URL. Injected for the same reason;
    /// the default mirrors the shell's local-file/HTTP split.
    public typealias StreamFactory = @Sendable (ResolvedTrackURL) throws -> AudioEngine.Stream

    /// Resolves a track to a URL *for a given server*.
    ///
    /// A factory rather than one resolver, because every play command names the
    /// server it is about and a session can have several attached. A single
    /// fixed resolver would quietly play the wrong server's copy of a track
    /// whenever more than one was connected — which is not a crash, it is the
    /// right song from the wrong library, and nobody would report it as a bug.
    private let resolverFor: @Sendable (ServerID) -> TrackURLResolver?
    private let makeEngine: EngineFactory
    private let makeStream: StreamFactory

    /// Constructed lazily on the first play — deliberately NOT at init.
    ///
    /// The engine opens the output device the instant it exists. On iOS a device
    /// opened before the audio session is activated emits silence while
    /// reporting itself healthy, so an engine built at init would look fine and
    /// make no sound. Session activation is a Sink/shell concern this service
    /// cannot see; waiting until the first actual play means the shell has
    /// activated the session by the time the device opens. (PlaybackEngine's
    /// ensureEngine constructs late for exactly this reason.)
    private var engine: AudioEngine?

    // Level / EQ / ReplayGain can be set before the first play, i.e. before the
    // engine exists. Cache the latest of each and push it into the engine the
    // instant it is built, so a setting made against no engine is not silently
    // lost — the same sync-after-construct PlaybackEngine does.
    private var pendingEqualizer: (gains: [Double], preamp: Double, enabled: Bool)?
    private var pendingReplayGain: (mode: AudioEngine.ReplayGainMode, preamp: Double)?
    private var pendingVolume: Double?

    public init(
        resolverFor: @escaping @Sendable (ServerID) -> TrackURLResolver?,
        makeEngine: @escaping EngineFactory = { AudioEngine() },
        makeStream: @escaping StreamFactory = PlaybackCommandService.defaultStream
    ) {
        self.resolverFor = resolverFor
        self.makeEngine = makeEngine
        self.makeStream = makeStream
    }

    /// The default byte stream: a local file reads directly, anything else
    /// streams over authenticated HTTP. Mirrors PlaybackEngine.makeStream.
    public static func defaultStream(_ resolved: ResolvedTrackURL) throws -> AudioEngine.Stream {
        if resolved.isLocal {
            guard let stream = FileStream(url: resolved.url) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return stream
        }
        return HTTPStream(request: URLRequest(url: resolved.url))
    }

    // MARK: Transport

    /// Play a track now, discarding anything queued.
    public func playNow(
        serverId: ServerID, track: Track, trackKey: UInt64
    ) async throws -> PlaybackStateSnapshot {
        try await start(serverId: serverId, track: track, trackKey: trackKey, queue: false)
    }

    /// Queue a track behind the current one for a gapless join. `playNext`
    /// genuinely queues — it holds the stream and swaps at the current track's
    /// last sample — so queueing early is correct, not a timing guess.
    public func playNext(
        serverId: ServerID, track: Track, trackKey: UInt64
    ) async throws -> PlaybackStateSnapshot {
        try await start(serverId: serverId, track: track, trackKey: trackKey, queue: true)
    }

    public func pause() -> PlaybackStateSnapshot {
        engine?.pause()
        return snapshot()
    }

    public func resume() -> PlaybackStateSnapshot {
        engine?.resume()
        return snapshot()
    }

    public func stop() -> PlaybackStateSnapshot {
        engine?.stop()
        return snapshot()
    }

    /// Seek within the current track. The returned snapshot reports where the
    /// engine actually landed (`positionSeconds`), not where it was asked to go.
    public func seek(toSeconds seconds: Double) -> PlaybackStateSnapshot {
        engine?.seek(to: seconds)
        return snapshot()
    }

    public func setVolume(_ volume: Double) -> PlaybackStateSnapshot {
        pendingVolume = volume
        engine?.setVolume(volume)
        return snapshot()
    }

    public func setEqualizer(gainsDB: [Double], preampDB: Double, enabled: Bool) -> PlaybackStateSnapshot {
        pendingEqualizer = (gainsDB, preampDB, enabled)
        engine?.setEqualizer(gainsDB: gainsDB, preampDB: preampDB, enabled: enabled)
        return snapshot()
    }

    public func setReplayGain(mode: AudioEngine.ReplayGainMode, preampDB: Double) -> PlaybackStateSnapshot {
        pendingReplayGain = (mode, preampDB)
        engine?.setReplayGain(mode: mode, preampDB: preampDB)
        return snapshot()
    }

    /// The state query. Playback is continuous but this surface is
    /// request/response, so a client polls this for position and — crucially —
    /// for whether a failure occurred and whether it is worth retrying.
    public func state() -> PlaybackStateSnapshot {
        snapshot()
    }

    // MARK: Internals

    private func start(
        serverId: ServerID, track: Track, trackKey: UInt64, queue: Bool
    ) async throws -> PlaybackStateSnapshot {
        guard let engine = ensureEngine() else { return .idle }
        guard let resolver = resolverFor(serverId) else {
            throw PlaybackCommandError.unknownTrack(serverId: serverId, remoteId: track.id)
        }
        // The core builds the stream itself: resolve to a URL (the resolver
        // prefers a local download when present) then wrap it in the byte
        // source the engine reads. The engine is never handed a URL — it must
        // not learn about Plex tokens, Jellyfin keys or Subsonic salts.
        let resolved = try await resolver.resolve(track)
        let stream = try makeStream(resolved)
        // The container hint helps the decoder pick a demuxer; empty → nil so a
        // pathless URL does not pass "" as a bogus extension.
        let ext = resolved.url.pathExtension.isEmpty ? nil : resolved.url.pathExtension
        if queue {
            engine.playNext(stream: stream, trackID: trackKey, gainDB: track.normalizationGainDB, fileExtension: ext)
        } else {
            engine.playNow(stream: stream, trackID: trackKey, gainDB: track.normalizationGainDB, fileExtension: ext)
        }
        return snapshot()
    }

    /// Build the engine on demand (see the `engine` property's note on why not at
    /// init) and flush any settings cached while it did not exist.
    private func ensureEngine() -> AudioEngine? {
        if let engine { return engine }
        guard let engine = makeEngine() else { return nil }
        self.engine = engine
        // These were set against an engine that did not exist yet.
        if let pendingReplayGain {
            engine.setReplayGain(mode: pendingReplayGain.mode, preampDB: pendingReplayGain.preamp)
        }
        if let pendingEqualizer {
            engine.setEqualizer(gainsDB: pendingEqualizer.gains, preampDB: pendingEqualizer.preamp, enabled: pendingEqualizer.enabled)
        }
        if let pendingVolume {
            engine.setVolume(pendingVolume)
        }
        return engine
    }

    private func snapshot() -> PlaybackStateSnapshot {
        guard let engine else { return .idle }
        return PlaybackStateSnapshot(
            state: engine.state,
            positionSeconds: engine.positionSeconds,
            currentTrackID: engine.currentTrackID,
            hasFailed: engine.hasFailed,
            failureKind: engine.failureKind,
            failureIsRetryable: engine.failureIsRetryable
        )
    }
}
