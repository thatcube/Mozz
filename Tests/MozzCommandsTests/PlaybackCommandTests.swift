import Foundation
import Testing
import MozzAudioEngine
import MozzCore
import MozzDatabase
import MozzSchema
import SwiftProtobuf
@testable import MozzCommands

/// Playback driven the way a shell drives it: as commands on the Facade, over
/// the wire, against a real engine. These link the real Rust engine and push
/// real audio through it (as MozzAudioEngineTests do) — a command surface that
/// merely compiles proves nothing about whether play, seek, or a decode failure
/// actually cross the boundary intact.
///
/// Serialized because each test opens the real output device; several engines
/// contending for it in parallel would be a flake, not a finding.
@Suite(.serialized) struct PlaybackCommandTests {

    // MARK: Fixtures

    /// A stream the test owns so the callback path is exercised, not mocked
    /// away. Mirrors the one in MozzAudioEngineTests.
    private final class MemoryStream: AudioEngine.Stream {
        private let bytes: [UInt8]
        private var position = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
            let take = min(count, bytes.count - position)
            if take > 0 {
                bytes.withUnsafeBufferPointer { source in
                    buffer.update(from: source.baseAddress! + position, count: take)
                }
                position += take
            }
            return take
        }

        func seek(offset: Int64, origin: Int32) -> Int64 {
            let base: Int64
            switch origin {
            case 1: base = Int64(position)
            case 2: base = Int64(bytes.count)
            default: base = 0
            }
            let landed = max(0, min(base + offset, Int64(bytes.count)))
            position = Int(landed)
            return landed
        }

        func close() {}
    }

    /// A mono 8 kHz WAV of `frames` samples, built here so no fixture file has to
    /// be committed. 16 kHz-worth of frames is two seconds — long enough to seek
    /// well into.
    private static func wav(frames: Int) -> [UInt8] {
        var out = [UInt8]()
        func u32(_ v: UInt32) { out.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        func u16(_ v: UInt16) { out.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        let data = UInt32(frames * 2)
        out.append(contentsOf: Array("RIFF".utf8)); u32(36 + data)
        out.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(8_000); u32(16_000); u16(2); u16(16)
        out.append(contentsOf: Array("data".utf8)); u32(data)
        for _ in 0..<frames { u16(UInt16(bitPattern: 8_000)) }
        return out
    }

    /// Resolves any track to a fixed ".wav" URL. The engine never sees this URL —
    /// the injected stream factory supplies the bytes — but the ".wav" suffix
    /// gives the decoder its container hint, exactly as a real URL's extension
    /// would.
    private struct FixedResolver: TrackURLResolver {
        func resolve(_ track: Track) async throws -> ResolvedTrackURL {
            ResolvedTrackURL(url: URL(string: "mozz-test://track.wav")!, isLocal: false)
        }
    }

    /// Counts engine constructions, so a test can prove the engine is built
    /// lazily (on first play) rather than at init.
    private final class ConstructionCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func makeLibrary() async throws -> LibraryRepository {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-\(UUID().uuidString).sqlite")
        let db = try MusicDatabase.open(at: url)
        try await SyntheticCatalog(db).generate(
            serverId: SyntheticCatalog.defaultServerID,
            size: .init(artists: 4, albums: 8, tracks: 40))
        return LibraryRepository(db)
    }

    private static func firstTrack(_ repository: LibraryRepository) async throws -> TrackRecord {
        let page = try await repository.tracksPage(
            serverId: SyntheticCatalog.defaultServerID, after: nil, limit: 1)
        return try #require(page.rows.first)
    }

    /// A playback service over a real engine (8 kHz mono, matching the WAV) whose
    /// bytes come from `stream`. `counter` observes lazy construction.
    private static func makePlayback(
        stream: @escaping @Sendable () -> [UInt8] = { wav(frames: 16_000) },
        counter: ConstructionCounter? = nil
    ) -> PlaybackCommandService {
        PlaybackCommandService(
            resolverFor: { _ in FixedResolver() },
            makeEngine: {
                counter?.bump()
                return AudioEngine(sampleRate: 8_000, channels: 1, bufferFrames: 8_192)
            },
            makeStream: { _ in MemoryStream(stream()) })
    }

    private static func dispatcher(
        _ repository: LibraryRepository, playback: PlaybackCommandService?
    ) throws -> CommandDispatcher {
        CommandDispatcher(service: LibraryCommandService(
            repository: repository,
            playbackSettings: PlaybackSettingsStore(try MusicDatabase.inMemory()),
            downloads: DownloadStore(try MusicDatabase.inMemory()),
            playback: playback))
    }

    private static func send(
        _ dispatcher: CommandDispatcher,
        _ build: (inout Mozz_V1_Request) -> Void
    ) async throws -> Mozz_V1_Response {
        var request = Mozz_V1_Request()
        request.id = 1
        build(&request)
        let bytes = await dispatcher.handle(try request.serializedData())
        return try Mozz_V1_Response(serializedBytes: bytes)
    }

    /// Poll a playback-state query over the wire until `condition` holds, because
    /// the decode thread produces state at a speed this machine sets, not the
    /// test. Returns the last state seen.
    @discardableResult
    private static func eventuallyState(
        _ dispatcher: CommandDispatcher,
        _ description: String,
        timeout: TimeInterval = 4,
        _ condition: (Mozz_V1_PlaybackState) -> Bool
    ) async throws -> Mozz_V1_PlaybackState {
        let deadline = Date().addingTimeInterval(timeout)
        var last = Mozz_V1_PlaybackState()
        repeat {
            let response = try await send(dispatcher) { $0.playbackState = Mozz_V1_PlaybackStateRequest() }
            guard case .playbackState(let payload) = response.result else {
                Issue.record("expected playbackState, got \(String(describing: response.result))")
                return last
            }
            last = payload.state
            if condition(last) { return last }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        Issue.record("timed out waiting for: \(description) — last state \(last)")
        return last
    }

    // MARK: Tests

    /// The headline requirement: playing a track and then querying state both go
    /// through the Facade, and the query reports the live engine — playing, at
    /// the track that was asked for, with a position that advances.
    @Test func playingThenQueryingStateRoundTripsThroughTheFacade() async throws {
        let repository = try await Self.makeLibrary()
        let track = try await Self.firstTrack(repository)
        let dispatcher = try Self.dispatcher(repository, playback: Self.makePlayback())

        let played = try await Self.send(dispatcher) {
            var request = Mozz_V1_PlaybackPlayRequest()
            request.serverID = track.serverId
            request.remoteID = track.remoteId
            $0.playbackPlay = request
        }
        guard case .playbackPlay = played.result else {
            Issue.record("expected playbackPlay, got \(String(describing: played.result))")
            return
        }

        // The engine keys playback by the internal track id, which is also the
        // wire's TrackSummary.id. It only reads back once the decode thread has
        // picked the track up, so assert it on the playing snapshot, not the
        // synchronous play response.
        let playing = try await Self.eventuallyState(dispatcher, "the engine reaches playing") {
            $0.engineState == .playing
        }
        #expect(playing.currentTrackID == UInt64(bitPattern: track.id ?? -1))
        #expect(!playing.hasFailed_p)

        try await Self.eventuallyState(dispatcher, "position advances") { $0.positionSeconds > 0.02 }
    }

    /// A decode failure must cross the Facade carrying BOTH its kind and the
    /// engine's retryable verdict, uncollapsed. Rubbish bytes are Unsupported —
    /// permanent — so the wire must say `.unsupported` and NOT retryable. A
    /// surface that reported "failed" without the kind, or flipped the retry
    /// flag, is the exact bug this asserts against.
    @Test func aDecodeFailureCrossesTheFacadeWithItsKindAndRetryVerdict() async throws {
        let repository = try await Self.makeLibrary()
        let track = try await Self.firstTrack(repository)
        let playback = Self.makePlayback(stream: { [UInt8](repeating: 9, count: 64) })
        let dispatcher = try Self.dispatcher(repository, playback: playback)

        _ = try await Self.send(dispatcher) {
            var request = Mozz_V1_PlaybackPlayRequest()
            request.serverID = track.serverId
            request.remoteID = track.remoteId
            $0.playbackPlay = request
        }

        let failed = try await Self.eventuallyState(dispatcher, "the failure is reported") { $0.hasFailed_p }
        #expect(failed.hasFailed_p)
        #expect(failed.failureKind == .unsupported)
        #expect(failed.failureIsRetryable == false)
        #expect(failed.engineState != .playing)
    }

    /// Seek must report the position the engine actually landed on, read from
    /// the engine — never the target echoed back. Asking to seek to an absurd
    /// time proves it: the reported position stays bounded by the real track
    /// rather than parroting the request. (The exact post-seek position is
    /// environment-dependent — a real output device drives the frame counter at
    /// its own rate — so the deterministic, meaningful assertion at the command
    /// surface is that the answer is engine-derived, not the caller's number.)
    @Test func seekReportsWhereTheEngineLandedNotWhatWasAsked() async throws {
        let repository = try await Self.makeLibrary()
        let track = try await Self.firstTrack(repository)
        let dispatcher = try Self.dispatcher(
            repository, playback: Self.makePlayback(stream: { Self.wav(frames: 80_000) }))

        _ = try await Self.send(dispatcher) {
            var request = Mozz_V1_PlaybackPlayRequest()
            request.serverID = track.serverId
            request.remoteID = track.remoteId
            $0.playbackPlay = request
        }
        try await Self.eventuallyState(dispatcher, "playing") {
            $0.engineState == .playing && $0.positionSeconds > 0.02
        }

        // The track is ~10s; ask to seek to a wildly out-of-range time.
        let absurdTarget = 9_000.0
        let seeked = try await Self.send(dispatcher) {
            var request = Mozz_V1_PlaybackSeekRequest()
            request.positionSeconds = absurdTarget
            $0.playbackSeek = request
        }
        guard case .playbackSeek(let payload) = seeked.result else {
            Issue.record("expected playbackSeek, got \(String(describing: seeked.result))")
            return
        }
        // The command answers with the engine's position, bounded by the real
        // track — never the target it was handed. Echoing the request would sail
        // past this.
        #expect(payload.state.positionSeconds < 100)

        // And it stays engine-bounded on the next poll, too — the engine never
        // wandered off to the requested 9000s.
        let after = try await Self.eventuallyState(dispatcher, "position stays engine-bounded") { _ in true }
        #expect(after.positionSeconds < 100)
    }

    /// A track the catalog never saw fails cleanly as a `Failure` naming the id,
    /// rather than crashing or constructing an engine for nothing.
    @Test func anUnknownTrackFailsCleanlyRatherThanCrashing() async throws {
        let repository = try await Self.makeLibrary()
        let counter = Self.ConstructionCounter()
        let dispatcher = try Self.dispatcher(
            repository, playback: Self.makePlayback(counter: counter))

        let response = try await Self.send(dispatcher) {
            var request = Mozz_V1_PlaybackPlayRequest()
            request.serverID = SyntheticCatalog.defaultServerID
            request.remoteID = "no-such-track"
            $0.playbackPlay = request
        }
        guard case .failure(let failure) = response.result else {
            Issue.record("expected failure, got \(String(describing: response.result))")
            return
        }
        #expect(failure.message.contains("no-such-track"))
        // Nothing playable, so nothing was built.
        #expect(counter.count == 0)
    }

    /// Where playback is not wired into the process (the live FFI session, for
    /// now), a playback command is an honest `Failure`, not a silent no-op.
    @Test func playbackIsAnHonestFailureWhenNoEngineIsWired() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository, playback: nil)

        let response = try await Self.send(dispatcher) {
            $0.playbackState = Mozz_V1_PlaybackStateRequest()
        }
        guard case .failure(let failure) = response.result else {
            Issue.record("expected failure, got \(String(describing: response.result))")
            return
        }
        #expect(failure.message.contains("not available"))
    }

    /// The engine must be built lazily — on the first play, not at init — because
    /// it opens the output device the moment it exists, and on iOS a device
    /// opened before the audio session is active emits silence while looking
    /// healthy. Setting volume and querying state before any play must therefore
    /// build nothing; the first play builds exactly one engine.
    @Test func theEngineIsConstructedLazilyOnFirstPlay() async throws {
        let repository = try await Self.makeLibrary()
        let track = try await Self.firstTrack(repository)
        let counter = Self.ConstructionCounter()
        let playback = Self.makePlayback(counter: counter)

        // Nothing has played, so nothing is built.
        #expect(counter.count == 0)

        // A setting made before the first play caches rather than constructs.
        _ = await playback.setVolume(0.5)
        #expect(counter.count == 0)

        // Querying state before any play is idle, and still builds nothing.
        let idle = await playback.state()
        #expect(idle.state == .idle)
        #expect(counter.count == 0)

        // The first play constructs exactly one engine (which also flushes the
        // volume cached above — it must not crash doing so).
        _ = try await playback.playNow(serverId: "s1", track: track.toDomain(), trackKey: UInt64(bitPattern: track.id ?? 0))
        #expect(counter.count == 1)

        // A second play reuses it.
        _ = try await playback.playNow(serverId: "s1", track: track.toDomain(), trackKey: UInt64(bitPattern: track.id ?? 0))
        #expect(counter.count == 1)
    }
}
