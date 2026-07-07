import Foundation
import MozzCore
import MozzDatabase

/// Orchestrates open metadata enrichment (ADR-0007): fills in MusicBrainz IDs the
/// backend didn't already embed, via rate-limited MusicBrainz name-search, and
/// records hits + misses in the DB. Network + policy only — persistence lives in
/// `EnrichmentStore`, so `MozzRecommend` reads results without a network path.
///
/// Gated by `isEnabled` (re-checked before every outbound call, so turning the
/// feature off promptly halts an in-flight crawl). The background pass is
/// single-flight and cancellable (server switch / sign-out); on-demand seed
/// resolution shares the same rate limiter via the injected client.
public actor EnrichmentService {
    private let store: EnrichmentStore
    private let musicBrainz: MusicBrainzClient
    private let config: EnrichmentConfig
    private let isEnabled: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void

    private var backgroundPass: Task<Void, Never>?
    /// Bumped whenever a pass is started or cancelled, so a stale task's cleanup
    /// can't clear a newer pass's registration (single-flight/cancellation safety).
    private var generation = 0

    public init(store: EnrichmentStore,
                musicBrainz: MusicBrainzClient,
                config: EnrichmentConfig,
                isEnabled: @escaping @Sendable () -> Bool,
                now: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store
        self.musicBrainz = musicBrainz
        self.config = config
        self.isEnabled = isEnabled
        self.now = now
        self.log = log
    }

    // MARK: - Background resolution (fire-and-forget, single-flight)

    /// Kick a bounded background pass that resolves MBIDs for tracks that lack
    /// them, prioritized by the store (recently played / favorites first). No-op
    /// when disabled or when a pass is already running. Never awaited by the
    /// caller (a sync must not appear to hang for minutes).
    public func resolvePending(serverId: ServerID) {
        guard isEnabled() else { return }
        guard backgroundPass == nil else { return }
        generation += 1
        let gen = generation
        backgroundPass = Task { [weak self] in
            await self?.runResolvePending(serverId: serverId)
            await self?.finishBackgroundPass(gen)
        }
    }

    /// Cancel any in-flight background pass (server switch / sign-out).
    public func cancel() {
        generation += 1 // invalidate the running task's cleanup
        backgroundPass?.cancel()
        backgroundPass = nil
    }

    /// Clear the handle only if this task is still the current pass — a stale
    /// (cancelled/superseded) task must not clear a newer pass's registration.
    private func finishBackgroundPass(_ gen: Int) {
        guard gen == generation else { return }
        backgroundPass = nil
    }

    /// Test hook: await the in-flight background pass, if any.
    func waitForBackgroundPass() async { await backgroundPass?.value }

    private func runResolvePending(serverId: ServerID) async {
        let cutoff = now().addingTimeInterval(-config.lookupTTL).timeIntervalSince1970
        let candidates: [MBIDResolutionCandidate]
        do {
            candidates = try await store.tracksNeedingResolution(
                serverId: serverId, notLookedUpSince: cutoff, limit: config.perRunBudget)
        } catch {
            log("enrichment: fetching candidates failed: \(error)")
            return
        }

        for candidate in candidates {
            if Task.isCancelled { return }
            // Re-check on every iteration: disabling enrichment mid-crawl must stop
            // further outbound requests (privacy-sensitive).
            guard isEnabled() else { return }
            do {
                let match = try await musicBrainz.bestRecording(
                    artist: candidate.artistName, title: candidate.title,
                    durationMs: candidate.durationMs, artistMBID: candidate.existingArtistMbid)
                try await store.recordTrackResolution(
                    trackRef: candidate.trackRef,
                    mbid: match?.recordingMBID,
                    artistMbid: match?.artistMBID,
                    at: now().timeIntervalSince1970)
            } catch is CancellationError {
                return // Never swallow cancellation.
            } catch let error as MozzError where error == .cancelled {
                return // URLSession maps a cancelled request to MozzError.cancelled.
            } catch {
                // A transient failure (network/decoding) shouldn't poison the
                // negative cache — leave the track for a future pass.
                log("enrichment: resolving \(candidate.trackRef) failed: \(error)")
            }
        }
    }

    // MARK: - On-demand seed resolution (used by radio, B3)

    /// Resolve (and cache) the recording MBID for a single seed track on demand.
    /// Returns an already-stored MBID immediately; otherwise name-searches once.
    /// Shares the rate limiter with the background pass. `nil` when disabled or
    /// unresolved.
    @discardableResult
    public func resolveSeed(trackRef: String, artistName: String, title: String,
                            durationMs: Double?, artistMBID: String?) async -> String? {
        guard isEnabled() else { return nil }
        if let state = try? await store.mbidState(trackRef: trackRef), let mbid = state.mbid {
            return mbid
        }
        do {
            let match = try await musicBrainz.bestRecording(
                artist: artistName, title: title, durationMs: durationMs, artistMBID: artistMBID)
            try await store.recordTrackResolution(
                trackRef: trackRef, mbid: match?.recordingMBID,
                artistMbid: match?.artistMBID, at: now().timeIntervalSince1970)
            return match?.recordingMBID
        } catch {
            log("enrichment: resolving seed \(trackRef) failed: \(error)")
            return nil
        }
    }
}
