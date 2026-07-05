import XCTest
import MozzCore
@testable import MozzPlayback

/// A resolver that hands back a local file URL without any network, so engine
/// state transitions can be exercised on the host.
private struct StubResolver: TrackURLResolver {
    func resolve(_ track: Track) async throws -> ResolvedTrackURL {
        ResolvedTrackURL(url: URL(fileURLWithPath: "/dev/null/\(track.id).m4a"), isLocal: true)
    }
}

@MainActor
final class PlaybackEngineTests: XCTestCase {
    func testInitialStateIsIdle() {
        let engine = PlaybackEngine(resolver: StubResolver())
        XCTAssertEqual(engine.snapshot.status, .idle)
        XCTAssertNil(engine.currentTrack)
    }

    func testPlaySetsCurrentTrackImmediately() {
        let engine = PlaybackEngine(resolver: StubResolver())
        let list = (0..<3).map { Track(id: "t\($0)", title: "T\($0)", artistName: "A") }
        engine.play(tracks: list, startAt: 1)
        XCTAssertEqual(engine.currentTrack?.id, "t1")
        XCTAssertEqual(engine.snapshot.currentTrackID, "t1")
        XCTAssertTrue(engine.snapshot.hasNext)
    }

    func testShuffleAndRepeatReflectInSnapshot() {
        let engine = PlaybackEngine(resolver: StubResolver())
        engine.play(tracks: (0..<5).map { Track(id: "t\($0)", title: "T", artistName: "A") })
        engine.toggleShuffle()
        XCTAssertTrue(engine.snapshot.isShuffled)
        engine.cycleRepeatMode()
        XCTAssertEqual(engine.snapshot.repeatMode, .all)
    }

    func testNextAdvancesCurrentTrack() {
        let engine = PlaybackEngine(resolver: StubResolver())
        engine.play(tracks: (0..<3).map { Track(id: "t\($0)", title: "T", artistName: "A") })
        engine.next()
        XCTAssertEqual(engine.currentTrack?.id, "t1")
    }

    func testStopClearsState() {
        let engine = PlaybackEngine(resolver: StubResolver())
        engine.play(tracks: [Track(id: "t0", title: "T", artistName: "A")])
        engine.stop()
        XCTAssertNil(engine.currentTrack)
        XCTAssertEqual(engine.snapshot.status, .idle)
    }
}

/// Verifies the listening-history emission (B1): every track start is paired
/// with exactly one terminal event — `completed` on natural end vs `skipped`
/// when the user leaves early. Runs synchronously (started is emitted on intent,
/// natural end is driven via the internal `handleNaturalFinish` seam), so no
/// real audio playback is needed.
@MainActor
final class PlayEventEmissionTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [PlayEvent] = []
        func add(_ e: PlayEvent) { lock.lock(); events.append(e); lock.unlock() }
        var trace: [String] {
            lock.lock(); defer { lock.unlock() }
            return events.map { "\($0.kind.rawValue):\($0.trackID)" }
        }
    }

    private func makeEngine() -> (PlaybackEngine, Log) {
        let engine = PlaybackEngine(resolver: StubResolver())
        let log = Log()
        engine.onPlayEvent = { log.add($0) }
        return (engine, log)
    }

    private func list(_ n: Int) -> [Track] {
        (0..<n).map { Track(id: "t\($0)", title: "T", artistName: "A", duration: 100) }
    }

    func testUserNextEmitsStartedThenSkippedThenStarted() {
        let (engine, log) = makeEngine()
        engine.play(tracks: list(3))
        engine.next()
        XCTAssertEqual(log.trace, ["started:t0", "skipped:t0", "started:t1"])
    }

    func testNaturalFinishEmitsCompletedThenStartsNext() {
        let (engine, log) = makeEngine()
        engine.play(tracks: list(2))
        engine.handleNaturalFinish()
        XCTAssertEqual(log.trace, ["started:t0", "completed:t0", "started:t1"])
    }

    func testStopMidTrackEmitsSkipped() {
        let (engine, log) = makeEngine()
        engine.play(tracks: list(1))
        engine.stop()
        XCTAssertEqual(log.trace, ["started:t0", "skipped:t0"])
    }

    func testCompletionAtEndOfQueueDoesNotAlsoSkip() {
        // The finishing track completes; the follow-on stop() must not also log
        // a skip for it (no double terminal event).
        let (engine, log) = makeEngine()
        engine.play(tracks: list(1))
        engine.handleNaturalFinish()
        XCTAssertEqual(log.trace, ["started:t0", "completed:t0"])
    }

    func testStartingANewQueueSkipsTheOutgoingTrack() {
        let (engine, log) = makeEngine()
        engine.play(tracks: [Track(id: "a", title: "A", artistName: "A", duration: 100)])
        engine.play(tracks: [Track(id: "b", title: "B", artistName: "A", duration: 100)])
        XCTAssertEqual(log.trace, ["started:a", "skipped:a", "started:b"])
    }
}
