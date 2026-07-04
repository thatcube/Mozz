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
