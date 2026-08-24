import Foundation
import MozzContinuity
import MozzCore
import MozzDatabase
import MozzPlayback

extension AppEnvironment {

    /// Accept a cross-device resume: load the other device's queue and pick up
    /// where it left off.
    ///
    /// Hydration order matters. The store may already have handed back full
    /// tracks — Subsonic's `getPlayQueue` returns complete song entries, so
    /// resolving them again would be a needless request per track. Anything
    /// still missing is looked up locally, and only what remains after that is
    /// fetched from the server.
    @MainActor
    public func continueHere(_ offer: ContinuityOffer, autoplay: Bool = true) async {
        let snapshot = offer.snapshot
        let cursor = snapshot.cursor

        guard let queue = snapshot.queue else {
            await continueTrackOnly(cursor, hydrated: snapshot.hydrated, autoplay: autoplay)
            continuity.dismissOffer()
            return
        }

        var resolved = snapshot.hydrated
        let missing = queue.items
            .map(\.locator.remoteID)
            .filter { resolved[$0] == nil }
        if !missing.isEmpty {
            for track in await hydrateTracks(ids: missing) {
                resolved[track.id] = track
            }
        }

        guard let rebuilt = ContinuityMapper.rebuild(
            from: queue,
            currentAbsoluteIndex: cursor.currentAbsoluteIndex,
            hydrate: { resolved[$0.locator.remoteID] }
        ) else {
            await continueTrackOnly(cursor, hydrated: resolved, autoplay: autoplay)
            continuity.dismissOffer()
            return
        }

        playback.restoreFromContinuity(
            tracks: rebuilt.tracks,
            realizedOrder: rebuilt.order,
            position: rebuilt.position,
            elapsed: cursor.positionSeconds,
            repeatMode: ContinuityMapper.repeatMode(queue.repeatMode),
            isShuffled: queue.isShuffled,
            autoplay: autoplay
        )
        continuity.dismissOffer()
    }

    /// Fallback when no queue survived: play the single track at its stored
    /// position. Still a genuinely useful resume — the track and position are
    /// exact — so it is a normal path, not an error.
    @MainActor
    private func continueTrackOnly(
        _ cursor: ContinuityCursor,
        hydrated: [String: Track],
        autoplay: Bool
    ) async {
        var track = hydrated[cursor.current.remoteID]
        if track == nil {
            track = await hydrateTracks(ids: [cursor.current.remoteID]).first
        }
        guard let track else { return }
        playback.restoreFromContinuity(
            tracks: [track],
            realizedOrder: [0],
            position: 0,
            elapsed: cursor.positionSeconds,
            repeatMode: .off,
            isShuffled: false,
            autoplay: autoplay
        )
    }

    /// Resolve provider ids to tracks, preferring the local catalog.
    ///
    /// The database is the single source of truth and already holds the whole
    /// synced library, so a device that has synced this server resolves the
    /// entire queue without touching the network. Whatever is left goes to the
    /// backend in **one batched call** — resolving track-by-track would be an
    /// N+1 storm on a queue of any size.
    @MainActor
    private func hydrateTracks(ids: [String]) async -> [Track] {
        guard let serverId = active?.connection.id else { return [] }
        var found: [String: Track] = [:]
        for id in ids {
            if let record = try? await repository.track(serverId: serverId, remoteId: id) {
                found[id] = record.toDomain()
            }
        }

        let stillMissing = ids.filter { found[$0] == nil }
        if !stillMissing.isEmpty, let backend = active?.backend,
           let fetched = try? await backend.fetchTrackDetails(ids: stillMissing) {
            for track in fetched { found[track.id] = track }
        }
        return ids.compactMap { found[$0] }
    }
}
