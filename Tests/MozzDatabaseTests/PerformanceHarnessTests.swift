import XCTest
import MozzCore
@testable import MozzDatabase

/// Performance-bar guards. The lighter case always runs and asserts the
/// sub-100ms search target; the full 100k-track case is gated behind
/// `MOZZ_RUN_PERF=1` (it is heavier) and prints the numbers reported in
/// ARCHITECTURE.md.
final class PerformanceHarnessTests: XCTestCase {
    /// A hi-res library (24-bit lossless, 150–400 MB/track) must account
    /// correctly at multi-terabyte scale: `storageUsage()` sums an `Int64` byte
    /// column, so this proves no overflow, exact totals, and TB-scale human
    /// formatting — the concern behind "will this scale to huge FLAC libraries?".
    /// Pure metadata: not one audio byte is written.
    func testStorageAccountingScalesToMultipleTerabytes() async throws {
        let db = try MusicDatabase.inMemory()
        let serverId = "hires"
        // ~90% hi-res 24-bit → a realistically huge audiophile library.
        try await SyntheticCatalog(db).generate(
            serverId: serverId,
            size: .init(artists: 300, albums: 1_500, tracks: 15_000, hiResFraction: 0.9)
        )

        // Mark the entire library downloaded in one statement, recording each
        // track's real (synthetic) byte size — no files, just the accounting rows.
        try await db.write { database in
            try database.execute(sql: """
                INSERT INTO download (trackId, state, sizeBytes, requestedAt, completedAt)
                SELECT id, 'downloaded', COALESCE(fileSizeBytes, 0), 0, 0
                FROM track WHERE serverId = ?
                """, arguments: [serverId])
        }

        let repo = LibraryRepository(db)
        let usage = try await repo.storageUsage()
        XCTAssertEqual(usage.downloadedTrackCount, 15_000)

        // Exact: the download SUM must equal the catalog's own byte sum.
        let catalogBytes = try await db.read { database in
            try Int64.fetchOne(database, sql: "SELECT COALESCE(SUM(fileSizeBytes),0) FROM track WHERE serverId = ?",
                               arguments: [serverId]) ?? 0
        }
        XCTAssertEqual(usage.totalBytes, catalogBytes)

        // Multi-terabyte, and Int64-safe (a wrap would go negative).
        let tb = Double(usage.totalBytes) / 1_000_000_000_000
        XCTAssertGreaterThan(usage.totalBytes, 1_000_000_000_000, "hi-res library should exceed 1 TB")
        XCTAssertGreaterThan(usage.totalBytes, 0, "Int64 byte total must not overflow to negative")

        // Human formatting renders terabytes (what the storage UI shows).
        let formatted = ByteCountFormatter.string(fromByteCount: usage.totalBytes, countStyle: .file)
        XCTAssertTrue(formatted.contains("TB"), "expected a TB-scale label, got \(formatted)")

        print(String(format: "[PERF hi-res] 15k tracks @ 90%% hi-res → %.2f TB (%@)", tb, formatted))
    }

    func testSearchLatencyBarAt20k() async throws {
        let db = try MusicDatabase.inMemory()
        let harness = PerformanceHarness(db)
        let serverId = "perf"
        // ~7% fragmentation so GROUP BY albumGroupKey does real consolidation work
        // (unique titles would collapse nothing and hide the grouping cost).
        let gen = try await harness.generate(
            serverId: serverId,
            size: .init(artists: 400, albums: 2_000, tracks: 20_000, fragmentation: 0.07)
        )
        let metrics = try await harness.measureReads(serverId: serverId, generationSeconds: gen)

        XCTAssertEqual(metrics.trackCount, 20_000)
        // The sub-100ms search bar must hold even off a warm in-memory DB.
        XCTAssertLessThan(metrics.searchP95Ms, 100, "search p95 exceeded 100ms bar: \(metrics.searchP95Ms)")
        // A single page must be effectively instant regardless of catalog size.
        XCTAssertLessThan(metrics.pageFetchMs, 50, "page fetch too slow: \(metrics.pageFetchMs)")

        let repo = LibraryRepository(db)
        // Confirm the fragmentation actually consolidated (else the perf below is
        // meaningless): distinct groups must be fewer than raw album rows.
        let rawAlbums = try await repo.albumCount(serverId: serverId)
        let allGroups = try await repo.albumsPage(serverId: serverId, offset: 0, limit: rawAlbums)
        XCTAssertEqual(rawAlbums, 2_000)
        XCTAssertLessThan(allGroups.count, rawAlbums, "fragmentation didn't consolidate anything")

        // The album page GROUPs BY + ORDERs BY albumGroupKey (index-driven, early
        // terminating). A deep page must stay fast — the guard against a
        // materialize-all-groups-then-sort regression.
        let albumPageStart = Date()
        _ = try await repo.albumsPage(serverId: serverId, offset: 1_000, limit: 100)
        let albumPageMs = Date().timeIntervalSince(albumPageStart) * 1000
        XCTAssertLessThan(albumPageMs, 60, "grouped album page too slow: \(albumPageMs)")

        print("[PERF 20k] albums \(rawAlbums)→\(allGroups.count) groups, page \(String(format: "%.1f", albumPageMs))ms\n\(metrics.summary)")
    }

    func testFullScale100kPerf() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MOZZ_RUN_PERF"] == "1",
            "Set MOZZ_RUN_PERF=1 to run the full 100k-track benchmark."
        )
        // Measure against an on-disk DB (matches the shipping app) including a
        // cold reopen so the numbers reflect real cold-launch DB readiness.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mozz-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("perf.sqlite")

        let serverId = "perf"
        var generationSeconds: Double = 0
        do {
            let db = try MusicDatabase.open(at: url)
            generationSeconds = try await PerformanceHarness(db).generate(serverId: serverId, size: .large)
        }

        // Cold reopen + first count query (proxy for cold-launch DB readiness).
        let coldStart = Date()
        let reopened = try MusicDatabase.open(at: url)
        _ = try await LibraryRepository(reopened).trackCount(serverId: serverId)
        let coldOpenMs = Date().timeIntervalSince(coldStart) * 1000

        // Local footprint of a 100k-track library with NOTHING downloaded: just
        // the catalog DB (metadata). This is the entire on-disk cost of browsing
        // + streaming a huge server library — audio is streamed on demand and
        // never persisted, artwork is an in-memory cache, so the phone stores
        // only this until the user explicitly downloads. Guard it stays modest.
        func fileSize(_ u: URL) -> Int64 {
            (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
        }
        let dbBytes = fileSize(url)
            + fileSize(url.appendingPathExtension("wal"))
            + fileSize(URL(fileURLWithPath: url.path + "-wal"))
        let dbMB = Double(dbBytes) / 1_048_576.0
        print(String(format: "[PERF 100k] catalog DB on disk (nothing downloaded): %.1f MB", dbMB))
        XCTAssertLessThan(dbMB, 250, "100k-track catalog DB unexpectedly large: \(dbMB) MB")

        let harness = PerformanceHarness(reopened)
        let metrics = try await harness.measureReads(
            serverId: serverId, iterations: 5,
            generationSeconds: generationSeconds, coldOpenMs: coldOpenMs
        )

        XCTAssertEqual(metrics.trackCount, 100_000)
        XCTAssertLessThan(metrics.searchP95Ms, 100, "search p95 exceeded 100ms bar at 100k: \(metrics.searchP95Ms)")
        print("[PERF 100k]\n\(metrics.summary)")

        // Recommendation candidate-generation cost at scale. Off the user's hot
        // path (sets are precomputed off-main; the UI reads the stored result),
        // so the budget is generous — this exists to give the ORDER BY RANDOM() +
        // json_each scan a number and catch a pathological regression before the
        // planned genre-normalized table turns it into an indexed join.
        let candGenMs = try await harness.measureCandidateGenerationMs(serverId: serverId)
        print("[PERF 100k] candidate generation: \(String(format: "%.1f", candGenMs)) ms")
        XCTAssertLessThan(candGenMs, 1_500, "candidate generation regressed badly at 100k: \(candGenMs) ms")

        // B4.5 enriched paths (normalized track.genres ∪ mb_tags). Populate mb_tags
        // for most tracks so the Swift-folded UNION corpus + widened candidate scan
        // are measured with realistic json_each expansion, not an empty mb_tags
        // column. Off the hot path (hourly-TTL corpus, precomputed sets), so the
        // budgets are generous — this just gives the enriched cost a number.
        let written = try await harness.populateSyntheticMbTags(serverId: serverId, fraction: 0.9, tagsPerTrack: 4)
        print("[PERF 100k] populated mb_tags on \(written) tracks")
        let corpusMs = try await harness.measureGenreFrequenciesMs(serverId: serverId, enrich: true)
        print("[PERF 100k] enriched genre corpus: \(String(format: "%.1f", corpusMs)) ms")
        XCTAssertLessThan(corpusMs, 4_000, "enriched corpus fold regressed at 100k: \(corpusMs) ms")
        let candEnrichMs = try await harness.measureCandidateGenerationMs(serverId: serverId, enrich: true)
        print("[PERF 100k] enriched candidate generation: \(String(format: "%.1f", candEnrichMs)) ms")
        XCTAssertLessThan(candEnrichMs, 2_500, "enriched candidate generation regressed at 100k: \(candEnrichMs) ms")

        // Regression guard for the as-you-type hang: every synthetic track title
        // contains "the", so a short prefix matches almost the entire FTS index.
        // Ranking that with bm25 forces scoring the whole match set (~60ms at
        // 100k, and far worse on-device / concurrently with a sync). Short
        // queries must early-terminate at LIMIT instead and stay ~single-digit ms.
        let repo = LibraryRepository(reopened)
        for term in ["t", "th", "a", "s"] {
            let start = Date()
            _ = try await repo.search(term, serverId: serverId)
            let ms = Date().timeIntervalSince(start) * 1000
            XCTAssertLessThan(ms, 30, "broad prefix '\(term)' too slow (\(ms) ms) — bm25 full-scan regression?")
        }
    }
}
