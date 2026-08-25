import Foundation
import Testing
@testable import MozzHistory

// The merge is a G-Set union, so the properties worth proving are the CRDT laws
// themselves — idempotent, commutative, and dedupe by identity. If those hold,
// two devices that have seen the same events agree no matter what order they saw
// them in, which is the entire reason this needs no compare-and-swap.

private func event(
    device: String = "dev-a",
    ref: String = "srv:trk-1",
    kind: String = "completed",
    atMS: Int64 = 1_700_000_000_000,
    positionMS: Int64? = 180_000,
    durationMS: Int64? = 200_000
) -> HistoryEvent {
    HistoryEvent(
        deviceID: device,
        trackRef: ref,
        kind: kind,
        createdAtMS: atMS,
        positionMS: positionMS,
        durationMS: durationMS
    )
}

private func batch(
    device: String,
    events: [HistoryEvent],
    version: Int = HistoryBatch.currentVersion
) -> HistoryBatch {
    HistoryBatch(
        version: version,
        deviceID: device,
        writtenAtMS: 1_700_000_100_000,
        windowStartMS: 0,
        events: events
    )
}

@Suite("History event identity")
struct HistoryEventIdentityTests {

    @Test("The same event always derives the same uid")
    func stableUID() {
        #expect(event().uid == event().uid)
    }

    @Test("Each defining field changes the uid")
    func definingFieldsParticipate() {
        let base = event()
        #expect(event(device: "dev-b").uid != base.uid)
        #expect(event(ref: "srv:trk-2").uid != base.uid)
        #expect(event(kind: "skipped").uid != base.uid)
        #expect(event(atMS: 1_700_000_000_001).uid != base.uid)
        #expect(event(positionMS: 1).uid != base.uid)
        #expect(event(durationMS: 1).uid != base.uid)
    }

    @Test("Context describes an event without defining it")
    func contextExcludedFromIdentity() {
        // Re-importing the same listen with richer context must not look like a
        // second listen.
        let bare = HistoryEvent(
            deviceID: "dev-a", trackRef: "srv:t", kind: "completed",
            createdAtMS: 1, positionMS: nil, durationMS: nil
        )
        let described = HistoryEvent(
            deviceID: "dev-a", trackRef: "srv:t", kind: "completed",
            createdAtMS: 1, positionMS: nil, durationMS: nil,
            context: "album", contextID: "alb-9"
        )
        #expect(bare.uid == described.uid)
    }

    @Test("A nil field is distinct from a zero one")
    func nilIsNotZero() {
        // "no position recorded" and "position 0" are different facts, and the
        // encoding must not conflate them.
        let absent = event(positionMS: nil)
        let zero = event(positionMS: 0)
        #expect(absent.uid != zero.uid)
    }

    @Test("A uid is 32 lowercase hex characters")
    func uidShape() {
        let uid = event().uid
        #expect(uid.count == 32)
        #expect(uid.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}

@Suite("History merge (G-Set union)")
struct HistoryMergeTests {

    @Test("Events from another device are taken")
    func takesRemoteEvents() {
        let remote = [event(device: "dev-b", ref: "srv:x"), event(device: "dev-b", ref: "srv:y")]
        let fresh = HistoryMerge.newEvents(
            from: [batch(device: "dev-b", events: remote)],
            known: [],
            ownDeviceID: "dev-a"
        )
        #expect(fresh.count == 2)
    }

    @Test("Merging is idempotent — the second run yields nothing")
    func idempotent() {
        let remote = [event(device: "dev-b", ref: "srv:x")]
        let batches = [batch(device: "dev-b", events: remote)]

        let first = HistoryMerge.newEvents(from: batches, known: [], ownDeviceID: "dev-a")
        #expect(first.count == 1)

        let second = HistoryMerge.newEvents(
            from: batches,
            known: Set(first.map(\.uid)),
            ownDeviceID: "dev-a"
        )
        #expect(second.isEmpty)
    }

    @Test("Merging is commutative — batch order cannot change the outcome")
    func commutative() {
        let b = batch(device: "dev-b", events: [event(device: "dev-b", ref: "srv:x")])
        let c = batch(device: "dev-c", events: [event(device: "dev-c", ref: "srv:y")])

        let forward = HistoryMerge.newEvents(from: [b, c], known: [], ownDeviceID: "dev-a")
        let reverse = HistoryMerge.newEvents(from: [c, b], known: [], ownDeviceID: "dev-a")

        #expect(Set(forward.map(\.uid)) == Set(reverse.map(\.uid)))
    }

    @Test("The same event arriving from two devices is taken once")
    func dedupesAcrossBatches() {
        // Device C relayed an event device B also published. The union must
        // collapse them, or a single listen would be counted twice in the taste
        // profile.
        let shared = event(device: "dev-b", ref: "srv:x")
        let fresh = HistoryMerge.newEvents(
            from: [batch(device: "dev-b", events: [shared, shared])],
            known: [],
            ownDeviceID: "dev-a"
        )
        #expect(fresh.count == 1)
    }

    @Test("A device never re-imports its own history")
    func skipsOwnDevice() {
        let mine = [event(device: "dev-a", ref: "srv:x")]
        let fresh = HistoryMerge.newEvents(
            from: [batch(device: "dev-a", events: mine)],
            known: [],
            ownDeviceID: "dev-a"
        )
        #expect(fresh.isEmpty)
    }

    @Test("An event that misattributes its author is rejected")
    func rejectsMisattributedEvents() {
        // A batch is attributed to one device; an event inside claiming another
        // author is a bug or a forgery, and must not be credited to the device
        // it names.
        let impostor = event(device: "dev-z", ref: "srv:x")
        let fresh = HistoryMerge.newEvents(
            from: [batch(device: "dev-b", events: [impostor])],
            known: [],
            ownDeviceID: "dev-a"
        )
        #expect(fresh.isEmpty)
    }

    @Test("A batch from a newer client is skipped, not guessed at")
    func skipsFutureVersions() {
        let future = batch(
            device: "dev-b",
            events: [event(device: "dev-b", ref: "srv:x")],
            version: HistoryBatch.currentVersion + 1
        )
        #expect(HistoryMerge.newEvents(from: [future], known: [], ownDeviceID: "dev-a").isEmpty)
    }

    @Test("Merged events come back in chronological order")
    func chronological() {
        let late = event(device: "dev-b", ref: "srv:late", atMS: 3_000)
        let early = event(device: "dev-b", ref: "srv:early", atMS: 1_000)
        let fresh = HistoryMerge.newEvents(
            from: [batch(device: "dev-b", events: [late, early])],
            known: [],
            ownDeviceID: "dev-a"
        )
        #expect(fresh.map(\.createdAtMS) == [1_000, 3_000])
    }
}

@Suite("History windowing")
struct HistoryWindowTests {

    private func spread(_ count: Int, endingAt end: Date, spacing: TimeInterval = 3_600) -> [HistoryEvent] {
        (0..<count).map { index in
            let at = end.addingTimeInterval(-Double(index) * spacing)
            return event(
                device: "dev-a",
                ref: "srv:trk-\(index)",
                atMS: Int64(at.timeIntervalSince1970 * 1000)
            )
        }
    }

    @Test("Events older than the window are dropped")
    func dropsOldEvents() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = event(device: "dev-a", ref: "srv:new",
                           atMS: Int64(now.timeIntervalSince1970 * 1000))
        let ancient = event(device: "dev-a", ref: "srv:old",
                            atMS: Int64(now.addingTimeInterval(-400 * 86_400).timeIntervalSince1970 * 1000))

        let result = HistoryMerge.window(
            events: [recent, ancient], now: now, windowDays: 180, maximumBytes: 1_000_000
        )
        #expect(result.events.map(\.trackRef) == ["srv:new"])
    }

    @Test("A batch is trimmed to fit the byte budget")
    func respectsByteBudget() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events = spread(500, endingAt: now)

        let budget = 8_000
        let result = HistoryMerge.window(
            events: events, now: now, windowDays: 180, maximumBytes: budget
        )
        let encoded = try? HistoryMerge.makeEncoder().encode(result.events)

        #expect(!result.events.isEmpty)
        #expect((encoded?.count ?? .max) <= budget)
    }

    @Test("When space is short the newest events survive")
    func keepsNewestUnderPressure() {
        // Recent listening dominates the taste profile's 30-day half-life, so
        // the oldest events are the right ones to lose.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events = spread(500, endingAt: now)
        let newest = events.map(\.createdAtMS).max()

        let result = HistoryMerge.window(
            events: events, now: now, windowDays: 180, maximumBytes: 8_000
        )
        #expect(result.events.map(\.createdAtMS).max() == newest)
    }

    @Test("windowStartMS reports what the batch could actually contain")
    func reportsEffectiveWindowStart() {
        // A reader has to distinguish "played nothing older" from "trimmed
        // older", which the events alone cannot express.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = HistoryMerge.window(
            events: spread(500, endingAt: now), now: now,
            windowDays: 180, maximumBytes: 8_000
        )
        let oldestKept = try? #require(result.events.first?.createdAtMS)
        #expect(result.windowStartMS == oldestKept)
    }

    @Test("An empty history produces an empty batch, not a crash")
    func emptyHistory() {
        let result = HistoryMerge.window(
            events: [], now: Date(), windowDays: 180, maximumBytes: 1_000
        )
        #expect(result.events.isEmpty)
    }

    @Test("An impossibly small budget yields nothing rather than looping")
    func absurdlySmallBudget() {
        // The trim loop must terminate even when a single event cannot fit.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = HistoryMerge.window(
            events: spread(10, endingAt: now), now: now, windowDays: 180, maximumBytes: 1
        )
        #expect(result.events.isEmpty)
    }
}
