import Foundation

/// The G-Set union and the windowing that keeps a batch inside a backend's size
/// limit. Pure — no database, no network, no clock beyond what callers pass in —
/// so the semantics that matter can be tested exhaustively off-device.
public enum HistoryMerge {

    // MARK: Union

    /// Merge remote batches into the events this device already has.
    ///
    /// Returns only what is genuinely **new**, so the caller inserts exactly
    /// those and nothing else. Deduplication is by `uid`, which makes this
    /// idempotent: running the same merge twice yields nothing the second time.
    ///
    /// `ownDeviceID` is excluded because a device is the sole author of its own
    /// history. Re-importing its own events could only ever be a no-op at best,
    /// and at worst would resurrect events it deliberately trimmed.
    public static func newEvents(
        from batches: [HistoryBatch],
        known: Set<String>,
        ownDeviceID: String
    ) -> [HistoryEvent] {
        var seen = known
        var fresh: [HistoryEvent] = []

        for batch in batches where batch.deviceID != ownDeviceID {
            // A batch written by a newer client may encode things this build
            // cannot interpret. Skipping is the safe reading: history is
            // additive, so missing some events degrades recommendations
            // slightly, whereas misreading them corrupts the log permanently.
            guard batch.version <= HistoryBatch.currentVersion else { continue }

            for event in batch.events {
                // A batch is attributed to one device, so an event inside it
                // claiming a different author is either a bug or a forgery.
                // Either way it must not be attributed to the claimed device.
                guard event.deviceID == batch.deviceID else { continue }
                guard !event.uid.isEmpty, !seen.contains(event.uid) else { continue }
                seen.insert(event.uid)
                fresh.append(event)
            }
        }

        // Chronological, so a caller inserting in order keeps the local table
        // roughly time-ordered and any downstream "recent" query stays cheap.
        return fresh.sorted { $0.createdAtMS < $1.createdAtMS }
    }

    // MARK: Windowing

    /// The default history window.
    ///
    /// `TasteProfile` decays affinity with a 30-day half-life, so an event 180
    /// days old carries 2^-6 ≈ 1.6% of a fresh one's weight. Syncing beyond that
    /// spends payload on signal that is already almost zero.
    public static let defaultWindowDays = 180

    /// Trim events to a bounded, most-recent window that fits `maximumBytes`.
    ///
    /// Two limits apply, and the tighter wins:
    ///
    /// - **Age.** Anything older than the window is dropped, because it barely
    ///   affects taste (above).
    /// - **Size.** Backends cap what they will hold, and the cap is measured in
    ///   *encoded bytes* rather than event count — uids are fixed-width but
    ///   track refs and context strings are not, so a thousand events might be
    ///   40 KB or 200 KB.
    ///
    /// When the size limit binds, the **newest** events are kept: recent
    /// listening dominates the taste profile, so if something has to go it
    /// should be the oldest.
    ///
    /// Returns the retained events (chronological) alongside the effective
    /// `windowStartMS`, which is the later of the age cutoff and the oldest
    /// event actually retained — so a reader is told the truth about what the
    /// batch could contain rather than inferring it.
    public static func window(
        events: [HistoryEvent],
        now: Date,
        windowDays: Int = defaultWindowDays,
        maximumBytes: Int,
        encoder: JSONEncoder = HistoryMerge.makeEncoder()
    ) -> (events: [HistoryEvent], windowStartMS: Int64) {
        let nowMS = Int64(now.timeIntervalSince1970 * 1000)
        let cutoffMS = nowMS - Int64(max(0, windowDays)) * 86_400_000

        let recent = events
            .filter { $0.createdAtMS >= cutoffMS }
            .sorted { $0.createdAtMS < $1.createdAtMS }

        guard !recent.isEmpty else { return ([], cutoffMS) }

        // Encode once to learn the real average cost per event, then drop from
        // the oldest end until it fits. Measuring beats guessing: a synthetic
        // per-event estimate is wrong by a factor of several either way
        // depending on how long the user's track refs happen to be.
        var kept = recent
        while !kept.isEmpty, encodedSize(kept, encoder: encoder) > maximumBytes {
            // Drop a proportional slice rather than one event at a time, so an
            // oversized log converges in a few passes instead of thousands.
            let overshoot = Double(encodedSize(kept, encoder: encoder)) / Double(max(1, maximumBytes))
            let target = max(1, Int(Double(kept.count) / overshoot))
            let dropCount = max(1, kept.count - target)
            kept.removeFirst(min(dropCount, kept.count))
        }

        let effectiveStart = kept.first?.createdAtMS ?? cutoffMS
        return (kept, max(cutoffMS, effectiveStart))
    }

    private static func encodedSize(_ events: [HistoryEvent], encoder: JSONEncoder) -> Int {
        ((try? encoder.encode(events)) ?? Data()).count
    }

    /// A deterministic encoder. Sorted keys so a batch that has not changed
    /// serializes byte-identically and does not provoke a pointless write.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
