import Foundation

/// A spread ("balanced") shuffle. Where a plain uniform shuffle lets items that
/// share a grouping key — typically the same artist — land back-to-back by
/// chance, `BalancedShuffle` distributes each group evenly across the result so
/// the sequence *feels* random to a listener (the behavior Apple Music / Spotify
/// ship, and what users actually expect from "shuffle").
///
/// Method (the "even spacing + random phase" technique): group the items by
/// key, lay each group's members evenly across the unit timeline `[0, 1)` with a
/// random per-group phase, then order everything by position. Two equal-sized
/// groups therefore interleave perfectly; a single group degrades to a plain
/// uniform shuffle. It's O(n log n) and, with an injected generator, fully
/// deterministic for tests.
public enum BalancedShuffle {

    /// A balanced permutation of `indices`, grouping by `key`.
    ///
    /// - Parameters:
    ///   - indices: the elements to order (opaque to this type — usually indices
    ///     into a track array).
    ///   - key: extracts the grouping key (e.g. the normalized artist name).
    ///   - generator: the randomness source, injected so callers/tests control it.
    /// - Returns: a permutation of `indices` with same-key items spread apart.
    public static func order<G: RandomNumberGenerator>(
        of indices: [Int],
        key: (Int) -> String,
        using generator: inout G
    ) -> [Int] {
        guard indices.count > 1 else { return indices }

        var groups: [String: [Int]] = [:]
        for index in indices {
            groups[key(index), default: []].append(index)
        }

        // Nothing to spread against → a plain uniform shuffle.
        if groups.count == 1 {
            var only = indices
            only.shuffle(using: &generator)
            return only
        }

        // Iterate groups in a stable (sorted-key) order so RNG consumption is
        // deterministic given a seeded generator; the final ordering is decided
        // purely by absolute position, so this doesn't bias the result.
        var positioned: [(position: Double, index: Int)] = []
        positioned.reserveCapacity(indices.count)
        for groupKey in groups.keys.sorted() {
            var members = groups[groupKey] ?? []
            members.shuffle(using: &generator)          // random order within the group
            let spacing = 1.0 / Double(members.count)
            let phase = Double.random(in: 0..<spacing, using: &generator)  // random comb rotation
            for (offset, index) in members.enumerated() {
                positioned.append((phase + Double(offset) * spacing, index))
            }
        }

        return positioned
            .sorted { $0.position < $1.position }
            .map(\.index)
    }

    /// Convenience overload using the system randomness source.
    public static func order(of indices: [Int], key: (Int) -> String) -> [Int] {
        var generator = SystemRandomNumberGenerator()
        return order(of: indices, key: key, using: &generator)
    }
}
