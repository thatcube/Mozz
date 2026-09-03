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

    /// The engine as it ships, plus the candidates for replacing it.
    ///
    /// Kept as one list rather than one test each because decoding the audio
    /// dominates the run: every variant is scored on the same prepared samples,
    /// so adding one costs a pass of DSP rather than a pass of MP3.
    /// Measured on 1,200 FMA tracks, 2026-09-02 — none of the alternatives beat
    /// the shipping engine, and the spread across all six is inside the noise
    /// floor for this sample size (±1.3pp on a 70% proportion):
    ///
    ///     v1 (shipping)             69.6% top-3   47.2% 1-NN
    ///     + deltas                  68.4%         46.4%
    ///     + gain norm               69.6%         46.9%
    ///     20 mfcc                   68.7%         48.1%
    ///     20 mfcc + deltas          68.3%         48.1%
    ///     20 mfcc + deltas + gain   69.0%         48.5%
    ///
    /// Which is worth keeping precisely because it is a negative result: more
    /// coefficients and more statistics do not make this class of descriptor
    /// hear more. The remaining gains are in WHICH audio gets described — the
    /// window, and how much of the song it covers — and in what the recommender
    /// does with the vectors, not in the vector itself.
    private var variants: [(name: String, configuration: SonicAnalyzer.Configuration)] {
        let v1 = SonicAnalyzer.Configuration.v1
        func tweak(mfcc: Int = SonicFeatureLayout.mfccCount,
                   deltas: Bool = false, gain: Bool = false) -> SonicAnalyzer.Configuration {
            SonicAnalyzer.Configuration(
                sampleRate: v1.sampleRate, frameSize: v1.frameSize, hopSize: v1.hopSize,
                melBands: v1.melBands, melMinHz: v1.melMinHz, melMaxHz: v1.melMaxHz,
                mfccCount: mfcc, includeMFCCDeltas: deltas, normalizeGain: gain)
        }
        return [
            ("v1 (shipping)", v1),
            ("+ deltas", tweak(deltas: true)),
            ("+ gain norm", tweak(gain: true)),
            ("20 mfcc", tweak(mfcc: 20)),
            ("20 mfcc + deltas", tweak(mfcc: 20, deltas: true)),
            ("20 mfcc + deltas + gain", tweak(mfcc: 20, deltas: true, gain: true)),
        ]
    }

    func testNeighboursShareTheirLabelMoreOftenThanChance() throws {
        guard let root else {
            throw XCTSkip("set MOZZ_BENCHMARK_DIR to a folder of <label>/<track>.mp3")
        }

        let analyzers = variants.map { ($0.name, SonicAnalyzer(configuration: $0.configuration)) }
        // The learned engine, when its weights are available. Scored on exactly
        // the same audio, through exactly the same metric, so the comparison is
        // the port's own numbers rather than the Python prototype's.
        let learned: VGGishAnalyzer? = ProcessInfo.processInfo.environment["MOZZ_VGGISH_WEIGHTS"]
            .flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            .flatMap { try? VGGishTrunk(weights: $0) }
            .map { VGGishAnalyzer(trunk: $0) }
        var learnedVectors: [[Float]] = []
        var labels: [String] = []
        var names: [String] = []
        var byVariant: [[[Float]]] = Array(repeating: [], count: analyzers.count)

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
                let rate = SonicAnalyzer.Configuration.v1.sampleRate
                let prepared = AudioPreparation.prepare(decoded, sampleRate: rate)
                // The clips are already excerpts, so no lead-in is skipped:
                // taking twenty seconds off a thirty-second clip would leave
                // ten, and the point is to measure the analyzer rather than the
                // windowing.
                let window = SonicAnalysisService.window(prepared, sampleRate: rate, trimLeadIn: false)
                let features = analyzers.map { $0.1.analyze(window) }
                // A track only counts when every variant could describe it, so
                // the comparison is over one identical set of songs.
                guard features.allSatisfy({ $0 != nil }) else { continue }
                var learnedVector: [Float]?
                if let learned {
                    // VGGish wants 16 kHz, which is what the DSP engine's
                    // configuration already resamples to.
                    guard let f = learned.analyze(prepared) else { continue }
                    learnedVector = f.values
                }
                labels.append(dir.lastPathComponent)
                names.append(file.deletingPathExtension().lastPathComponent)
                for (i, f) in features.enumerated() { byVariant[i].append(f!.values) }
                if let learnedVector { learnedVectors.append(learnedVector) }
            }
        }

        XCTAssertGreaterThan(labels.count, 50, "not enough analyzable audio to measure anything")

        // Optional dump, so the same vectors can be scored against metadata this
        // harness does not have — artist and album, which are sharper probes of
        // "sounds like" than eight coarse genres.
        if let out = ProcessInfo.processInfo.environment["MOZZ_BENCHMARK_OUT"] {
            let shipping = byVariant[0]
            let body = zip(names, shipping).map { name, vector in
                "\(name)\t" + vector.map { String($0) }.joined(separator: ",")
            }.joined(separator: "\n")
            try? body.write(toFile: out, atomically: true, encoding: .utf8)
        }

        let counts = labels.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let n = Double(labels.count)
        let chance = counts.values.reduce(0.0) { total, count in
            let share = Double(count) / n
            let missOne = 1 - (Double(count) - 1) / (n - 1)
            return total + share * (1 - pow(missOne, 3))
        }

        print("""

        ── sonic benchmark ──────────────────────────────
          \(labels.count) tracks across \(counts.count) labels
          chance: \(String(format: "%.1f%%", chance * 100)) in top-3, \
        \(String(format: "%.1f%%", 100 / Double(counts.count))) for 1-NN

          variant                    top-3    1-NN
        """)

        var best = (name: "", score: -1.0)
        var perVariantByLabel: [String: [String: Double]] = [:]
        for (index, (name, _)) in analyzers.enumerated() {
            // The same corpus standardization the app searches through, so this
            // measures what ships rather than the raw vectors.
            let corpus = SonicCorpusStats(byVariant[index])
            let space = byVariant[index].map { corpus.normalize($0) }

            var hits = 0, nearestHits = 0
            var byLabel: [String: (hits: Int, total: Int)] = [:]
            for i in space.indices {
                let ranked = space.indices
                    .filter { $0 != i }
                    .sorted { dot(space[i], space[$0]) > dot(space[i], space[$1]) }
                let hit = ranked.prefix(3).contains { labels[$0] == labels[i] }
                if hit { hits += 1 }
                if let nearest = ranked.first, labels[nearest] == labels[i] { nearestHits += 1 }
                byLabel[labels[i], default: (0, 0)].hits += hit ? 1 : 0
                byLabel[labels[i], default: (0, 0)].total += 1
            }
            let precision = Double(hits) / n
            let nearest = Double(nearestHits) / n
            print(String(format: "  %-24@  %5.1f%%  %5.1f%%", name as NSString,
                         precision * 100, nearest * 100))
            if precision > best.score { best = (name, precision) }
            perVariantByLabel[name] = byLabel.mapValues { Double($0.hits) / Double($0.total) }
        }
        if learned != nil, learnedVectors.count == labels.count {
            let corpus = SonicCorpusStats(learnedVectors)
            let space = learnedVectors.map { corpus.normalize($0) }
            var hits = 0, nearestHits = 0
            for i in space.indices {
                let ranked = space.indices.filter { $0 != i }
                    .sorted { dot(space[i], space[$0]) > dot(space[i], space[$1]) }
                if ranked.prefix(3).contains(where: { labels[$0] == labels[i] }) { hits += 1 }
                if let nearest = ranked.first, labels[nearest] == labels[i] { nearestHits += 1 }
            }
            print(String(format: "  %-24@  %5.1f%%  %5.1f%%   <- the port",
                         "mozz-vggish@1" as NSString,
                         Double(hits) / n * 100, Double(nearestHits) / n * 100))
        }
        print("\n  best: \(best.name)\n")

        // Per-label, for the winner and the incumbent — a variant that only
        // helps one genre is a variant that overfits this dataset.
        for name in Set(["v1 (shipping)", best.name]).sorted() where perVariantByLabel[name] != nil {
            let byLabel = perVariantByLabel[name]!
            print("  \(name)")
            for (label, share) in byLabel.sorted(by: { $0.key < $1.key }) {
                print(String(format: "    %-16@ %5.0f%%", label as NSString, share * 100))
            }
        }

        XCTAssertGreaterThan(best.score, chance,
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
