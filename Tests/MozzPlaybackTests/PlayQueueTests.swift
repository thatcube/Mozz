import XCTest
import MozzCore
@testable import MozzPlayback

private func tracks(_ n: Int) -> [Track] {
    (0..<n).map { Track(id: "t\($0)", title: "Track \($0)", artistName: "A") }
}

final class PlayQueueTests: XCTestCase {
    func testSetItemsStartsAtIndex() {
        var q = PlayQueue()
        q.setItems(tracks(5), startingAt: 2)
        XCTAssertEqual(q.current?.id, "t2")
        XCTAssertEqual(q.count, 5)
        XCTAssertEqual(q.upNext.map(\.id), ["t3", "t4"])
    }

    func testAdvanceStopsAtEndWhenRepeatOff() {
        var q = PlayQueue()
        q.setItems(tracks(3), startingAt: 2)
        XCTAssertNil(q.advance())
        XCTAssertEqual(q.current?.id, "t2")
        XCTAssertFalse(q.hasNext)
    }

    func testAdvanceWrapsWhenRepeatAll() {
        var q = PlayQueue()
        q.setItems(tracks(3), startingAt: 2)
        q.repeatMode = .all
        XCTAssertEqual(q.advance()?.id, "t0")
        XCTAssertTrue(q.hasNext)
    }

    func testTrackDidFinishRepeatsOne() {
        var q = PlayQueue()
        q.setItems(tracks(3), startingAt: 0)
        q.repeatMode = .one
        XCTAssertEqual(q.trackDidFinish()?.id, "t0")
        XCTAssertEqual(q.current?.id, "t0")
    }

    func testAdvanceIgnoresRepeatOne() {
        var q = PlayQueue()
        q.setItems(tracks(3), startingAt: 0)
        q.repeatMode = .one
        XCTAssertEqual(q.advance()?.id, "t1")
    }

    func testPreviousRestartsHandledByEngineNotQueue() {
        var q = PlayQueue()
        q.setItems(tracks(3), startingAt: 0)
        // At index 0 with repeat off, previous keeps current.
        XCTAssertEqual(q.previous()?.id, "t0")
    }

    func testPreviousGoesBack() {
        var q = PlayQueue()
        q.setItems(tracks(3), startingAt: 2)
        XCTAssertEqual(q.previous()?.id, "t1")
    }

    func testPreviousWrapsWhenRepeatAll() {
        var q = PlayQueue()
        q.setItems(tracks(3), startingAt: 0)
        q.repeatMode = .all
        XCTAssertEqual(q.previous()?.id, "t2")
    }

    func testPeekNextRespectsRepeatMode() {
        var q = PlayQueue()
        q.setItems(tracks(3), startingAt: 2)
        XCTAssertNil(q.peekNext)             // repeat off, at end
        q.repeatMode = .all
        XCTAssertEqual(q.peekNext?.id, "t0") // wraps
        q.repeatMode = .one
        XCTAssertEqual(q.peekNext?.id, "t2") // same track
    }

    func testShufflePinsCurrentAndPreservesSet() {
        var q = PlayQueue()
        q.setItems(tracks(50), startingAt: 10)
        q.setShuffle(true)
        XCTAssertEqual(q.current?.id, "t10", "current track must keep playing")
        XCTAssertEqual(q.position, 0)
        // Order is a permutation of all base indices.
        let ids = Set((q.upNext + [q.current!]).map(\.id))
        XCTAssertEqual(ids.count, 50)
    }

    func testDisablingShuffleRestoresOrderAtCurrent() {
        var q = PlayQueue()
        q.setItems(tracks(10), startingAt: 3)
        q.setShuffle(true)
        q.setShuffle(false)
        XCTAssertEqual(q.current?.id, "t3")
        XCTAssertEqual(q.upNext.map(\.id), ["t4", "t5", "t6", "t7", "t8", "t9"])
    }

    func testInsertNextOrdering() {
        var q = PlayQueue()
        q.setItems(tracks(3), startingAt: 0)
        let extra = [Track(id: "x1", title: "X1", artistName: "A"), Track(id: "x2", title: "X2", artistName: "A")]
        q.insertNext(extra)
        XCTAssertEqual(q.upNext.map(\.id), ["x1", "x2", "t1", "t2"])
    }

    func testAppendAddsToEnd() {
        var q = PlayQueue()
        q.setItems(tracks(2), startingAt: 0)
        q.append([Track(id: "z", title: "Z", artistName: "A")])
        XCTAssertEqual(q.upNext.map(\.id), ["t1", "z"])
    }

    func testJumpToBaseIndex() {
        var q = PlayQueue()
        q.setItems(tracks(5), startingAt: 0)
        XCTAssertEqual(q.jump(toBaseIndex: 3)?.id, "t3")
        XCTAssertEqual(q.current?.id, "t3")
    }

    func testEmptyQueueBehavior() {
        var q = PlayQueue()
        XCTAssertNil(q.current)
        XCTAssertNil(q.advance())
        XCTAssertNil(q.peekNext)
        XCTAssertFalse(q.hasNext)
        XCTAssertTrue(q.isEmpty)
    }

    func testRepeatModeCycle() {
        XCTAssertEqual(MozzPlayback.RepeatMode.off.next, .all)
        XCTAssertEqual(MozzPlayback.RepeatMode.all.next, .one)
        XCTAssertEqual(MozzPlayback.RepeatMode.one.next, .off)
    }
}
