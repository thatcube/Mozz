import Foundation
import MozzCore
import Testing
@testable import MozzContinuity

private func fingerprint(_ serverID: String = "srv", account: String = "acct") -> ServerAccountFingerprint {
    ServerAccountFingerprint(backend: .subsonic, serverID: serverID, accountID: account)
}

private func item(_ id: String, baseOrdinal: Int = 0) -> ContinuityItem {
    ContinuityItem(
        locator: TrackLocator(server: fingerprint(), remoteID: id),
        baseOrdinal: baseOrdinal,
        title: "Title \(id)",
        artist: "Artist",
        durationMS: 180_000
    )
}

@Suite("Continuity queue hashing")
struct ContinuityHashTests {

    @Test("The same queue always hashes to the same value")
    func hashIsStable() {
        let items = (0..<5).map { item("t\($0)", baseOrdinal: $0) }
        let a = ContinuityQueueBuilder.hash(
            items: items, descriptor: .adHoc, repeatMode: .off,
            isShuffled: false, totalCount: 5, startAbsoluteIndex: 0
        )
        let b = ContinuityQueueBuilder.hash(
            items: items, descriptor: .adHoc, repeatMode: .off,
            isShuffled: false, totalCount: 5, startAbsoluteIndex: 0
        )
        #expect(a == b)
        #expect(a.count == 64)      // SHA-256 hex
    }

    @Test("Reordering the queue changes the hash")
    func orderMatters() {
        let forward = (0..<4).map { item("t\($0)", baseOrdinal: $0) }
        let reversed = Array(forward.reversed())
        let a = ContinuityQueueBuilder.hash(
            items: forward, descriptor: .adHoc, repeatMode: .off,
            isShuffled: false, totalCount: 4, startAbsoluteIndex: 0
        )
        let b = ContinuityQueueBuilder.hash(
            items: reversed, descriptor: .adHoc, repeatMode: .off,
            isShuffled: false, totalCount: 4, startAbsoluteIndex: 0
        )
        #expect(a != b)
    }

    @Test("Display metadata is excluded, so re-fetched titles don't invalidate a queue")
    func displayMetadataIgnored() {
        let plain = [item("t1", baseOrdinal: 0)]
        var enriched = plain
        enriched[0].title = "A much better title"
        enriched[0].artist = "Corrected Artist"
        enriched[0].artwork = ArtworkRef(key: "art")

        let a = ContinuityQueueBuilder.hash(
            items: plain, descriptor: .adHoc, repeatMode: .off,
            isShuffled: false, totalCount: 1, startAbsoluteIndex: 0
        )
        let b = ContinuityQueueBuilder.hash(
            items: enriched, descriptor: .adHoc, repeatMode: .off,
            isShuffled: false, totalCount: 1, startAbsoluteIndex: 0
        )
        #expect(a == b)
    }

    @Test("Shuffle and repeat participate in identity")
    func modesMatter() {
        let items = [item("t1", baseOrdinal: 0)]
        let base = ContinuityQueueBuilder.hash(
            items: items, descriptor: .adHoc, repeatMode: .off,
            isShuffled: false, totalCount: 1, startAbsoluteIndex: 0
        )
        let shuffled = ContinuityQueueBuilder.hash(
            items: items, descriptor: .adHoc, repeatMode: .off,
            isShuffled: true, totalCount: 1, startAbsoluteIndex: 0
        )
        let repeated = ContinuityQueueBuilder.hash(
            items: items, descriptor: .adHoc, repeatMode: .all,
            isShuffled: false, totalCount: 1, startAbsoluteIndex: 0
        )
        #expect(base != shuffled)
        #expect(base != repeated)
    }
}

@Suite("Continuity byte-budget window")
struct ContinuityWindowTests {

    /// Every id costs the same, so the arithmetic is easy to reason about.
    private func fixedCost(_ cost: Int) -> (Int) -> Int { { _ in cost } }

    @Test("A queue that fits is not truncated")
    func smallQueueFits() {
        let window = ContinuityQueueBuilder.window(
            itemCount: 10, currentIndex: 3, budget: 1000, encodedLength: fixedCost(10)
        )
        #expect(window.range == 0..<10)
        #expect(window.isTruncated == false)
    }

    @Test("The current item is always included, even on a starvation budget")
    func currentAlwaysSurvives() {
        let window = ContinuityQueueBuilder.window(
            itemCount: 100, currentIndex: 42, budget: 1, encodedLength: fixedCost(50)
        )
        #expect(window.range.contains(42))
        #expect(window.isTruncated)
    }

    @Test("Truncation favours what plays next over what already played")
    func biasedForward() {
        // Budget fits ~10 items; the current one sits in the middle of a long queue.
        let window = ContinuityQueueBuilder.window(
            itemCount: 1000, currentIndex: 500, budget: 100, encodedLength: fixedCost(10)
        )
        let ahead = window.range.upperBound - 500 - 1
        let behind = 500 - window.range.lowerBound
        #expect(ahead > behind, "expected a forward bias, got \(behind) behind / \(ahead) ahead")
        #expect(window.isTruncated)
    }

    @Test("Unused history budget is handed back to the tail")
    func spendsLeftoverForward() {
        // Current item is at the very start, so there is no history to buy;
        // the whole budget should go forward rather than being wasted.
        let window = ContinuityQueueBuilder.window(
            itemCount: 1000, currentIndex: 0, budget: 100, encodedLength: fixedCost(10)
        )
        #expect(window.range.lowerBound == 0)
        #expect(window.range.count >= 9)
    }

    @Test("An empty queue produces an empty window")
    func emptyQueue() {
        let window = ContinuityQueueBuilder.window(
            itemCount: 0, currentIndex: 0, budget: 1000, encodedLength: fixedCost(10)
        )
        #expect(window.range.isEmpty)
        #expect(window.isTruncated == false)
    }

    @Test("Longer ids yield a smaller window for the same budget")
    func costDrivesSize() {
        let cheap = ContinuityQueueBuilder.window(
            itemCount: 500, currentIndex: 250, budget: 400, encodedLength: fixedCost(10)
        )
        let costly = ContinuityQueueBuilder.window(
            itemCount: 500, currentIndex: 250, budget: 400, encodedLength: fixedCost(40)
        )
        #expect(cheap.range.count > costly.range.count)
    }
}

@Suite("Continuity snapshot semantics")
struct ContinuitySnapshotTests {

    private func cursor(queueHash: String?) -> ContinuityCursor {
        ContinuityCursor(
            playbackRunID: UUID(),
            deviceID: "device",
            cursorSequence: 1,
            capturedAtMS: 1_000,
            state: .paused,
            current: TrackLocator(server: fingerprint(), remoteID: "t1"),
            currentAbsoluteIndex: 0,
            positionMS: 30_000,
            queueHash: queueHash
        )
    }

    @Test("A cursor pointing at a queue we couldn't load reports the queue missing")
    func detectsMissingQueue() {
        let snapshot = ContinuitySnapshot(cursor: cursor(queueHash: "abc"), queue: nil)
        #expect(snapshot.isQueueMissing)
    }

    @Test("A track-only cursor is not treated as a missing queue")
    func trackOnlyIsNotMissing() {
        let snapshot = ContinuitySnapshot(cursor: cursor(queueHash: nil), queue: nil)
        #expect(snapshot.isQueueMissing == false)
    }

    @Test("Position converts from stored milliseconds")
    func positionConversion() {
        #expect(cursor(queueHash: nil).positionSeconds == 30)
    }
}

@Suite("Continuity identity")
struct ContinuityIdentityTests {

    @Test("Fingerprints without a server id are not comparable")
    func subsonicIsNotComparable() {
        // Generic Subsonic exposes no server UUID, so a mismatch would only mean
        // "different URL", not "different server" — comparing must be refused
        // rather than answered wrongly.
        let a = ServerAccountFingerprint(backend: .subsonic, serverID: "", accountID: "me")
        let b = ServerAccountFingerprint(backend: .subsonic, serverID: "", accountID: "me")
        #expect(a.isComparableAcross(b) == false)
    }

    @Test("Fingerprints with real server ids are comparable")
    func jellyfinIsComparable() {
        let a = ServerAccountFingerprint(backend: .jellyfin, serverID: "abc", accountID: "me")
        let b = ServerAccountFingerprint(backend: .jellyfin, serverID: "abc", accountID: "me")
        #expect(a.isComparableAcross(b))
        #expect(a == b)
    }
}
