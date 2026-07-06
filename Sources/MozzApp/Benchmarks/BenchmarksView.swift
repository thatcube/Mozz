import SwiftUI
import MozzCore
import MozzDatabase
import os

/// In-app performance harness. Lets you load a large synthetic catalog directly
/// into the DB and measure the metrics on the performance bar: catalog size,
/// search latency (p50/p95), a full page fetch, and current memory. Results are
/// also printed to the console so they can be captured for ARCHITECTURE.md.
struct BenchmarksView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var isBusy = false
    @State private var log: [String] = []
    @State private var counts: (artists: Int, albums: Int, tracks: Int)?

    var body: some View {
        List {
            Section("Catalog") {
                if let counts {
                    LabeledContent("Artists", value: "\(counts.artists)")
                    LabeledContent("Albums", value: "\(counts.albums)")
                    LabeledContent("Tracks", value: "\(counts.tracks)")
                }
                LabeledContent("Memory", value: Format.bytes(Int64(Self.residentMemoryBytes())))
                Button("Load 100k-track catalog") { Task { await generate(.large) } }
                    .disabled(isBusy)
                Button("Load 20k-track catalog") {
                    Task { await generate(.init(artists: 400, albums: 2_000, tracks: 20_000)) }
                }
                .disabled(isBusy)
            }

            Section("Measure") {
                Button("Run search benchmark") { Task { await runSearchBenchmark() } }
                    .disabled(isBusy)
                Button("Run page-fetch benchmark") { Task { await runPageBenchmark() } }
                    .disabled(isBusy)
            }

            if isBusy {
                Section { HStack { ProgressView(); Text("Working…") } }
            }

            if !log.isEmpty {
                Section("Results") {
                    ForEach(log, id: \.self) { line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
        }
        .navigationTitle("Benchmarks")
        .task { await refreshCounts() }
    }

    private func generate(_ size: SyntheticCatalog.Size) async {
        guard let serverId = env.active?.connection.id else {
            append("No active server."); return
        }
        isBusy = true
        defer { isBusy = false }
        let start = Date()
        do {
            try await SyntheticCatalog(env.database).generate(serverId: serverId, size: size)
            let elapsed = Date().timeIntervalSince(start)
            append(String(format: "Generated %d tracks in %.2fs", size.tracks, elapsed))
            await refreshCounts()
        } catch {
            append("Generate failed: \(error.localizedDescription)")
        }
    }

    private func runSearchBenchmark() async {
        let serverId = env.active?.connection.id
        let repo = env.repository
        let terms = ["the", "love", "song", "night", "blue", "a", "day", "star", "heart", "fire"]
        isBusy = true
        defer { isBusy = false }
        var timings: [Double] = []
        for term in terms {
            let start = Date()
            _ = try? await repo.search(term, serverId: serverId)
            timings.append(Date().timeIntervalSince(start) * 1000)
        }
        timings.sort()
        let p50 = timings[timings.count / 2]
        let p95 = timings[min(timings.count - 1, Int(Double(timings.count) * 0.95))]
        append(String(format: "Search p50=%.1fms p95=%.1fms (n=%d)", p50, p95, timings.count))
    }

    private func runPageBenchmark() async {
        let serverId = env.active?.connection.id
        let repo = env.repository
        isBusy = true
        defer { isBusy = false }
        let start = Date()
        let page = (try? await repo.tracksPage(serverId: serverId, offset: 0, limit: 100)) ?? []
        let elapsed = Date().timeIntervalSince(start) * 1000
        append(String(format: "Fetched %d-track page in %.1fms", page.count, elapsed))
    }

    private func refreshCounts() async {
        let serverId = env.active?.connection.id
        let repo = env.repository
        async let a = repo.artistCount(serverId: serverId)
        async let al = repo.albumCount(serverId: serverId)
        async let t = repo.trackCount(serverId: serverId)
        counts = ((try? await a) ?? 0, (try? await al) ?? 0, (try? await t) ?? 0)
    }

    private func append(_ line: String) {
        log.insert(line, at: 0)
        os_log("%{public}@", line)
    }

    static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
