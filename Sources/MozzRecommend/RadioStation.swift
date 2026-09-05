import Foundation
import MozzCore
import MozzDatabase

/// An endless station: a seed, the tracks it has already surfaced, and the
/// tiered logic that decides what plays next.
///
/// This used to live in the iOS app's `AppEnvironment`, which meant the answer
/// to "what does radio play after this?" existed on exactly one platform. The
/// desktop had no station at all and Android could not have had one without a
/// third implementation of the same three tiers. Since the tiers are the
/// product — the acoustic neighbours first, the crowd signal second, genre as a
/// floor — a shell reimplementing them is a shell that quietly plays something
/// else.
///
/// What stays in the shell is what genuinely differs: how a queue is filled
/// (AVQueuePlayer, Media3, the Facade's own engine), and when it is safe to
/// replace what is playing. This type never touches playback; it answers with
/// remote ids and lets the caller decide what to do with them.
///
/// An actor rather than a class with locks because the interesting bug here is
/// two stations racing: a tap on one song while an earlier tap is still
/// fetching. Serializing the state is most of that problem solved, and the
/// generation counter below is the rest.
public actor RadioStation {

    /// Everything the station needs that ``RecommendationService`` cannot reach
    /// on its own — a server's own analysis, ListenBrainz, and the name of
    /// whichever engine analyzed this device's library.
    ///
    /// Closures rather than a protocol because the three callers supply them
    /// from three different layers: the iOS app has all of it, the Facade has
    /// the backend but no enrichment, and a test has none. A protocol would
    /// make each of those declare conformances for capabilities it does not
    /// have; ``RadioSources/none`` is the honest default and every field
    /// degrades to "this tier contributes nothing".
    public struct Sources: Sendable {
        /// The server's own acoustic analysis of its library, when it has one.
        public var serverSonicMatches: @Sendable (
            _ seedRemoteId: String, _ serverId: ServerID, _ limit: Int
        ) async -> [SonicMatch]

        /// ListenBrainz-similar tracks this library owns. Empty when enrichment
        /// is off, the seed has no resolved MBID, or the seed is an artist.
        public var collaborativeMatches: @Sendable (
            _ seed: RadioSeed, _ serverId: ServerID,
            _ excluding: Set<String>, _ limit: Int
        ) async -> [ScoredOwnedTrack]

        /// Warm the seed's similarity data before the first batch is built.
        /// Fire-and-forget: a station starts whether or not this finishes, and
        /// what it fetches lands in the batch after next at worst.
        public var prepareSeed: @Sendable (_ seed: RadioSeed) async -> Void

        /// Which analysis engine's vectors to search. Searching the other one
        /// finds nothing at all, and finds it silently.
        ///
        /// `nil` — the default — means "ask the database which engine actually
        /// wrote vectors for this library", which is the right answer for every
        /// caller that is not itself running the analyzer. A shell that IS
        /// running it should name its own engine, so a station and a pass in
        /// progress agree during the window where both engines have rows.
        public var sonicEngine: @Sendable () -> String?

        public init(
            serverSonicMatches: @escaping @Sendable (String, ServerID, Int) async -> [SonicMatch] = { _, _, _ in [] },
            collaborativeMatches: @escaping @Sendable (RadioSeed, ServerID, Set<String>, Int) async -> [ScoredOwnedTrack] = { _, _, _, _ in [] },
            prepareSeed: @escaping @Sendable (RadioSeed) async -> Void = { _ in },
            sonicEngine: @escaping @Sendable () -> String? = { nil }
        ) {
            self.serverSonicMatches = serverSonicMatches
            self.collaborativeMatches = collaborativeMatches
            self.prepareSeed = prepareSeed
            self.sonicEngine = sonicEngine
        }

        /// No server analysis, no enrichment: the station runs on this device's
        /// own vectors and the genre floor. What the Facade gets today.
        public static var none: Sources { Sources() }
    }

    /// What a station is currently playing from, for a shell that needs to show
    /// it ("Radio · Kate Bush") or decide whether to offer a stop control.
    public struct State: Sendable, Equatable {
        public var seed: RadioSeed
        public var serverId: ServerID
        /// How many tracks this station has handed out since it started.
        public var surfaced: Int
    }

    private let recommendations: RecommendationService
    private let sources: Sources

    private var seed: RadioSeed?
    private var serverId: ServerID?
    /// Remote ids already handed out, so successive batches don't repeat.
    private var seen: Set<String> = []
    /// Bumped by every `start`, `adopt` and `stop`. A batch fetched for an
    /// older generation is dropped rather than mixed into the current station:
    /// the alternative is a slow first tap poisoning the seen-set of the
    /// station the second tap actually installed.
    private var generation = 0

    public init(recommendations: RecommendationService, sources: Sources = .none) {
        self.recommendations = recommendations
        self.sources = sources
    }

    /// The running station, or `nil` when nothing is playing from one.
    public var state: State? {
        guard let seed, let serverId else { return nil }
        return State(seed: seed, serverId: serverId, surfaced: seen.count)
    }

    // MARK: Starting

    /// Start a station from a track: its own acoustic neighbours first, then
    /// the crowd, then its genres.
    ///
    /// The seed track is excluded from the batch rather than included in it.
    /// A shell that wants "start radio from this song" plays the song and then
    /// this batch; one that wants "play something like this song" plays only
    /// the batch. Deciding that here would have taken the choice away from the
    /// second caller.
    public func start(
        fromTrack track: RadioTrackSeed, serverId: ServerID, limit: Int = 30
    ) async -> [String] {
        let seed = RadioSeed(
            title: track.title, genres: track.genres,
            artistIds: [track.artistId].compactMap { $0 },
            seedTrackRef: "\(serverId):\(track.remoteId)")
        return await start(
            seed: seed, serverId: serverId, excluding: [track.remoteId], limit: limit)
    }

    /// Start a station from an artist.
    ///
    /// `name` and `genres` are only a fallback. The seed is derived from the
    /// artist's own tracks, because that is the vocabulary the candidate pool
    /// is scored in - where the library has been enriched those genres are the
    /// canonical, `mb_tags`-merged ones, and seeding with the raw tags instead
    /// compares two different vocabularies. It also means a station can start
    /// from an artist the catalog has tracks for but no `artist` row.
    public func start(
        fromArtist artistId: String, serverId: ServerID,
        name: String? = nil, genres: [String] = [], limit: Int = 30
    ) async -> [String] {
        let derived = await recommendations.artistSeed(artistId: artistId, serverId: serverId)
        let seed = RadioSeed(
            title: derived?.name.nilIfEmpty ?? name ?? artistId,
            genres: derived?.genres.isEmpty == false ? derived!.genres : genres,
            artistIds: [artistId])
        return await start(seed: seed, serverId: serverId, limit: limit)
    }

    /// Start a station from a seed the caller built itself.
    ///
    /// Returns `[]` when a newer start superseded this one while it fetched, or
    /// when no tier had anything to give. Both mean the same thing to a caller:
    /// do not disturb what is playing.
    @discardableResult
    public func start(
        seed: RadioSeed, serverId: ServerID,
        excluding: Set<String> = [], limit: Int = 30
    ) async -> [String] {
        generation += 1
        let mine = generation

        // Warmed in parallel with the first batch rather than before it. The
        // similarity fetch is a network round trip and a station that waited
        // for it would take seconds to make a sound; what it warms is read
        // again on every later batch anyway.
        let prepare = Task { [sources] in await sources.prepareSeed(seed) }
        defer { _ = prepare }

        let ids = await batch(
            seed: seed, serverId: serverId, excluding: excluding, limit: limit)

        // Superseded while fetching: a newer tap owns the station now, and
        // installing this one would replace what the user just chose.
        guard mine == generation, !ids.isEmpty else { return [] }

        self.seed = seed
        self.serverId = serverId
        self.seen = excluding.union(ids)
        return ids
    }

    /// Adopt what is already playing as a station's seed, without producing a
    /// batch or disturbing the queue.
    ///
    /// Siri is asked for one specific song far more often than the app's own UI
    /// is — "play <song> on Mozz" — and on a speaker in another room a queue
    /// that falls silent after three minutes is a poor answer. The song is
    /// already playing; the station simply forms behind it.
    public func adopt(seed: RadioSeed, serverId: ServerID, playing remoteId: String?) {
        generation += 1
        self.seed = seed
        self.serverId = serverId
        self.seen = Set([remoteId].compactMap { $0 })
        Task { [sources] in await sources.prepareSeed(seed) }
    }

    // MARK: Continuing

    /// The next batch, excluding everything this station has already surfaced.
    ///
    /// Returns `[]` when no station is running or when one was started or
    /// stopped while this was fetching. A shell calls this as its queue runs
    /// low and simply appends whatever comes back.
    public func next(limit: Int = 20) async -> [String] {
        guard let seed, let serverId else { return [] }
        let mine = generation
        let ids = await batch(
            seed: seed, serverId: serverId, excluding: seen, limit: limit)
        guard mine == generation else { return [] }
        seen.formUnion(ids)
        return ids
    }

    /// Forget the running station — on sign-out, on a server switch, or when
    /// the user plays something directly.
    ///
    /// Bumping the generation matters as much as clearing the seed: a fetch
    /// already in flight would otherwise land afterwards and resurrect it.
    public func stop() {
        generation += 1
        seed = nil
        serverId = nil
        seen = []
    }

    // MARK: The tiers

    /// Gather each tier's candidates and let ``RecommendationService/radioBatch``
    /// blend them. The order and the per-artist caps live there; this decides
    /// only what each tier is allowed to see.
    ///
    /// Public because one batch is also useful without a station behind it: a
    /// caller that keeps its own seed and its own seen-set — the Facade's
    /// stateless `radioBatch` command, and any shell that would rather own that
    /// state — gets the same three tiers without reimplementing them, which is
    /// the entire point of this type.
    public func batch(
        seed: RadioSeed, serverId: ServerID, excluding: Set<String> = [], limit: Int = 20
    ) async -> [String] {
        async let sonic = sonicCandidates(for: seed, serverId: serverId, limit: limit)
        async let similar = sources.collaborativeMatches(
            seed, serverId, excluding, collaborativePool(for: limit))

        let ids = try? await recommendations.radioBatch(
            seed: seed, serverId: serverId, limit: limit, excluding: excluding,
            sonic: await sonic, similar: await similar)
        return ids ?? []
    }

    /// The seed's acoustically-similar owned tracks — the server's own analysis
    /// where it has one, and otherwise what this device heard for itself.
    ///
    /// Overfetched by 3× for the same reason the collaborative tier is: the
    /// blender's per-artist cap throws away an analyzer's album-mates, which
    /// are most of what a nearest-neighbour search returns, so a pool trimmed
    /// to `limit` first arrives short.
    private func sonicCandidates(
        for seed: RadioSeed, serverId: ServerID, limit: Int
    ) async -> [ScoredOwnedTrack] {
        guard let ref = seed.seedTrackRef else { return [] }
        let prefix = "\(serverId):"
        let remoteId = ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref

        var matches = await sources.serverSonicMatches(remoteId, serverId, limit * 3)
        if matches.isEmpty {
            // Nothing analyzed it for us, which is the ordinary case.
            var named = sources.sonicEngine()
            if named == nil {
                named = await recommendations.analyzedEngine(serverId: serverId)
            }
            guard let engine = named else { return [] }
            matches = (try? await recommendations.localSonicMatches(
                seedRemoteId: remoteId, serverId: serverId,
                engine: engine, limit: limit * 3)) ?? []
        }
        guard !matches.isEmpty else { return [] }
        return (try? await recommendations.ownedSonicTracks(matches, serverId: serverId)) ?? []
    }

    /// How wide a collaborative pool to ask for. The tier's per-artist cap
    /// discards artist-heavy excess, so asking for exactly `limit` underfills
    /// and hands the slots to genre; the ceiling keeps a big library from
    /// paying for a pool the blender will never look at.
    private func collaborativePool(for limit: Int) -> Int {
        min(max(limit * 5, 50), 250)
    }
}

/// The parts of a track a station needs to seed from one, so a caller does not
/// have to hold a whole `Track` (the Facade's shells hold wire rows, not
/// models).
public struct RadioTrackSeed: Sendable, Equatable {
    public var remoteId: String
    public var title: String
    public var genres: [String]
    public var artistId: String?

    public init(remoteId: String, title: String, genres: [String] = [], artistId: String? = nil) {
        self.remoteId = remoteId
        self.title = title
        self.genres = genres
        self.artistId = artistId
    }
}

private extension String {
    /// An empty name is not a name: a station labelled "" reads as a bug.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
