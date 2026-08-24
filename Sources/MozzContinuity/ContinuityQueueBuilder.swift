#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Builds the stored queue: content hashing, and the byte-budget window that
/// Subsonic's URL-length limit forces.
///
/// All of this is deliberately pure so it can be unit-tested without a server.
public enum ContinuityQueueBuilder {

    // MARK: Canonical hashing

    /// A deterministic, cross-platform byte encoding of the parts of a queue
    /// that define its identity.
    ///
    /// Written by hand rather than via `JSONEncoder` because stock JSON encoding
    /// is *not* canonical — key order and float formatting vary — and the whole
    /// point of the hash is that a different implementation on another platform
    /// can compute the same value and agree. Rules, which any reimplementation
    /// must follow exactly:
    ///
    /// - Fields are joined with `\u{1}`, records with `\u{2}`.
    /// - Durations are integer milliseconds rendered in base 10.
    /// - Only identity-defining fields participate: the ordered locators, their
    ///   base ordinals, the descriptor, and the shuffle/repeat modes. Display
    ///   metadata (title, artist, artwork) is excluded, so re-fetching richer
    ///   metadata does not invalidate an otherwise identical queue.
    ///
    /// Public so a reimplementation on another platform can compare its
    /// *intermediate* encoding, not just the final digest. When two platforms
    /// disagree on a hash, the bytes are where the difference actually is, and
    /// having them makes that a five-minute diff instead of a guessing game.
    /// See `spec/continuity/` for the golden fixtures both sides must satisfy.
    public static func canonicalBytes(
        items: [ContinuityItem],
        descriptor: QueueDescriptor,
        repeatMode: ContinuityRepeatMode,
        isShuffled: Bool,
        totalCount: Int,
        startAbsoluteIndex: Int
    ) -> Data {
        var parts: [String] = [
            "v1",
            descriptor.kind.rawValue,
            descriptor.sourceID ?? "",
            descriptor.sourceRevision ?? "",
            repeatMode.rawValue,
            isShuffled ? "1" : "0",
            String(totalCount),
            String(startAbsoluteIndex),
        ]
        for item in items {
            parts.append([
                item.locator.server.backend.rawValue,
                item.locator.server.serverID,
                item.locator.server.accountID,
                item.locator.remoteID,
                String(item.baseOrdinal),
            ].joined(separator: "\u{1}"))
        }
        return Data(parts.joined(separator: "\u{2}").utf8)
    }

    /// SHA-256 of ``canonicalBytes(items:descriptor:repeatMode:isShuffled:totalCount:startAbsoluteIndex:)``,
    /// lowercase hex.
    public static func hash(
        items: [ContinuityItem],
        descriptor: QueueDescriptor,
        repeatMode: ContinuityRepeatMode,
        isShuffled: Bool,
        totalCount: Int,
        startAbsoluteIndex: Int
    ) -> String {
        let digest = SHA256.hash(data: canonicalBytes(
            items: items,
            descriptor: descriptor,
            repeatMode: repeatMode,
            isShuffled: isShuffled,
            totalCount: totalCount,
            startAbsoluteIndex: startAbsoluteIndex
        ))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Assemble a queue record, computing its hash.
    public static func make(
        items: [ContinuityItem],
        descriptor: QueueDescriptor,
        repeatMode: ContinuityRepeatMode,
        isShuffled: Bool,
        totalCount: Int,
        startAbsoluteIndex: Int = 0,
        isTruncated: Bool = false
    ) -> ContinuityQueue {
        ContinuityQueue(
            queueHash: hash(
                items: items,
                descriptor: descriptor,
                repeatMode: repeatMode,
                isShuffled: isShuffled,
                totalCount: totalCount,
                startAbsoluteIndex: startAbsoluteIndex
            ),
            descriptor: descriptor,
            items: items,
            startAbsoluteIndex: startAbsoluteIndex,
            totalCount: totalCount,
            isTruncated: isTruncated,
            repeatMode: repeatMode,
            isShuffled: isShuffled
        )
    }

    // MARK: Byte-budget window

    /// The result of fitting a queue into a byte budget.
    public struct Window: Sendable, Equatable {
        /// Indices into the original array, in order.
        public var range: Range<Int>
        public var isTruncated: Bool
    }

    /// Default budget for Subsonic's `savePlayQueue`.
    ///
    /// `savePlayQueue` takes the queue as repeated `id=` parameters on a **GET**
    /// URL (the Subsonic client has no form-POST path), so the limit is the
    /// request line, not storage. 6 KiB leaves generous headroom under the
    /// common 8 KiB server/proxy default once the base URL and auth parameters
    /// are accounted for.
    public static let defaultByteBudget = 6 * 1024

    /// Choose the widest window around `currentIndex` that fits `budget`.
    ///
    /// Biased toward what comes *next*: the tail is what playback needs to keep
    /// going, while history is a convenience. Two thirds of the budget goes
    /// forward, and any unspent forward budget is handed back to history (and
    /// vice versa), so a queue near its end still carries useful context.
    ///
    /// - Parameter encodedLength: byte cost of one item, letting the caller
    ///   account for percent-encoding of real ids.
    public static func window(
        itemCount: Int,
        currentIndex: Int,
        budget: Int = defaultByteBudget,
        encodedLength: (Int) -> Int
    ) -> Window {
        guard itemCount > 0 else { return Window(range: 0..<0, isTruncated: false) }
        let current = min(max(currentIndex, 0), itemCount - 1)

        // The current item is non-negotiable: it is the resume point.
        var spent = encodedLength(current)
        var lower = current
        var upper = current

        // Grow forward first, up to two thirds of the budget...
        let forwardBudget = (budget - spent) * 2 / 3
        var forwardSpent = 0
        var next = current + 1
        while next < itemCount {
            let cost = encodedLength(next)
            if forwardSpent + cost > forwardBudget { break }
            forwardSpent += cost
            upper = next
            next += 1
        }
        spent += forwardSpent

        // ...then spend everything left — including unused forward budget — on
        // history.
        var previous = current - 1
        while previous >= 0 {
            let cost = encodedLength(previous)
            if spent + cost > budget { break }
            spent += cost
            lower = previous
            previous -= 1
        }

        // Any budget still unspent (history ran out) goes back to the tail.
        next = upper + 1
        while next < itemCount {
            let cost = encodedLength(next)
            if spent + cost > budget { break }
            spent += cost
            upper = next
            next += 1
        }

        let range = lower..<(upper + 1)
        return Window(range: range, isTruncated: range.count < itemCount)
    }
}
