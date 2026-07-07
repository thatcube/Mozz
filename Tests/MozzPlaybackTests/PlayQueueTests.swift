import XCTest
import Foundation
import MozzCore
@testable import MozzPlayback

private func tracks(_ n: Int) -> [Track] {
    (0..<n).map { Track(id: "t\($0)", title: "Track \($0)", artistName: "A") }
}

/// 12 tracks across 3 equal-sized artists (A/B/C), so the balanced-shuffle
/// grouping path is actually exercised through `PlayQueue` (not just the
/// single-group fallback the `tracks(_:)` helper hits).
private func multiArtistTracks() -> [Track] {
    (0..<12).map { Track(id: "t\($0)", title: "T\($0)", artistName: ["A", "B", "C"][$0 % 3]) }
}

/// One artist, two albums (X/Y, 5 each) — exercises the secondary (album) key.
private func albumTracks() -> [Track] {
    (0..<10).map { Track(id: "t\($0)", title: "T\($0)", albumTitle: $0 < 5 ? "X" : "Y", artistName: "A") }
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
        q.setRepeatMode(.all)
        XCTAssertEqual(q.advance()?.id, "t0")
        XCTAssertTrue(q.hasNext)
    }

    func testTrackDidFinishRepeatsOne() {
        var q = PlayQueue()
        q.setItems(tracks(3), startingAt: 0)
        q.setRepeatMode(.one)
        XCTAssertEqual(q.trackDidFinish()?.id, "t0")
        XCTAssertEqual(q.current?.id, "t0")
    }

    func testAdvanceIgnoresRepeatOne() {
        var q = PlayQueue()
        q.setItems(tracks(3), startingAt: 0)
        q.setRepeatMode(.one)
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
        q.setRepeatMode(.all)
        XCTAssertEqual(q.previous()?.id, "t2")
    }

    func testPeekNextRespectsRepeatMode() {
        var q = PlayQueue()
        q.setItems(tracks(3), startingAt: 2)
        XCTAssertNil(q.peekNext)             // repeat off, at end
        q.setRepeatMode(.all)
        XCTAssertEqual(q.peekNext?.id, "t0") // wraps
        q.setRepeatMode(.one)
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

    // MARK: Balanced shuffle entry point

    func testSetItemsShuffledEnablesShuffleWithFullPermutation() {
        var q = PlayQueue()
        q.setItemsShuffled(tracks(50))
        XCTAssertTrue(q.isShuffled)
        XCTAssertEqual(q.position, 0)
        XCTAssertEqual(q.count, 50)
        let ids = Set((q.upNext + [q.current!]).map(\.id))
        XCTAssertEqual(ids.count, 50, "every base track appears exactly once")
    }

    // MARK: Reshuffle-on-wrap (gapless invariant)

    /// The engine pre-rolls `peekNext` for gapless playback, so the track it
    /// predicts at the loop boundary MUST equal the track that actually plays
    /// after the queue wraps. This guards that invariant across a reshuffle.
    func testPeekNextMatchesWrappedTrackForGaplessLoop() {
        var q = PlayQueue()
        q.setItemsShuffled(tracks(20))
        q.setRepeatMode(.all)
        while q.position < q.order.count - 1 { q.advance() }

        let predicted = q.peekNext?.id
        let played = q.trackDidFinish()?.id   // wraps to the next loop

        XCTAssertEqual(q.position, 0)
        XCTAssertNotNil(predicted)
        XCTAssertEqual(played, predicted,
                       "pre-rolled peekNext must be the track that plays after wrap")
    }

    func testWrapGeneratesAFreshOrderEachLoop() {
        var q = PlayQueue()
        q.setItemsShuffled(tracks(20))
        q.setRepeatMode(.all)
        let firstLoopOrder = q.order

        for _ in 0..<q.count { q.advance() }   // one full loop back to the start

        XCTAssertEqual(q.position, 0)
        XCTAssertNotEqual(q.order, firstLoopOrder,
                          "a shuffled repeat-all queue reshuffles when it wraps")
    }

    func testNonShuffledWrapKeepsSameOrder() {
        var q = PlayQueue()
        q.setItems(tracks(4), startingAt: 0)
        q.setRepeatMode(.all)
        let order = q.order
        for _ in 0..<q.count { q.advance() }
        XCTAssertEqual(q.order, order, "repeat-all without shuffle replays the same order")
        XCTAssertEqual(q.current?.id, "t0")
    }

    // MARK: Balanced spreading through PlayQueue (multi-artist)

    func testShufflePinsCurrentWithMultipleArtists() {
        var q = PlayQueue()
        q.setItems(multiArtistTracks(), startingAt: 5)   // t5 == artist "C"
        q.setShuffle(true)
        XCTAssertEqual(q.current?.id, "t5", "current track stays pinned to the front")
        XCTAssertEqual(q.position, 0)
        let ids = Set(([q.current!] + q.upNext).map(\.id))
        XCTAssertEqual(ids.count, 12, "every track present exactly once")
    }

    func testSetItemsShuffledSpreadsArtistsThroughQueue() {
        var q = PlayQueue()
        q.setItemsShuffled(multiArtistTracks())
        let ordered = [q.current!] + q.upNext
        XCTAssertEqual(Set(ordered.map(\.id)).count, 12)
        // 3 equal-sized groups on evenly-spaced combs → guaranteed round-robin,
        // so no two adjacent tracks share an artist (RNG-independent).
        let artists = ordered.map(\.artistName)
        let collisions = zip(artists, artists.dropFirst()).filter { $0 == $1 }.count
        XCTAssertEqual(collisions, 0, "balanced shuffle must spread artists end-to-end")
    }

    func testSetItemsShuffledSpreadsAlbumsWithinArtist() {
        var q = PlayQueue()
        q.setItemsShuffled(albumTracks())
        let ordered = [q.current!] + q.upNext
        XCTAssertEqual(Set(ordered.map(\.id)).count, 10)
        let albums = ordered.map { $0.albumTitle ?? "" }
        let collisions = zip(albums, albums.dropFirst()).filter { $0 == $1 }.count
        XCTAssertEqual(collisions, 0, "same-album tracks must spread within a single artist")
    }

    func testWrapSeamAvoidsRepeatingTheOutgoingArtist() {
        var q = PlayQueue()
        q.setItemsShuffled(multiArtistTracks())   // 3 artists A/B/C
        q.setRepeatMode(.all)
        while q.position < q.order.count - 1 { q.advance() }   // park on the last slot

        let outgoingArtist = q.current?.artistName
        let predicted = q.peekNext
        XCTAssertNotEqual(predicted?.artistName, outgoingArtist,
                          "the next loop must not open on the outgoing artist")
        XCTAssertNotEqual(predicted?.id, q.current?.id, "and not the outgoing track")
        // Gapless invariant still holds across the seam-adjusted wrap.
        XCTAssertEqual(q.trackDidFinish()?.id, predicted?.id)
    }

    // MARK: Restore rebuilds the reshuffle-on-wrap cache

    func testRestoreRebuildsWrapCacheSoFirstWrapReshuffles() throws {
        var q = PlayQueue()
        q.setItemsShuffled(tracks(20))
        q.setRepeatMode(.all)
        while q.position < q.order.count - 1 { q.advance() }   // park on the last slot

        // Persistence round-trip: nextLoopOrder is excluded from Codable, so the
        // decoded queue starts with an empty wrap cache.
        let data = try JSONEncoder().encode(q)
        var restored = try JSONDecoder().decode(PlayQueue.self, from: data)
        restored.rebuildTransientState()

        let orderBeforeWrap = restored.order
        let predicted = restored.peekNext?.id
        let played = restored.trackDidFinish()?.id
        XCTAssertEqual(played, predicted, "gapless wrap invariant holds after restore")
        XCTAssertEqual(restored.position, 0)
        XCTAssertNotEqual(restored.order, orderBeforeWrap,
                          "first wrap after restore reshuffles (rebuildTransientState primed the cache)")
    }
}
