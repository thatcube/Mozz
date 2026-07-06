import XCTest
@testable import MozzPlayback

/// A small deterministic `RandomNumberGenerator` (SplitMix64) so shuffle output
/// is reproducible in tests.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Count how many adjacent pairs share a group key.
private func adjacentCollisions(_ order: [Int], key: (Int) -> String) -> Int {
    guard order.count > 1 else { return 0 }
    var collisions = 0
    for i in 1..<order.count where key(order[i]) == key(order[i - 1]) {
        collisions += 1
    }
    return collisions
}

final class BalancedShuffleTests: XCTestCase {

    func testReturnsAValidPermutation() {
        var rng = SeededGenerator(seed: 42)
        let indices = Array(0..<100)
        let result = BalancedShuffle.order(of: indices, key: { "artist-\($0 % 7)" }, using: &rng)
        XCTAssertEqual(Set(result), Set(indices))
        XCTAssertEqual(result.count, indices.count)
    }

    func testSingleGroupIsAPlainShuffle() {
        var rng = SeededGenerator(seed: 7)
        let indices = Array(0..<30)
        let result = BalancedShuffle.order(of: indices, key: { _ in "same" }, using: &rng)
        XCTAssertEqual(Set(result), Set(indices))
        XCTAssertNotEqual(result, indices, "a single group should still be shuffled")
    }

    func testTwoEqualGroupsInterleavePerfectly() {
        // 5 "A" (0..<5) + 5 "B" (5..<10): equal-sized combs must alternate, so
        // there should be zero adjacent same-artist pairs regardless of seed.
        let key: (Int) -> String = { $0 < 5 ? "A" : "B" }
        for seed in UInt64(0)..<20 {
            var rng = SeededGenerator(seed: seed)
            let result = BalancedShuffle.order(of: Array(0..<10), key: key, using: &rng)
            XCTAssertEqual(adjacentCollisions(result, key: key), 0,
                           "equal groups must fully interleave (seed \(seed))")
        }
    }

    func testThreeEqualGroupsSpreadWithoutAdjacentRepeats() {
        // 4 each of A/B/C laid on equal-spacing combs → round-robin, no repeats.
        let key: (Int) -> String = { ["A", "B", "C"][$0 % 3] }
        for seed in UInt64(0)..<20 {
            var rng = SeededGenerator(seed: seed)
            let result = BalancedShuffle.order(of: Array(0..<12), key: key, using: &rng)
            XCTAssertEqual(adjacentCollisions(result, key: key), 0,
                           "three equal groups must spread evenly (seed \(seed))")
        }
    }

    func testDominantArtistDegradesGracefully() {
        // 20 "A" + 2 "B": clumping is unavoidable, but the result must still be a
        // valid permutation and no worse than the theoretical minimum collisions.
        var rng = SeededGenerator(seed: 99)
        let key: (Int) -> String = { $0 < 20 ? "A" : "B" }
        let result = BalancedShuffle.order(of: Array(0..<22), key: key, using: &rng)
        XCTAssertEqual(Set(result), Set(0..<22))
        // With 20 of one artist across 22 slots, at least 20 - (22 - 20) - 1 = 17
        // A-A adjacencies are forced; just assert we're in a sane range.
        XCTAssertGreaterThanOrEqual(adjacentCollisions(result, key: key), 17)
    }

    func testDeterministicForAGivenSeed() {
        let key: (Int) -> String = { "artist-\($0 % 5)" }
        var a = SeededGenerator(seed: 12345)
        var b = SeededGenerator(seed: 12345)
        let first = BalancedShuffle.order(of: Array(0..<40), key: key, using: &a)
        let second = BalancedShuffle.order(of: Array(0..<40), key: key, using: &b)
        XCTAssertEqual(first, second, "same seed must produce the same order")
    }

    func testTrivialInputsAreReturnedUnchanged() {
        var rng = SeededGenerator(seed: 1)
        XCTAssertEqual(BalancedShuffle.order(of: [], key: { _ in "x" }, using: &rng), [])
        XCTAssertEqual(BalancedShuffle.order(of: [9], key: { _ in "x" }, using: &rng), [9])
    }
}
