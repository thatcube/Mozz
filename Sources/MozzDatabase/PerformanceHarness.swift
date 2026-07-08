import Foundation
import GRDB
import MozzCore
#if canImport(Darwin)
import Darwin
#endif

/// Reproducible performance measurements against the local store — the numbers
/// behind the performance bar (search latency, page fetch, cold-open, memory).
/// Lives in the database layer so it can run both as a host XCTest (regression
/// guard) and inside the app on the iOS simulator (real device-class numbers).
public struct PerformanceHarness: Sendable {
    public struct Metrics: Sendable, Codable {
        public var artistCount: Int
        public var albumCount: Int
        public var trackCount: Int
        public var generationSeconds: Double?
        public var coldOpenMs: Double?
        public var countQueryMs: Double
        public var pageFetchMs: Double
        public var searchP50Ms: Double
        public var searchP95Ms: Double
        public var searchMaxMs: Double
        public var searchIterations: Int
        public var residentMemoryMB: Double

        public var summary: String {
            func f(_ v: Double) -> String { String(format: "%.1f", v) }
            var lines = [
                "catalog: \(artistCount) artists · \(albumCount) albums · \(trackCount) tracks",
            ]
            if let g = generationSeconds { lines.append("generation: \(f(g))s") }
            if let c = coldOpenMs { lines.append("cold DB open + first count: \(f(c)) ms") }
            lines.append("count query: \(f(countQueryMs)) ms")
            lines.append("page fetch (100 rows): \(f(pageFetchMs)) ms")
            lines.append("search p50/p95/max: \(f(searchP50Ms)) / \(f(searchP95Ms)) / \(f(searchMaxMs)) ms (n=\(searchIterations))")
            lines.append("resident memory: \(f(residentMemoryMB)) MB")
            return lines.joined(separator: "\n")
        }
    }

    /// Representative terms that hit the synthetic catalog's FTS index across
    /// artists / albums / tracks (see ``SyntheticCatalog`` name pools).
    public static let defaultSearchTerms = [
        "Machine", "Golden", "Ocean", "Silent", "Burning", "Lena", "Vance",
        "Horizon", "Electric", "Signal", "Lunar", "Cathedral", "Ashford", "Neon", "Tide",
    ]

    private let database: MusicDatabase
    private let repository: LibraryRepository

    public init(_ database: MusicDatabase) {
        self.database = database
        self.repository = LibraryRepository(database)
    }

    /// Generate a catalog and return how long it took (seconds).
    @discardableResult
    public func generate(serverId: ServerID, size: SyntheticCatalog.Size) async throws -> Double {
        let start = Date()
        try await SyntheticCatalog(database).generate(serverId: serverId, size: size)
        return Date().timeIntervalSince(start)
    }

    /// Measure read-path metrics against an already-populated server.
    public func measureReads(
        serverId: ServerID,
        searchTerms: [String] = PerformanceHarness.defaultSearchTerms,
        iterations: Int = 3,
        generationSeconds: Double? = nil,
        coldOpenMs: Double? = nil
    ) async throws -> Metrics {
        let artistCount = try await repository.artistCount(serverId: serverId)
        let albumCount = try await repository.albumCount(serverId: serverId)

        let countStart = Date()
        let trackCount = try await repository.trackCount(serverId: serverId)
        let countQueryMs = Date().timeIntervalSince(countStart) * 1000

        let pageStart = Date()
        _ = try await repository.tracksPage(serverId: serverId, offset: trackCount / 2, limit: 100)
        let pageFetchMs = Date().timeIntervalSince(pageStart) * 1000

        var timings: [Double] = []
        for _ in 0..<max(1, iterations) {
            for term in searchTerms {
                let start = Date()
                _ = try await repository.search(term, serverId: serverId)
                timings.append(Date().timeIntervalSince(start) * 1000)
            }
        }
        timings.sort()

        return Metrics(
            artistCount: artistCount,
            albumCount: albumCount,
            trackCount: trackCount,
            generationSeconds: generationSeconds,
            coldOpenMs: coldOpenMs,
            countQueryMs: countQueryMs,
            pageFetchMs: pageFetchMs,
            searchP50Ms: percentile(timings, 0.50),
            searchP95Ms: percentile(timings, 0.95),
            searchMaxMs: timings.last ?? 0,
            searchIterations: timings.count,
            residentMemoryMB: Double(Self.residentMemoryBytes()) / 1_048_576.0
        )
    }

    /// Time the recommendation *candidate-generation* read — the taste-matched,
    /// not-recently-played library scan (`RecommendationStore.candidateTracks`),
    /// which uses `ORDER BY RANDOM() LIMIT` + a per-row `json_each` genre match.
    /// This is off the user's hot path (sets are precomputed off-main and the UI
    /// reads the stored result), but we measure it at scale so the known
    /// `ORDER BY RANDOM()` full-sort cost has a number and can't silently regress
    /// before the genre-normalized table replaces it. Uses catalog genres so the
    /// match actually returns rows.
    public func measureCandidateGenerationMs(
        serverId: ServerID,
        genres: [String] = ["Rock", "Jazz", "Electronic"],
        limit: Int = 2000,
        enrich: Bool = false
    ) async throws -> Double {
        let store = RecommendationStore(database)
        let queryGenres = enrich ? GenreNormalizer.keys(genres) : genres
        let notPlayedSince = Date().addingTimeInterval(-30 * 24 * 3600).timeIntervalSince1970
        let start = Date()
        _ = try await store.candidateTracks(serverId: serverId, genres: queryGenres, artistIds: [],
                                            notPlayedSince: notPlayedSince, limit: limit, enrich: enrich)
        return Date().timeIntervalSince(start) * 1000
    }

    /// Time the genre-corpus aggregate (`RecommendationStore.genreFrequencies`) —
    /// the TF-IDF IDF space rebuilt on a TTL. When `enrich`, this is the B4.5
    /// Swift-folded UNION of `track.genres` + `mb_tags` (the heavier path); measure
    /// it at scale with `mb_tags` populated so the fold cost has a number.
    public func measureGenreFrequenciesMs(serverId: ServerID, enrich: Bool = false) async throws -> Double {
        let store = RecommendationStore(database)
        let start = Date()
        _ = try await store.genreFrequencies(serverId: serverId, enrich: enrich)
        return Date().timeIntervalSince(start) * 1000
    }

    /// Populate `mb_tags` for a `fraction` of a server's tracks (multi-tag) so the
    /// enriched corpus/candidate timings reflect realistic `json_each` row
    /// expansion. Writes `track_features` rows directly (synthetic tracks carry no
    /// embedded MBIDs, so they have none otherwise). Returns the row count written.
    @discardableResult
    public func populateSyntheticMbTags(
        serverId: ServerID, fraction: Double = 0.9, tagsPerTrack: Int = 4
    ) async throws -> Int {
        let pool = ["electronic", "downtempo", "trip hop", "idm", "ambient", "synth pop",
                    "alternative rock", "indie rock", "shoegaze", "dream pop"]
        return try await database.write { db in
            let refs = try String.fetchAll(db, sql: """
                SELECT track.serverId || ':' || track.remoteId FROM track WHERE track.serverId = ?
                """, arguments: [serverId])
            let cutoff = Int(Double(refs.count) * max(0, min(1, fraction)))
            let now = Date().timeIntervalSince1970
            var written = 0
            for (i, ref) in refs.prefix(cutoff).enumerated() {
                let tags = (0..<tagsPerTrack).map { pool[(i + $0) % pool.count] }
                let json = String(data: try JSONEncoder().encode(tags), encoding: .utf8) ?? "[]"
                try db.execute(sql: """
                    INSERT INTO track_features (track_ref, mb_tags, mb_tags_lookup_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(track_ref) DO UPDATE SET mb_tags = excluded.mb_tags,
                        mb_tags_lookup_at = excluded.mb_tags_lookup_at, updated_at = excluded.updated_at
                    """, arguments: [ref, json, now, now])
                written += 1
            }
            return written
        }
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(sorted.count - 1, max(0, index))]
    }

    /// Current resident memory of the process, in bytes.
    public static func residentMemoryBytes() -> UInt64 {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
        #else
        return 0
        #endif
    }
}
