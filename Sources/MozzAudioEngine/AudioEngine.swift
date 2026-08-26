import MozzAudioFFI
import Foundation

/// The shared audio engine, as Swift sees it.
///
/// Everything deciding how a track sounds - decoding, ReplayGain, the
/// equaliser, gapless joins, and the order those are applied in - happens in the
/// Rust engine behind this type. That is the point. AVFoundation and the
/// desktop's FFmpeg process are two implementations that have already drifted,
/// and no amount of care keeps two of anything identical.
///
/// This wrapper makes no decisions. It converts Swift values into C ones, keeps
/// a handle alive, and gets out of the way. Anything it chose would be a choice
/// only Apple platforms make, which is precisely what is being removed.
///
/// ## What crosses the boundary
///
/// Commands and state, at human speed. Never audio: the decode thread and the
/// audio callback both live entirely on the Rust side, so no buffer is handed
/// across a language boundary while a deadline is running. A Swift allocation
/// or an ARC pause cannot cause a dropout, because Swift is not involved in
/// producing sound.
public final class AudioEngine {
    /// What the engine is doing.
    public enum State: UInt32, Sendable {
        case idle = 0
        case playing = 1
        case paused = 2
        case ended = 3
    }

    /// How ReplayGain is applied.
    public enum ReplayGainMode: UInt32, Sendable {
        case off = 0
        case track = 1
        case album = 2
    }

    /// Why the most recent decode failed. Distinguishes a broken file (which
    /// must never be retried) from a dropped network (which must). The engine —
    /// not each shell — owns which is which; ``failureIsRetryable`` answers the
    /// question directly so nothing has to hard-code these cases.
    public enum FailureKind: UInt32, Sendable {
        /// No failure since the last command.
        case none = 0
        /// Not audio this engine can decode — permanent; do not retry.
        case unsupported = 1
        /// The stream was interrupted (a network/IO blip) — worth retrying.
        case interrupted = 2
        /// The audio decoded to garbage — permanent; do not retry.
        case corrupt = 3
    }

    /// Supplies the bytes of one track.
    ///
    /// A protocol rather than a URL, because the credentials for a media server
    /// belong to whatever logged into it. Handing the engine a URL would mean
    /// teaching it about Plex tokens, Jellyfin headers and Subsonic salts, and
    /// then teaching every other shell the same thing all over again.
    public protocol Stream: AnyObject {
        /// Fill `buffer` with up to `count` bytes and return how many. Zero
        /// means the end. Called on the decode thread, never the audio thread,
        /// so blocking on a network here is expected and safe.
        func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int
        /// Move to `offset` from `origin` (0 start, 1 current, 2 end), returning
        /// the new absolute position, or negative on failure.
        func seek(offset: Int64, origin: Int32) -> Int64
        /// Release anything held. Called exactly once.
        func close()
    }

    /// `MozzPlayer` is an incomplete type in the header, so Swift imports it as
    /// an `OpaquePointer` rather than a typed pointer. That is exactly right:
    /// its layout is the engine's business and nothing here should be able to
    /// reach inside it.
    private var handle: OpaquePointer?

    /// Create an engine, or nil if the decode thread cannot start.
    ///
    /// - Parameters:
    ///   - sampleRate: the rate to ask the output device for.
    ///   - channels: interleaved channels.
    ///   - bufferFrames: how far ahead the decoder may run. Larger survives a
    ///     slower network; smaller makes a skip discard less work.
    public init?(sampleRate: UInt32 = 44_100, channels: UInt16 = 2, bufferFrames: Int = 65_536) {
        guard let handle = mozz_player_new(sampleRate, channels, UInt(bufferFrames)) else {
            return nil
        }
        self.handle = handle
    }

    deinit {
        close()
    }

    /// Release the engine. Safe to call more than once.
    public func close() {
        guard let handle else { return }
        self.handle = nil
        mozz_player_free(handle)
    }

    /// Play a track now, discarding anything queued.
    ///
    /// - Parameters:
    ///   - stream: where the bytes come from. The engine closes it when done.
    ///   - trackID: reported back once the audio actually reaches this track.
    ///   - gainDB: the track's ReplayGain tag, if it has one. Whether it gets
    ///     applied is decided by ``setReplayGain(mode:preampDB:)`` — the tag
    ///     belongs to the track, the mode belongs to the listener.
    ///   - fileExtension: a hint only; the bytes always win.
    public func playNow(
        stream: Stream,
        trackID: UInt64,
        gainDB: Double? = nil,
        fileExtension: String? = nil
    ) {
        guard let handle else {
            // No engine means nothing will ever read this, so release it here
            // rather than leaving the caller holding something already dead.
            stream.close()
            return
        }
        withSource(stream, fileExtension) { source, hint in
            mozz_player_play_now(handle, source, hint, trackID, gainDB ?? 0, gainDB != nil)
        }
    }

    /// Queue a track behind the current one, so they meet with no gap.
    public func playNext(
        stream: Stream,
        trackID: UInt64,
        gainDB: Double? = nil,
        fileExtension: String? = nil
    ) {
        guard let handle else {
            stream.close()
            return
        }
        withSource(stream, fileExtension) { source, hint in
            mozz_player_play_next(handle, source, hint, trackID, gainDB ?? 0, gainDB != nil)
        }
    }

    /// Hold position and stop the device.
    public func pause() {
        guard let handle else { return }
        mozz_player_pause(handle)
    }

    /// Continue from where ``pause()`` stopped.
    public func resume() {
        guard let handle else { return }
        mozz_player_resume(handle)
    }

    /// Stop and discard the queue.
    public func stop() {
        guard let handle else { return }
        mozz_player_stop(handle)
    }

    /// Move within the current track.
    public func seek(to seconds: Double) {
        guard let handle else { return }
        mozz_player_seek(handle, seconds)
    }

    /// What the engine is doing. A closed engine is idle.
    public var state: State {
        guard let handle else { return .idle }
        return State(rawValue: mozz_player_state(handle)) ?? .idle
    }

    /// Seconds of the current track that have actually been heard.
    ///
    /// Measured from audio handed to the operating system, not from a clock and
    /// not from how far the decoder has read. Those differ by the whole buffer,
    /// which is why a playhead built on the decoder runs ahead of its own sound.
    public var positionSeconds: Double {
        guard let handle else { return 0 }
        return mozz_player_position_seconds(handle)
    }

    /// The track the audio is currently in — not necessarily the last queued.
    public var currentTrackID: UInt64 {
        guard let handle else { return 0 }
        return mozz_player_current_track(handle)
    }

    /// True when a decode has failed since the last command.
    public var hasFailed: Bool {
        guard let handle else { return false }
        return mozz_player_has_failed(handle)
    }

    /// Why the last decode failed (``FailureKind/none`` when it hasn't).
    public var failureKind: FailureKind {
        guard let handle else { return .none }
        return FailureKind(rawValue: mozz_player_failure_kind(handle)) ?? .none
    }

    /// Whether the last failure is worth retrying (a transient interruption)
    /// rather than remembering (a file that will never decode). The engine
    /// decides; a caller should not map ``failureKind`` cases itself.
    public var failureIsRetryable: Bool {
        guard let handle else { return false }
        return mozz_player_failure_is_retryable(handle)
    }

    /// Set the ten-band equaliser.
    ///
    /// Fewer than ten gains are padded with zero and extras are ignored,
    /// because a caller that miscounts should get a flat band rather than a
    /// buffer overrun on the C side.
    public func setEqualizer(gainsDB: [Double], preampDB: Double, enabled: Bool) {
        guard let handle else { return }
        var gains = [Double](repeating: 0, count: 10)
        for (index, gain) in gainsDB.prefix(10).enumerated() {
            gains[index] = gain
        }
        gains.withUnsafeBufferPointer { buffer in
            mozz_player_set_equalizer(handle, buffer.baseAddress, preampDB, enabled)
        }
    }

    /// Set ReplayGain.
    public func setReplayGain(mode: ReplayGainMode, preampDB: Double) {
        guard let handle else { return }
        mozz_player_set_replay_gain(handle, mode.rawValue, preampDB)
    }

    /// Set the listener's own volume, 0.0 silent to 1.0 unity.
    ///
    /// This is a level control applied after ReplayGain and the equaliser, not
    /// a decision about how the track sounds. The engine clamps to 0...1 and
    /// ramps the change so it does not click, so no clamping is done here — a
    /// second clamp would be a second place the range could drift from the
    /// engine's.
    public func setVolume(_ volume: Double) {
        guard let handle else { return }
        mozz_player_set_volume(handle, volume)
    }

    /// Wrap a Swift stream in the C callbacks the engine expects.
    ///
    /// The stream is retained unbalanced here and released by `closeSource`,
    /// which the engine calls exactly once. That is deliberate: the engine
    /// outlives this function by minutes, and letting ARC free the stream when
    /// this returns would hand the decode thread a dangling pointer.
    private func withSource(
        _ stream: Stream,
        _ fileExtension: String?,
        _ body: (MozzSource, UnsafePointer<CChar>?) -> Void
    ) {
        let box = Unmanaged.passRetained(StreamBox(stream)).toOpaque()
        let source = MozzSource(ctx: box, read: readSource, seek: seekSource, close: closeSource)

        if let fileExtension {
            fileExtension.withCString { body(source, $0) }
        } else {
            body(source, nil)
        }
    }
}

/// Carries a Swift stream across the C boundary as an opaque pointer.
private final class StreamBox {
    let stream: AudioEngine.Stream
    init(_ stream: AudioEngine.Stream) { self.stream = stream }
}

// These are `@convention(c)` because the engine calls them from its own decode
// thread. That rules out capturing anything: the only state they get is the
// opaque `ctx` pointer, which is the boxed Swift stream. It is also why the box
// is retained across the boundary rather than left to ARC, which has no idea a
// Rust thread is holding a reference.
private let readSource: MozzReadFn = { ctx, buffer, count in
    guard let ctx, let buffer else { return -1 }
    let box = Unmanaged<StreamBox>.fromOpaque(ctx).takeUnretainedValue()
    return box.stream.read(into: buffer, count: Int(count))
}

private let seekSource: MozzSeekFn = { ctx, offset, origin in
    guard let ctx else { return -1 }
    let box = Unmanaged<StreamBox>.fromOpaque(ctx).takeUnretainedValue()
    return box.stream.seek(offset: offset, origin: origin)
}

private let closeSource: MozzCloseFn = { ctx in
    guard let ctx else { return }
    let unmanaged = Unmanaged<StreamBox>.fromOpaque(ctx)
    unmanaged.takeUnretainedValue().stream.close()
    // Balances the retain in withSource. The engine promises exactly one close,
    // and this is the only place the box is released.
    unmanaged.release()
}
