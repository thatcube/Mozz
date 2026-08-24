import Foundation
import MozzContinuity
import MozzCore
import MozzPlayback

/// Translates between the playback engine's types and the portable continuity
/// wire types.
///
/// This lives in `MozzApp` because it is the only module that imports both:
/// `MozzPlayback` deliberately has no dependency on `MozzContinuity`, which is
/// why the wire format carries its own `ContinuityRepeatMode` rather than
/// reusing the engine's `RepeatMode`.
enum ContinuityMapper {

    static func repeatMode(_ mode: MozzPlayback.RepeatMode) -> ContinuityRepeatMode {
        switch mode {
        case .off: return .off
        case .one: return .one
        case .all: return .all
        }
    }

    static func repeatMode(_ mode: ContinuityRepeatMode) -> MozzPlayback.RepeatMode {
        switch mode {
        case .off: return .off
        case .one: return .one
        case .all: return .all
        }
    }

    static func state(_ status: PlaybackStatus) -> ContinuityPlaybackState {
        switch status {
        case .playing, .buffering: return .playing
        case .paused: return .paused
        case .idle: return .stopped
        }
    }

    /// The queue as items in **realized playback order**, each tagged with its
    /// index in the base order.
    ///
    /// `baseOrdinal` is the whole point: it is what lets the receiving device
    /// turn shuffle off and get the original album order back. It cannot be
    /// recomputed there, because Mozz's shuffle is biased by device-local
    /// recency and taste scores.
    static func items(
        from queue: PlayQueue,
        fingerprint: ServerAccountFingerprint
    ) -> [ContinuityItem] {
        queue.order.compactMap { baseIndex in
            guard queue.tracks.indices.contains(baseIndex) else { return nil }
            let track = queue.tracks[baseIndex]
            return ContinuityItem(
                locator: TrackLocator(server: fingerprint, remoteID: track.id),
                baseOrdinal: baseIndex,
                title: track.title,
                artist: track.artistName,
                durationMS: Int64(track.duration * 1000),
                artwork: track.artwork
            )
        }
    }

    /// Rebuild the base track list and the realized order from a stored queue.
    ///
    /// Returns tracks in **base** order plus the permutation that reproduces the
    /// sending device's playback order, ready for
    /// `PlaybackEngine.restoreFromContinuity`.
    ///
    /// `hydrate` resolves a locator to a real `Track`; items it cannot resolve
    /// are dropped rather than failing the whole handoff, since a single track
    /// removed from the server should not cost the user their queue.
    static func rebuild(
        from queue: ContinuityQueue,
        currentAbsoluteIndex: Int,
        hydrate: (ContinuityItem) -> Track?
    ) -> (tracks: [Track], order: [Int], position: Int)? {
        // Resolve in realized order, remembering each item's base ordinal.
        var resolved: [(track: Track, baseOrdinal: Int)] = []
        var currentResolvedIndex: Int?
        for (realizedIndex, item) in queue.items.enumerated() {
            guard let track = hydrate(item) else { continue }
            if realizedIndex + queue.startAbsoluteIndex == currentAbsoluteIndex {
                currentResolvedIndex = resolved.count
            }
            resolved.append((track, item.baseOrdinal))
        }
        guard !resolved.isEmpty else { return nil }

        // Base order = sorted by baseOrdinal. Dropped items leave gaps, so the
        // ordinals are re-densified rather than used as indices directly.
        let baseSorted = resolved.enumerated()
            .sorted { $0.element.baseOrdinal < $1.element.baseOrdinal }
        var realizedToBase = [Int](repeating: 0, count: resolved.count)
        var tracks: [Track] = []
        tracks.reserveCapacity(resolved.count)
        for (baseIndex, entry) in baseSorted.enumerated() {
            tracks.append(entry.element.track)
            realizedToBase[entry.offset] = baseIndex
        }
        return (tracks, realizedToBase, currentResolvedIndex ?? 0)
    }
}
