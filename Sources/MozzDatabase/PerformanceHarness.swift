import Foundation
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
