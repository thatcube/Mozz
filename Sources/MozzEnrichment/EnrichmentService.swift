import Foundation
import MozzCore
import MozzDatabase

/// Orchestrates open metadata enrichment (ADR-0007). A single background pass
/// runs four stages in order, so each depends on the previous:
///   1. resolve MusicBrainz recording MBIDs the backend didn't embed (B1);
///   2. canonicalize those MBIDs via ListenBrainz (similarity is canonical-keyed);
///   3. fetch ListenBrainz similar-recordings for the canonical MBIDs (B2);
///   4. capture MusicBrainz artist-genre tags into `mb_tags` (B4 data capture —
///      stored but not yet wired into the genre engine; that's B4.5).
///
/// Network + policy only — persistence lives in `EnrichmentStore`, so
/// `MozzRecommend` reads results without any network path. Gated by `isEnabled`
/// (re-checked before every outbound call). The pass is single-flight and
/// cancellable as a unit (server switch / sign-out). MusicBrainz and ListenBrainz
/// use SEPARATE rate limiters (different hosts/policies).
public actor EnrichmentService {
    private let store: EnrichmentStore
    private let musicBrainz: MusicBrainzClient
    private let listenBrainz: ListenBrainzClient
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
                listenBrainz: ListenBrainzClient,
                config: EnrichmentConfig,
                isEnabled: @escaping @Sendable () -> Bool,
                now: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store
        self.musicBrainz = musicBrainz
        self.listenBrainz = listenBrainz
        self.config = config
        self.isEnabled = isEnabled
        self.now = now
        self.log = log
    }

    // MARK: - Background pass (fire-and-forget, single-flight, 3 stages)

    /// Kick a bounded background enrichment pass (resolve -> canonicalize ->
    /// similarity -> tags). No-op when disabled or already running. Never awaited
    /// by the caller (a sync must not appear to hang for minutes).
    public func enrich(serverId: ServerID) {
        guard isEnabled() else { return }
        guard backgroundPass == nil else { return }
        generation += 1
        let gen = generation
        backgroundPass = Task { [weak self] in
            await self?.runPipeline(serverId: serverId)
            await self?.finishBackgroundPass(gen)
        }
    }

    /// Cancel the whole in-flight pass (server switch / sign-out).
    public func cancel() {
        generation += 1 // invalidate the running task's cleanup
        backgroundPass?.cancel()
        backgroundPass = nil
    }

    private func finishBackgroundPass(_ gen: Int) {
        guard gen == generation else { return }
        backgroundPass = nil
    }

    /// Test hook: await the in-flight background pass, if any.
    func waitForBackgroundPass() async { await backgroundPass?.value }

    private func runPipeline(serverId: ServerID) async {
        do {
            try await resolveStage(serverId: serverId)
            try await canonicalizeStage(serverId: serverId)
            try await similarityStage(serverId: serverId)
            try await tagStage(serverId: serverId)
        } catch is CancellationError {
            return
        } catch let error as MozzError where error == .cancelled {
            return
        } catch {
            log("enrichment: pipeline stopped: \(error)")
        }
    }

    /// Returns whether enrichment is still enabled; throws `CancellationError` to
    /// unwind the pipeline when the task was cancelled.
    private func checkpoint() throws -> Bool {
        if Task.isCancelled { throw CancellationError() }
        return isEnabled()
    }

    // Stage 1 - resolve recording MBIDs (MusicBrainz name-search).
    private func resolveStage(serverId: ServerID) async throws {
        let cutoff = now().addingTimeInterval(-config.lookupTTL).timeIntervalSince1970
        let candidates = try await store.tracksNeedingResolution(
            serverId: serverId, notLookedUpSince: cutoff, limit: config.perRunBudget)
        for candidate in candidates {
            guard try checkpoint() else { return }
            do {
                let match = try await musicBrainz.bestRecording(
                    artist: candidate.artistName, title: candidate.title,
                    durationMs: candidate.durationMs, artistMBID: candidate.existingArtistMbid)
                try await store.recordTrackResolution(
                    trackRef: candidate.trackRef, mbid: match?.recordingMBID,
                    artistMbid: match?.artistMBID, at: now().timeIntervalSince1970)
            } catch is CancellationError { throw CancellationError() }
            catch let e as MozzError where e == .cancelled { throw CancellationError() }
            catch { log("enrichment: resolve \(candidate.trackRef) failed: \(error)") }
        }
    }

    // Stage 2 - canonicalize resolved MBIDs (ListenBrainz recording-mbid-lookup).
    private func canonicalizeStage(serverId: ServerID) async throws {
        let cutoff = now().addingTimeInterval(-config.lookupTTL).timeIntervalSince1970
        let mbids = try await store.canonicalNeedingLookup(
            serverId: serverId, notLookedUpSince: cutoff, limit: config.canonicalPerRunBudget)
        for mbid in mbids {
            guard try checkpoint() else { return }
            do {
                // nil = decoded-but-no-mapping (safe to stamp for TTL); a throw is a
                // transport/decode/cancel failure — skip stamping so we retry later.
                let canonical = try await listenBrainz.canonicalRecording(forMbid: mbid)
                try await store.setCanonical(mbid: mbid, canonical: canonical,
                                             at: now().timeIntervalSince1970)
            } catch is CancellationError { throw CancellationError() }
            catch let e as MozzError where e == .cancelled { throw CancellationError() }
            catch { log("enrichment: canonicalize \(mbid) failed: \(error)") }
        }
    }

    // Stage 3 - fetch similar recordings for canonical MBIDs (ListenBrainz).
    private func similarityStage(serverId: ServerID) async throws {
        let cutoff = now().addingTimeInterval(-config.lookupTTL).timeIntervalSince1970
        let canonicals = try await store.recordingsNeedingSimilarity(
            serverId: serverId, notFetchedSince: cutoff,
            algorithm: config.listenBrainzAlgorithm, limit: config.similarityPerRunBudget)
        for canonical in canonicals {
            guard try checkpoint() else { return }
            do {
                let similar = try await listenBrainz.similarRecordings(forCanonicalMbid: canonical)
                try await store.replaceSimilarRecordings(
                    sourceMbid: canonical, algorithm: config.listenBrainzAlgorithm,
                    pairs: similar.map { ($0.recordingMBID, $0.score) },
                    at: now().timeIntervalSince1970)
            } catch is CancellationError { throw CancellationError() }
            catch let e as MozzError where e == .cancelled { throw CancellationError() }
            catch { log("enrichment: similar \(canonical) failed: \(error)") }
        }
    }

    // Stage 4 - capture MusicBrainz artist-genre tags (B4 data capture).
    // Enriches by artist_mbid (dense; recording genres are ~empty), one call per
    // distinct artist. Writes to the DISTINCT `mb_tags` column — NOT yet consumed
    // by the genre engine (deferred to B4.5), so it can never regress radio today.
    private func tagStage(serverId: ServerID) async throws {
        let cutoff = now().addingTimeInterval(-config.lookupTTL).timeIntervalSince1970
        let artistMbids = try await store.artistsNeedingTags(
            serverId: serverId, notLookedUpSince: cutoff, limit: config.tagPerRunBudget)
        for artistMbid in artistMbids {
            guard try checkpoint() else { return }
            do {
                // A throw is a transport/decode/cancel failure — skip stamping so we
                // retry later. An empty array is a valid "artist has no genres" result
                // and IS stamped (TTL negative cache).
                let tags = try await musicBrainz.artistGenres(forArtistMbid: artistMbid)
                try await store.setArtistTags(artistMbid: artistMbid, tags: tags,
                                              at: now().timeIntervalSince1970)
            } catch is CancellationError { throw CancellationError() }
            catch let e as MozzError where e == .cancelled { throw CancellationError() }
            catch { log("enrichment: tags \(artistMbid) failed: \(error)") }
        }
    }

    // MARK: - On-demand seed preparation (used by radio, B3)

    /// Ensure a seed track is resolved -> canonicalized -> its similar recordings
    /// fetched, and return its canonical recording MBID (for
    /// `EnrichmentStore.similarOwnedTracks`). `nil` when disabled or unresolvable.
    /// Shares the rate limiters with the background pass.
    public func prepareSeedSimilarity(trackRef: String, artistName: String, title: String,
                                      durationMs: Double?, artistMBID: String?) async -> String? {
        guard isEnabled() else { return nil }
        var recordingMbid: String?
        var canonical: String?
        if let state = try? await store.seedMbid(forTrackRef: trackRef) {
            recordingMbid = state.mbid
            canonical = state.canonical
        }
        if recordingMbid == nil {
            recordingMbid = await resolveSeed(trackRef: trackRef, artistName: artistName,
                                              title: title, durationMs: durationMs, artistMBID: artistMBID)
        }
        guard let mbid = recordingMbid else { return nil }
        if canonical == nil {
            // Mirror the background stage: a genuine no-mapping (nil) is stamped
            // (negative cache); a throw (transport/decode/cancel) is NOT stamped so
            // it's retried later. `try?` would collapse both into nil.
            do {
                let resolved = try await listenBrainz.canonicalRecording(forMbid: mbid)
                try? await store.setCanonical(mbid: mbid, canonical: resolved,
                                              at: now().timeIntervalSince1970)
                canonical = resolved
            } catch {
                return nil // couldn't canonicalize now; the background pass retries
            }
        }
        guard let canonicalMbid = canonical else { return nil }
        // Skip a redundant fetch if the background pass already did it recently.
        let cutoff = now().addingTimeInterval(-config.lookupTTL).timeIntervalSince1970
        if (try? await store.similarityIsFresh(canonicalMbid: canonicalMbid,
                                               algorithm: config.listenBrainzAlgorithm,
                                               notFetchedSince: cutoff)) == true {
            return canonicalMbid
        }
        do {
            let similar = try await listenBrainz.similarRecordings(forCanonicalMbid: canonicalMbid)
            try await store.replaceSimilarRecordings(
                sourceMbid: canonicalMbid, algorithm: config.listenBrainzAlgorithm,
                pairs: similar.map { ($0.recordingMBID, $0.score) },
                at: now().timeIntervalSince1970)
        } catch {
            log("enrichment: seed similar \(canonicalMbid) failed: \(error)")
        }
        return canonicalMbid
    }

    /// Resolve (and cache) the recording MBID for a single seed track on demand.
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
