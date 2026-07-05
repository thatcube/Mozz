import XCTest
import MozzCore
@testable import MozzDatabase

/// Performance-bar guards. The lighter case always runs and asserts the
/// sub-100ms search target; the full 100k-track case is gated behind
/// `MOZZ_RUN_PERF=1` (it is heavier) and prints the numbers reported in
/// ARCHITECTURE.md.
final class PerformanceHarnessTests: XCTestCase {
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
