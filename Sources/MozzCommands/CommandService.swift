import Foundation
import MozzCore
import MozzDatabase
import MozzEnrichment

/// The one surface every shell reaches the core through.
///
/// This exists to remove an asymmetry, not to add a layer. Today the iOS shell
/// calls the core's modules directly while every other shell goes through
/// hand-written JSON commands, so a capability can be added, used on the phone,
/// and be invisible everywhere else because nobody widened the facade. Four of
/// seven parity defects in one recent week were exactly that.
///
/// With one protocol there is nowhere else to go. Swift shells call it in
/// process — no serialisation, no C, Swift calling Swift. Everything else goes
/// through `CommandDispatcher`, which speaks the same protocol over the wire
/// format in `schema/`. Neither path can reach a capability the other cannot,
/// because there is only the one set of methods.
///
/// The compile-time chain that keeps it honest runs backwards from the schema:
/// adding a command to `library.proto` adds a case to the generated `oneof`,
/// which breaks `CommandDispatcher`'s exhaustive switch, which forces a method
/// here, which forces the core to implement it. A capability with no command
/// stops the build rather than quietly shipping on one platform.
///
/// Note the deliberate coupling: the return types are the database's record
/// types rather than a third parallel set of models. Introducing one would mean
/// hand-writing and maintaining a mapping in both directions for no behaviour
/// change. If the record types later need to stop being the wire vocabulary,
/// that is a change to make on purpose rather than a layer to add in advance.
public protocol CommandService: Sendable {

    /// Every server the user has attached.
    func libraries() async throws -> [ServerConnection]

    /// One page of albums, in the library's own sort order.
    ///
    /// `after` is the cursor from the previous page, or `nil` to start. It is
    /// opaque: callers hand back what they were given and never construct one.
    func albums(
        serverId: ServerID,
        after: LibraryRepository.PageCursor?,
        limit: Int
    ) async throws -> LibraryRepository.Page<AlbumRecord>

    /// One page of artists, in the library's own sort order.
    ///
    /// Same cursor contract as `albums`: callers only echo the token they were
    /// given, and the repository owns the ordering details.
    func artists(
        serverId: ServerID,
        after: LibraryRepository.PageCursor?,
        limit: Int
    ) async throws -> LibraryRepository.Page<ArtistRecord>

    /// One page of tracks, in the library's own sort order.
    func tracks(
        serverId: ServerID,
        after: LibraryRepository.PageCursor?,
        limit: Int
    ) async throws -> LibraryRepository.Page<TrackRecord>

    /// One artist, or `nil` when the server has no such artist.
    ///
    /// Both arguments are required, which the schema now enforces at every call
    /// site. The hand-written facade checked at runtime and answered with a
    /// string — `guard let remoteId = request.remoteId, let serverId else …` —
    /// so a caller that forgot one learned about it from a failed response.
    func artist(serverId: ServerID, remoteId: String) async throws -> ArtistRecord?

    /// Albums by an artist, in the repository's detail-shelf order.
    func artistAlbums(serverId: ServerID, remoteId: String) async throws -> [AlbumRecord]

    /// Tracks of one album, resolving a representative album id to its group.
    func albumTracks(serverId: ServerID, remoteId: String) async throws -> [TrackRecord]

    /// Tracks of one consolidated album group.
    func albumTracks(serverId: ServerID, groupKey: String) async throws -> [TrackRecord]

    /// Library totals for one server.
    func counts(serverId: ServerID) async throws -> (artists: Int, albums: Int, tracks: Int)

    /// The current playback settings (EQ + loudness normalization), or the
    /// core's defaults when nothing has been stored yet. These are core, not
    /// shell, state — the sound is one definition, reached the same way from
    /// every platform, so it can sync and cannot drift.
    func playbackSettings() async throws -> PlaybackSettings

    /// Replace the playback settings, returning exactly what was stored after
    /// the core normalizes/clamps it — so the caller sees the effective result
    /// rather than assuming its input survived unchanged.
    @discardableResult
    func setPlaybackSettings(_ settings: PlaybackSettings) async throws -> PlaybackSettings

    /// The bytes of one cover, resolved against the attached backend and cached
    /// by the core. The three outcomes — present, absent, unavailable — are kept
    /// distinct on purpose; see ``ArtworkOutcome``. A shell decodes the returned
    /// bytes into whatever it draws and nothing more.
    func artwork(serverId: ServerID, artworkKey: String, size: Int) async -> ArtworkOutcome

    // MARK: Downloads
    //
    // The offline-download decision — what is queued, in flight, complete or
    // failed, and how far along — lives in the core's durable record. A shell
    // performs the byte transfer and the file write (its platform's job) and
    // reports each step back through these methods, so the one record reflects
    // reality on every platform rather than only on the Apple shell that used to
    // call MozzDownloads directly.
    //
    // Tracks are addressed by (serverId, remoteId) here, as everywhere else on
    // this surface; the core resolves that to the internal id the record is
    // keyed by. A mutation for a track the catalog has never seen fails; a
    // *status* query for one simply reports "not downloaded" (nil), because a
    // caller must be able to poll any track without first proving it exists.

    /// Record the intent to download a track and mark it queued. Idempotent:
    /// enqueuing an already-tracked download returns its current record.
    @discardableResult
    func enqueueDownload(serverId: ServerID, remoteId: String) async throws -> DownloadRecord

    /// Report transfer progress from the shell. The first report moves the
    /// download from queued to downloading; each updates the byte counters a
    /// status poll reads back.
    @discardableResult
    func reportDownloadProgress(
        serverId: ServerID, remoteId: String, receivedBytes: Int64, totalBytes: Int64?
    ) async throws -> DownloadRecord

    /// Record that the shell finished writing the file: where it landed
    /// (relative to the downloads root) and its final size. Marks the download
    /// complete — the core's single definition of "complete" for all platforms.
    @discardableResult
    func completeDownload(
        serverId: ServerID, remoteId: String, localPath: String, sizeBytes: Int64
    ) async throws -> DownloadRecord

    /// Record that the shell's transfer failed, with the reason.
    @discardableResult
    func failDownload(serverId: ServerID, remoteId: String, message: String) async throws -> DownloadRecord

    /// Cancel a queued or in-flight download. This mirrors DownloadManager's own
    /// `cancel`, which records a cancellation as a failure whose message is
    /// "Cancelled" — kept identical so behaviour does not fork by platform.
    @discardableResult
    func cancelDownload(serverId: ServerID, remoteId: String) async throws -> DownloadRecord

    /// Remove a download's record and return the file's former relative path so
    /// the shell can delete the bytes it owns. Idempotent: an unknown or
    /// never-downloaded track has nothing to remove and returns nil.
    @discardableResult
    func deleteDownload(serverId: ServerID, remoteId: String) async throws -> String?

    /// The current download record for one track, or nil when there is none —
    /// which is also the answer for a track the catalog does not know. Pollable:
    /// this is how a client watches progress, since the schema's push channel is
    /// not yet implemented.
    func downloadStatus(serverId: ServerID, remoteId: String) async throws -> DownloadRecord?

    /// Every download the core knows about, each carrying its track's identity,
    /// optionally narrowed to certain states (empty = all states).
    func downloads(in states: [DownloadState]) async throws -> [LibraryRepository.IdentifiedDownload]

    /// How much space completed downloads use, for a storage screen.
    func storageUsage() async throws -> StorageUsage

    // MARK: Enrichment
    //
    // The features that make Mozz more than a file browser — a track's lyrics,
    // its canonical MusicBrainz identity, and the owned tracks similar to it.
    // These lived only on the Apple shell because they had no command here; a
    // capability decided differently per platform makes one library look like
    // two. So they answer through this one surface like everything else.

    /// A track's lyrics, with the absent/not-fetched/failed distinction kept
    /// intact — the whole reason this returns ``LyricsAvailability`` and not a
    /// bare optional.
    ///
    /// - Parameters:
    ///   - resolve: `false` reads only the caches (fast, network-free, the ONLY
    ///     mode that can answer ``LyricsAvailability/notFetched``). `true` runs
    ///     the full server + LRCLIB resolution, which answers present / absent /
    ///     failed but never not-fetched.
    ///   - useOnlineLookup: the user's "look up lyrics online" preference;
    ///     consulted only when `resolve` is true.
    ///   - userInitiated: the user asked right now, so a resolve ignores the
    ///     bad-network backoff; consulted only when `resolve` is true.
    ///
    /// Throws ``EnrichmentCommandError/unknownTrack(serverId:remoteId:)`` when the
    /// catalog has no such track — lyrics are of a specific track, so an unknown
    /// one is an error, not an empty answer.
    func lyrics(
        serverId: ServerID, remoteId: String,
        resolve: Bool, useOnlineLookup: Bool, userInitiated: Bool
    ) async throws -> LyricsAvailability

    /// A track's canonical MusicBrainz recording identity as already resolved into
    /// the local database. A pure read — never itself a network lookup. A track
    /// the catalog has never seen simply reports ``RecordingIdentity/notResolved``
    /// (like a status poll), so any track can be queried without proving it first.
    func recordingIdentity(serverId: ServerID, remoteId: String) async throws -> RecordingIdentity

    /// The owned library tracks similar to a seed track, most similar first, each
    /// with its aggregate score. Empty when the seed has no canonical MBID yet
    /// (similarity is keyed by it) or no similarity data has been fetched — the
    /// same network-free DB read the Apple radio tier makes.
    func similarTracks(serverId: ServerID, remoteId: String, limit: Int) async throws -> [ScoredTrack]
}

/// The outcome of a lyrics command. The three non-present cases are distinct on
/// purpose: collapsing them is the exact bug where a panel shows nothing and
/// never retries.
public enum LyricsAvailability: Sendable, Equatable {
    /// Lyrics exist and are attached.
    case present(Lyrics)
    /// A source was consulted (or the title is explicitly instrumental) and there
    /// are authoritatively none. Stop asking.
    case absent
    /// Nothing has been looked up yet — a cache-only read found no entry. Ask
    /// again with `resolve: true`; do NOT read this as "no lyrics".
    case notFetched
    /// A resolve was attempted but no source could be trusted (offline, throttled,
    /// a needed source unreachable). The negative is not authoritative; retry.
    case failed
}

/// A track's MusicBrainz recording identity. There is deliberately no `failed`:
/// the store persists only a definitive found/notfound, so a transient
/// resolution error leaves no trace and reads as ``notResolved`` — honest to the
/// data rather than a state the store cannot support.
public enum RecordingIdentity: Sendable, Equatable {
    /// A recording MBID is known (embedded tag or name-search hit). `canonical`
    /// is the representative of the same-recording set, absent until
    /// canonicalization runs. `artist` is the artist MBID when known.
    case resolved(recordingMbid: String, canonical: String?, artist: String?)
    /// A lookup ran and MusicBrainz has no match — the authoritative negative.
    case unmatched
    /// Not looked up yet, or a transient failure the store does not record.
    case notResolved
}

/// One owned track surfaced as similar to a seed, with its aggregate similarity
/// score. Carries the full record so a shell renders and plays it without a
/// second fetch.
public struct ScoredTrack: Sendable {
    public let track: TrackRecord
    public let score: Double

    public init(track: TrackRecord, score: Double) {
        self.track = track
        self.score = score
    }
}

/// Why an enrichment command could not be carried out. Surfaced to a shell as a
/// `Failure` (the dispatcher turns a thrown error into one).
public enum EnrichmentCommandError: Error, CustomStringConvertible {
    /// No track with this (server, remote) identity exists in the catalog.
    case unknownTrack(serverId: ServerID, remoteId: String)

    public var description: String {
        switch self {
        case .unknownTrack(let serverId, let remoteId):
            return "no track \(remoteId) on server \(serverId)"
        }
    }
}

/// Why a download command could not be carried out. Surfaced to a shell as a
/// `Failure` (the dispatcher turns a thrown error into one) rather than a crash.
public enum DownloadCommandError: Error, CustomStringConvertible {
    /// No track with this (server, remote) identity exists in the catalog, so
    /// there is nothing to download.
    case unknownTrack(serverId: ServerID, remoteId: String)

    public var description: String {
        switch self {
        case .unknownTrack(let serverId, let remoteId):
            return "no track \(remoteId) on server \(serverId) to download"
        }
    }
}

/// The core's implementation, over the source-of-truth database.
///
/// Thin on purpose. Anything that looks like a decision — a default page size, a
/// sort order, a fallback — belongs below this, in the repository, so that a
/// shell cannot get a different answer by asking differently.
public struct LibraryCommandService: CommandService {
    private let repository: LibraryRepository
    private let playbackSettingsStore: PlaybackSettingsStore
    private let downloadStore: DownloadStore
    private let artworkStore: ArtworkStore?
    private let lyricsService: LyricsService?
    private let enrichmentStore: EnrichmentStore?
    private let backendResolver: @Sendable (ServerID) -> (any MusicBackend)?
    private let similarityAlgorithm: String

    public init(
        repository: LibraryRepository,
        playbackSettings: PlaybackSettingsStore,
        downloads: DownloadStore,
        artwork: ArtworkStore? = nil,
        lyricsService: LyricsService? = nil,
        enrichmentStore: EnrichmentStore? = nil,
        backendResolver: @escaping @Sendable (ServerID) -> (any MusicBackend)? = { _ in nil },
        similarityAlgorithm: String = EnrichmentConfig.defaultListenBrainzAlgorithm
    ) {
        self.repository = repository
        self.playbackSettingsStore = playbackSettings
        self.downloadStore = downloads
        self.artworkStore = artwork
        self.lyricsService = lyricsService
        self.enrichmentStore = enrichmentStore
        self.backendResolver = backendResolver
        self.similarityAlgorithm = similarityAlgorithm
    }

    public func libraries() async throws -> [ServerConnection] {
        try await repository.servers()
    }

    public func albums(
        serverId: ServerID,
        after: LibraryRepository.PageCursor?,
        limit: Int
    ) async throws -> LibraryRepository.Page<AlbumRecord> {
        try await repository.albumsPage(serverId: serverId, after: after, limit: limit)
    }

    public func artists(
        serverId: ServerID,
        after: LibraryRepository.PageCursor?,
        limit: Int
    ) async throws -> LibraryRepository.Page<ArtistRecord> {
        try await repository.artistsPage(serverId: serverId, after: after, limit: limit)
    }

    public func tracks(
        serverId: ServerID,
        after: LibraryRepository.PageCursor?,
        limit: Int
    ) async throws -> LibraryRepository.Page<TrackRecord> {
        try await repository.tracksPage(serverId: serverId, after: after, limit: limit)
    }

    public func artist(serverId: ServerID, remoteId: String) async throws -> ArtistRecord? {
        try await repository.artist(serverId: serverId, remoteId: remoteId)
    }

    public func artistAlbums(serverId: ServerID, remoteId: String) async throws -> [AlbumRecord] {
        try await repository.albums(forArtistRemoteId: remoteId, serverId: serverId)
    }

    public func albumTracks(serverId: ServerID, remoteId: String) async throws -> [TrackRecord] {
        try await repository.tracks(forAlbumGroupContaining: remoteId, serverId: serverId)
    }

    public func albumTracks(serverId: ServerID, groupKey: String) async throws -> [TrackRecord] {
        try await repository.tracks(forAlbumGroupKey: groupKey, serverId: serverId)
    }

    public func counts(serverId: ServerID) async throws -> (artists: Int, albums: Int, tracks: Int) {
        (
            artists: try await repository.artistCount(serverId: serverId),
            albums: try await repository.albumCount(serverId: serverId),
            tracks: try await repository.trackCount(serverId: serverId)
        )
    }

    public func playbackSettings() async throws -> PlaybackSettings {
        try await playbackSettingsStore.load()
    }

    @discardableResult
    public func setPlaybackSettings(_ settings: PlaybackSettings) async throws -> PlaybackSettings {
        try await playbackSettingsStore.save(settings)
    }

    public func artwork(serverId: ServerID, artworkKey: String, size: Int) async -> ArtworkOutcome {
        // No store wired in means no way to fetch or cache — report the honest
        // transient answer rather than inventing an absence the caller would
        // remember. In the app the store is always present; only bare test and
        // JSON constructors leave it nil.
        guard let artworkStore else { return .unavailable }
        let query = ArtworkQuery(
            serverId: serverId, artworkKey: artworkKey, size: size)
        return await artworkStore.artwork(query)
    }

    // MARK: Downloads

    @discardableResult
    public func enqueueDownload(serverId: ServerID, remoteId: String) async throws -> DownloadRecord {
        let trackId = try await resolveTrackId(serverId: serverId, remoteId: remoteId)
        return try await downloadStore.enqueue(trackId: trackId)
    }

    @discardableResult
    public func reportDownloadProgress(
        serverId: ServerID, remoteId: String, receivedBytes: Int64, totalBytes: Int64?
    ) async throws -> DownloadRecord {
        let trackId = try await resolveTrackId(serverId: serverId, remoteId: remoteId)
        // The first byte report is what turns a queued download into an active
        // one, matching DownloadManager, which marks downloading as the transfer
        // begins. A record that is already downloaded is left as-is: a late,
        // stray progress report must not un-complete a finished download.
        let current = try await repository.download(trackId: trackId)?.downloadState
        if current != .downloading && current != .downloaded {
            try await downloadStore.markDownloading(trackId: trackId, totalBytes: totalBytes)
        }
        try await downloadStore.updateProgress(
            trackId: trackId, receivedBytes: receivedBytes, totalBytes: totalBytes)
        return try await requireRecord(trackId: trackId)
    }

    @discardableResult
    public func completeDownload(
        serverId: ServerID, remoteId: String, localPath: String, sizeBytes: Int64
    ) async throws -> DownloadRecord {
        let trackId = try await resolveTrackId(serverId: serverId, remoteId: remoteId)
        try await downloadStore.markDownloaded(
            trackId: trackId, localPath: localPath, sizeBytes: sizeBytes)
        return try await requireRecord(trackId: trackId)
    }

    @discardableResult
    public func failDownload(
        serverId: ServerID, remoteId: String, message: String
    ) async throws -> DownloadRecord {
        let trackId = try await resolveTrackId(serverId: serverId, remoteId: remoteId)
        try await downloadStore.markFailed(trackId: trackId, error: message)
        return try await requireRecord(trackId: trackId)
    }

    @discardableResult
    public func cancelDownload(serverId: ServerID, remoteId: String) async throws -> DownloadRecord {
        let trackId = try await resolveTrackId(serverId: serverId, remoteId: remoteId)
        // Identical to DownloadManager.cancel: a cancellation is recorded as a
        // failure whose message is exactly "Cancelled", so the two entry points
        // cannot disagree on what a cancelled download looks like.
        try await downloadStore.markFailed(trackId: trackId, error: "Cancelled")
        return try await requireRecord(trackId: trackId)
    }

    @discardableResult
    public func deleteDownload(serverId: ServerID, remoteId: String) async throws -> String? {
        // Deleting is idempotent and never fails on a missing target: an unknown
        // track, or a known track with no record, has nothing to remove, so this
        // reports "removed nothing" (nil) rather than an error. The returned path
        // is what the shell deletes from disk; the core only drops the record.
        guard let trackId = try await trackId(serverId: serverId, remoteId: remoteId) else {
            return nil
        }
        let formerPath = try await repository.download(trackId: trackId)?.localPath
        try await downloadStore.remove(trackId: trackId)
        return formerPath
    }

    public func downloadStatus(serverId: ServerID, remoteId: String) async throws -> DownloadRecord? {
        // A status query for a track the catalog does not know is not an error —
        // it is simply "not downloaded" (nil), so a client can poll any track's
        // status without first proving the track exists.
        guard let trackId = try await trackId(serverId: serverId, remoteId: remoteId) else {
            return nil
        }
        return try await repository.download(trackId: trackId)
    }

    public func downloads(
        in states: [DownloadState]
    ) async throws -> [LibraryRepository.IdentifiedDownload] {
        try await repository.identifiedDownloads(in: states)
    }

    public func storageUsage() async throws -> StorageUsage {
        try await repository.storageUsage()
    }

    // MARK: Enrichment

    public func lyrics(
        serverId: ServerID, remoteId: String,
        resolve: Bool, useOnlineLookup: Bool, userInitiated: Bool
    ) async throws -> LyricsAvailability {
        // Lyrics are of a specific track; an unknown one is an error, not an
        // empty answer (the legacy JSON handler failed here too).
        guard let record = try await repository.track(serverId: serverId, remoteId: remoteId) else {
            throw EnrichmentCommandError.unknownTrack(serverId: serverId, remoteId: remoteId)
        }
        // Without a lyrics engine wired in there is nothing to read or fetch —
        // report the honest transient answer (matches the artwork nil-store rule),
        // never a fabricated absence a caller would stop retrying.
        guard let lyricsService else { return .failed }
        let track = record.toDomain()
        let backend = backendResolver(serverId)

        if !resolve {
            // Cache-only: the ONLY mode that can distinguish "asked and none"
            // (a persisted negative) from "nobody has asked yet".
            switch await lyricsService.cached(track: track, backend: backend) {
            case .hit(let cached):
                if let lyrics = cached, !lyrics.isEmpty { return .present(lyrics) }
                return .absent
            case .miss:
                return .notFetched
            }
        }

        let resolution = await lyricsService.resolve(
            track: track, backend: backend, context: .visible,
            useLRCLIB: useOnlineLookup, userInitiated: userInitiated)
        if let lyrics = resolution.lyrics, !lyrics.isEmpty { return .present(lyrics) }
        // A nil resolve is either an authoritative absence or a transient failure.
        // `resolution.staySilent` alone cannot tell them apart — a cached
        // authoritative negative also stays silent. But `resolve` persists ONLY
        // authoritative negatives, so a follow-up cache read recovers the truth:
        // a hit means it was persisted (authoritative → absent); a miss means it
        // was not (transient → failed, retry).
        switch await lyricsService.cached(track: track, backend: backend) {
        case .hit: return .absent
        case .miss: return .failed
        }
    }

    public func recordingIdentity(serverId: ServerID, remoteId: String) async throws -> RecordingIdentity {
        guard let enrichmentStore else { return .notResolved }
        let ref = PlayEventStore.trackRef(serverId: serverId, remoteId: remoteId)
        guard let state = try await enrichmentStore.mbidState(trackRef: ref) else {
            return .notResolved
        }
        // A non-nil mbid means status 'embedded' or 'found' — checking the mbid
        // itself (not the status string) covers both without enumerating them.
        if let recordingMbid = state.mbid {
            let canonical = try await enrichmentStore.seedMbid(forTrackRef: ref)?.canonical
            return .resolved(
                recordingMbid: recordingMbid, canonical: canonical, artist: state.artistMbid)
        }
        if state.lookupStatus == "notfound" { return .unmatched }
        return .notResolved
    }

    public func similarTracks(serverId: ServerID, remoteId: String, limit: Int) async throws -> [ScoredTrack] {
        guard let enrichmentStore else { return [] }
        let ref = PlayEventStore.trackRef(serverId: serverId, remoteId: remoteId)
        // Similarity rows are keyed by the seed's CANONICAL MBID (matching the
        // Apple radio tier). No canonical yet → no similar set, an empty answer
        // rather than an error, exactly like the app.
        guard let canonical = try await enrichmentStore.seedMbid(forTrackRef: ref)?.canonical else {
            return []
        }
        let scored = try await enrichmentStore.similarOwnedTracks(
            seedCanonicalMbids: [canonical], algorithm: similarityAlgorithm,
            serverId: serverId, excludingRemoteIds: [remoteId], limit: limit)
        // similarOwnedTracks yields ranked remote ids; hydrate them into full
        // records preserving that order, then re-attach the score per remote id.
        let orderedRemoteIds = scored.map(\.candidate.remoteId)
        let scoreByRemoteId = Dictionary(
            scored.map { ($0.candidate.remoteId, $0.score) }, uniquingKeysWith: { first, _ in first })
        let records = try await repository.tracks(forRemoteIds: orderedRemoteIds, serverId: serverId)
        return records.map { ScoredTrack(track: $0, score: scoreByRemoteId[$0.remoteId] ?? 0) }
    }

    // MARK: Download helpers

    /// The internal id of the track with this identity, or nil when the catalog
    /// has no such track.
    private func trackId(serverId: ServerID, remoteId: String) async throws -> Int64? {
        try await repository.track(serverId: serverId, remoteId: remoteId)?.id
    }

    /// The internal id of the track, failing when it does not exist. Used by the
    /// mutating commands, where acting on a track the catalog never saw is a real
    /// error rather than a benign no-op.
    private func resolveTrackId(serverId: ServerID, remoteId: String) async throws -> Int64 {
        guard let id = try await trackId(serverId: serverId, remoteId: remoteId) else {
            throw DownloadCommandError.unknownTrack(serverId: serverId, remoteId: remoteId)
        }
        return id
    }

    /// The download record after a write. The write helpers upsert, so the
    /// record always exists here; the force is a guard against a logic error, not
    /// an expected path.
    private func requireRecord(trackId: Int64) async throws -> DownloadRecord {
        guard let record = try await repository.download(trackId: trackId) else {
            throw DownloadCommandError.unknownTrack(serverId: "", remoteId: "\(trackId)")
        }
        return record
    }
}
