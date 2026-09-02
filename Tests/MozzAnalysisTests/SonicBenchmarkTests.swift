import XCTest
import Foundation
@testable import MozzAnalysis

/// Measures the analyzer against music somebody else labelled.
///
/// Every other test here says the code does what it was written to do. This one
/// asks a different question — whether what it was written to do is any good —
/// and the only honest way to answer that is against audio with independent
/// ground truth, because a similarity engine graded on its own output always
/// passes.
///
/// Skipped unless `MOZZ_BENCHMARK_DIR` names a directory of labelled audio, so
/// it costs a normal test run nothing. The layout is one folder per label:
///
///     <dir>/Rock/*.mp3
///     <dir>/Hip-Hop/*.mp3
///
/// which is what the FMA "small" set unpacks to once its CSV is applied (see
/// `tools/fma-benchmark.py`). Any labelled collection in that shape works.
///
/// The metric is retrieval, not classification: for each track, do its nearest
/// neighbours carry the same label? That is the question radio actually asks,
/// and it needs no training and no held-out split.
final class SonicBenchmarkTests: XCTestCase {
    private var root: URL? {
        guard let path = ProcessInfo.processInfo.environment["MOZZ_BENCHMARK_DIR"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func testNeighboursShareTheirLabelMoreOftenThanChance() throws {
        guard let root else {
            throw XCTSkip("set MOZZ_BENCHMARK_DIR to a folder of <label>/<track>.mp3")
        }

        let analyzer = SonicAnalyzer()
        var labels: [String] = []
        var vectors: [[Float]] = []

        let labelDirs = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        XCTAssertFalse(labelDirs.isEmpty, "no label folders in \(root.path)")

        for dir in labelDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "mp3" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                guard let data = try? Data(contentsOf: file),
                      let decoded = MP3Decoder.decode(data)
                else { continue }
                let prepared = AudioPreparation.prepare(decoded, sampleRate: analyzer.configuration.sampleRate)
                // The clips are already excerpts, so no lead-in is skipped:
                // taking twenty seconds off a thirty-second clip would leave
                // ten, and the point is to measure the analyzer rather than the
                // windowing.
                let window = SonicAnalysisService.window(prepared,
                                                         sampleRate: analyzer.configuration.sampleRate,
                                                         trimLeadIn: false)
                guard let features = analyzer.analyze(window) else { continue }
                labels.append(dir.lastPathComponent)
                vectors.append(features.values)
            }
        }

        XCTAssertGreaterThan(vectors.count, 50, "not enough analyzable audio to measure anything")

        // The same corpus standardization the app searches through, so this
        // measures what ships rather than the raw vectors.
        let corpus = SonicCorpusStats(vectors)
        let space = vectors.map { corpus.normalize($0) }

        var hits = 0
        var nearestHits = 0
        for i in space.indices {
            let ranked = space.indices
                .filter { $0 != i }
                .sorted { dot(space[i], space[$0]) > dot(space[i], space[$1]) }
            let neighbours = ranked.prefix(3)
            if neighbours.contains(where: { labels[$0] == labels[i] }) { hits += 1 }
            // The nearest neighbour alone, which is the closest thing here to
            // the "genre accuracy" figure papers report — a 1-NN classifier —
            // and therefore the only number worth comparing to one.
            if let nearest = ranked.first, labels[nearest] == labels[i] { nearestHits += 1 }
        }
        let precision = Double(hits) / Double(space.count)
        let nearest = Double(nearestHits) / Double(space.count)

        // What a coin would score: the chance that three random draws include
        // at least one of the seed's own label.
        let counts = labels.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let n = Double(space.count)
        let chance = counts.values.reduce(0.0) { total, count in
            let share = Double(count) / n
            let missOne = 1 - (Double(count) - 1) / (n - 1)
            return total + share * (1 - pow(missOne, 3))
        }

        print("""

        ── sonic benchmark ──────────────────────────────
          tracks      \(space.count) across \(counts.count) labels
          label in top-3   \(String(format: "%.1f%%", precision * 100))
          chance           \(String(format: "%.1f%%", chance * 100))
          lift             \(String(format: "%.1fx", precision / max(chance, 0.0001)))
          1-NN accuracy    \(String(format: "%.1f%%", nearest * 100))  (vs \(String(format: "%.1f%%", 100.0 / Double(counts.count))) for a guess)
        ─────────────────────────────────────────────────

        """)
        for (label, count) in counts.sorted(by: { $0.key < $1.key }) {
            let idx = space.indices.filter { labels[$0] == label }
            let perLabel = idx.filter { i in
                let ranked = space.indices.filter { $0 != i }
                    .sorted { dot(space[i], space[$0]) > dot(space[i], space[$1]) }
                return ranked.prefix(3).contains { labels[$0] == label }
            }.count
            print(String(format: "  %-14@ %3d tracks   %.0f%%", label as NSString, count,
                         Double(perLabel) / Double(count) * 100))
        }

        XCTAssertGreaterThan(precision, chance,
                             "the analyzer must beat chance or it is hearing nothing")
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Double {
        var sum = 0.0
        for i in a.indices { sum += Double(a[i]) * Double(b[i]) }
        return sum
    }
}

/// The corpus transform, duplicated here rather than imported: `SonicCorpus`
/// lives in `MozzRecommend`, which knows about databases and servers, and a
/// benchmark over a folder of files should not have to.
private struct SonicCorpusStats {
    private let mean: [Float]
    private let inverseSD: [Float]

    init(_ vectors: [[Float]]) {
        let width = vectors.first?.count ?? 0
        var mean = [Float](repeating: 0, count: width)
        for v in vectors { for i in 0..<width { mean[i] += v[i] } }
        let count = Float(max(vectors.count, 1))
        for i in 0..<width { mean[i] /= count }
        var variance = [Float](repeating: 0, count: width)
        for v in vectors {
            for i in 0..<width {
                let d = v[i] - mean[i]
                variance[i] += d * d
            }
        }
        self.mean = mean
        self.inverseSD = (0..<width).map { i in
            let sd = (variance[i] / count).squareRoot()
            return sd > 1e-6 ? 1 / sd : 0
        }
    }

    func normalize(_ vector: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: vector.count)
        for i in vector.indices { out[i] = (vector[i] - mean[i]) * inverseSD[i] }
        var sum: Float = 0
        for value in out { sum += value * value }
        let magnitude = sum.squareRoot()
        guard magnitude > 1e-9 else { return out }
        return out.map { $0 / magnitude }
    }
}
