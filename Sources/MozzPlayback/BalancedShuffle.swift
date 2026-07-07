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

/// A balanced permutation of `indices`, spreading by an ordered list of keys.
    ///
    /// Keys are applied hierarchically: items are grouped by the first key and
    /// those groups are laid on evenly-spaced combs (primary spread); within each
    /// group the members are themselves balanced by the remaining keys (secondary
    /// spread), before being placed on the comb. So `[artist, album]` spreads
    /// artists first and, wherever an artist's tracks land near each other, keeps
    /// same-album tracks apart too. An empty key list is a plain uniform shuffle.
    ///
    /// - Parameters:
    ///   - indices: the elements to order (usually indices into a track array).
    ///   - keyFns: ordered grouping keys, most significant first.
    ///   - generator: the randomness source, injected so callers/tests control it.
    public static func order<G: RandomNumberGenerator>(
        of indices: [Int],
        keys keyFns: [(Int) -> String],
        using generator: inout G
    ) -> [Int] {
        guard indices.count > 1 else { return indices }
        guard let firstKey = keyFns.first else {
            var shuffled = indices
            shuffled.shuffle(using: &generator)
            return shuffled
        }
        let rest = Array(keyFns.dropFirst())

        var groups: [String: [Int]] = [:]
        for index in indices {
            groups[firstKey(index), default: []].append(index)
        }
        // Nothing to spread against at this level → defer to the remaining keys.
        if groups.count == 1 {
            return order(of: indices, keys: rest, using: &generator)
        }

        // Iterate groups in a stable (sorted-key) order so RNG consumption is
        // deterministic given a seeded generator; the final ordering is decided
        // purely by absolute position, so this doesn't bias the result.
        var positioned: [(position: Double, index: Int)] = []
        positioned.reserveCapacity(indices.count)
        for groupKey in groups.keys.sorted() {
            let members = groups[groupKey] ?? []
            // Balance the members by the remaining keys (secondary spread).
            let suborder = order(of: members, keys: rest, using: &generator)
            let spacing = 1.0 / Double(suborder.count)
            let phase = Double.random(in: 0..<spacing, using: &generator)  // random comb rotation
            for (offset, index) in suborder.enumerated() {
                positioned.append((phase + Double(offset) * spacing, index))
            }
        }

        return positioned
            .sorted { $0.position < $1.position }
            .map(\.index)
    }

    /// Single-key convenience (equivalent to `keys: [key]`).
    public static func order<G: RandomNumberGenerator>(
        of indices: [Int],
        key: @escaping (Int) -> String,
        using generator: inout G
    ) -> [Int] {
        order(of: indices, keys: [key], using: &generator)
    }

    /// Convenience overload using the system randomness source.
    public static func order(of indices: [Int], keys keyFns: [(Int) -> String]) -> [Int] {
        var generator = SystemRandomNumberGenerator()
        return order(of: indices, keys: keyFns, using: &generator)
    }

    /// Convenience overload using the system randomness source.
    public static func order(of indices: [Int], key: @escaping (Int) -> String) -> [Int] {
        var generator = SystemRandomNumberGenerator()
        return order(of: indices, keys: [key], using: &generator)
    }
}
