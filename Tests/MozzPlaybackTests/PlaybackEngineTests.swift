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

    /// Regression: a mutation that changes the upcoming track without a full
    /// reload (here, switching to repeat-one) must evict the already pre-rolled
    /// lookahead, or AVQueuePlayer would gaplessly play the stale track at the
    /// boundary while the queue reports a different one.
    func testStaleLookaheadEvictedWhenNextTrackChanges() async {
        let engine = PlaybackEngine(resolver: StubResolver())
        engine.play(tracks: (0..<3).map { Track(id: "t\($0)", title: "T", artistName: "A") })
        await engine.awaitPendingLoadsForTesting()
        // Repeat off, on t0 → the pre-rolled next is t1.
        XCTAssertEqual(engine.lookaheadTrackIDsForTesting, ["t0", "t1"])

        engine.setRepeatMode(.one)   // peekNext now == current (t0)
        await engine.awaitPendingLoadsForTesting()
        XCTAssertEqual(engine.lookaheadTrackIDsForTesting, ["t0", "t0"],
                       "stale t1 pre-roll must be replaced with the repeat-one track")
    }

    /// A station tops the queue up as it nears the end, so playback never runs dry.
    func testStationAutoExtendsQueue() async {
        let engine = PlaybackEngine(resolver: StubResolver())
        let box = ExtendCounter()
        engine.startStation((0..<4).map { Track(id: "s\($0)", title: "S", artistName: "A") }) {
            let n = box.bump()
            return (0..<5).map { Track(id: "x\(n)_\($0)", title: "X", artistName: "A") }
        }
        await engine.awaitPendingLoadsForTesting()
        XCTAssertGreaterThanOrEqual(box.count, 1, "station fetched a batch as the queue neared its end")
        XCTAssertTrue(engine.upNext.contains { $0.id.hasPrefix("x") }, "fetched tracks were appended")
    }

    /// A station extend fetch that resolves AFTER the user started different
    /// playback must not append its stale batch into the replaced queue.
    func testStaleStationExtendDoesNotAppendAfterReplacement() async {
        let engine = PlaybackEngine(resolver: StubResolver())
        let gate = ExtendGate()
        engine.startStation([Track(id: "s0", title: "S", artistName: "A")]) {
            await gate.wait()
            return [Track(id: "x0", title: "X", artistName: "A")]
        }
        await engine.awaitPendingLoadsForTesting()   // near-end fires; extend Task now awaiting the gate
        engine.play(tracks: (0..<3).map { Track(id: "p\($0)", title: "P", artistName: "B") })
        await gate.open()                             // let the stale station batch resolve
        await engine.awaitPendingLoadsForTesting()
        XCTAssertEqual(engine.currentTrack?.id, "p0")
        XCTAssertFalse(engine.upNext.contains { $0.id.hasPrefix("x") },
                       "a stale station batch must not append into the replaced queue")
    }

    /// The public transport epoch — which the app captures to detect that the
    /// user changed playback while a radio fetch was in flight — bumps on every
    /// content-replacing transport action.
    func testTransportEpochBumpsOnContentChange() {
        let engine = PlaybackEngine(resolver: StubResolver())
        let songs = (0..<2).map { Track(id: "t\($0)", title: "T", artistName: "A") }
        let e0 = engine.transportEpoch
        engine.play(tracks: songs)
        let e1 = engine.transportEpoch
        engine.playShuffled(songs)
        let e2 = engine.transportEpoch
        engine.startStation(songs) { [] }
        let e3 = engine.transportEpoch
        engine.stop()
        let e4 = engine.transportEpoch
        XCTAssertTrue(e0 < e1 && e1 < e2 && e2 < e3 && e3 < e4,
                      "each content-replacing action must advance the transport epoch")
    }
}

/// Thread-safe counter for the station auto-extend test's `@Sendable` closure.
private final class ExtendCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// A one-shot async gate so a test can hold a station's extend fetch open while
/// it replaces playback, then release it.
private actor ExtendGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
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
