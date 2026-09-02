import XCTest
@testable import MozzAnalysis

/// Conformance against `spec/sonic/mozz-dsp-v1.json`.
///
/// The contract this pins is the one the whole design rests on: **the same PCM
/// produces the same vector on every platform.** Vectors are portable app data
/// — they are stored per track, they sync between a phone and a laptop, and
/// they end up in one nearest-neighbour index — so an iPhone and a Pixel
/// disagreeing in the fourth decimal is not a cosmetic difference, it is two
/// devices holding different opinions about what a song sounds like.
///
/// The inputs are synthetic and generated from a fixed seed rather than sampled
/// from audio files, so the fixture is readable, tiny, and reproducible by an
/// implementation in any language.
///
/// Note what is NOT pinned: a *track's* vector. A server transcodes, and two
/// transcoder versions give different PCM for the same song. This pins the part
/// that is ours — PCM in, vector out.
///
/// To regenerate after a deliberate engine change (which must also bump
/// `SonicAnalyzer.engine`):
///
///     MOZZ_WRITE_SONIC_SPEC=1 swift test --filter SonicSpecConformanceTests
///
final class SonicSpecConformanceTests: XCTestCase {
    private struct Spec: Codable {
        var engine: String
        var dimension: Int
        var sampleRate: Int
        var cases: [Case]
    }

    private struct Case: Codable {
        var name: String
        var vector: [Double]
        var tempoBPM: Double?
        var loudnessDBFS: Double
    }

    /// The signals under contract, in a fixed order.
    private static let inputs: [(name: String, samples: () -> [Float])] = [
        ("sine-440", { Signal.sine(hz: 440, seconds: 5) }),
        ("sine-110-quiet", { Signal.sine(hz: 110, seconds: 5, amplitude: 0.08) }),
        ("white-noise", { Signal.noise(seconds: 5) }),
        ("pulse-120bpm", { Signal.pulse(bpm: 120, seconds: 10) }),
    ]

    func testVectorsMatchTheSpecExactly() throws {
        let analyzer = SonicAnalyzer()
        let produced: [Case] = try Self.inputs.map { input in
            let features = try XCTUnwrap(analyzer.analyze(input.samples()),
                                         "\(input.name) produced no vector")
            return Case(name: input.name,
                        vector: features.values.map { Double($0) },
                        tempoBPM: features.tempoBPM,
                        loudnessDBFS: features.loudnessDBFS)
        }

        if ProcessInfo.processInfo.environment["MOZZ_WRITE_SONIC_SPEC"] == "1" {
            let spec = Spec(engine: SonicAnalyzer.engine,
                            dimension: SonicFeatureLayout.dimension,
                            sampleRate: Signal.rate,
                            cases: produced)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(spec).write(to: Self.specURL())
            throw XCTSkip("Rewrote \(Self.specURL().path); re-run without MOZZ_WRITE_SONIC_SPEC to verify.")
        }

        let spec = try Self.loadSpec()
        XCTAssertEqual(spec.engine, SonicAnalyzer.engine,
                       "the engine changed but the spec did not; bump the version and regenerate")
        XCTAssertEqual(spec.dimension, SonicFeatureLayout.dimension)
        XCTAssertEqual(spec.cases.map(\.name), produced.map(\.name))

        for (expected, actual) in zip(spec.cases, produced) {
            XCTAssertEqual(actual.vector.count, expected.vector.count, "\(expected.name): width changed")
            for i in 0..<min(actual.vector.count, expected.vector.count) {
                // Float32 storage, so agreement to ~1e-6 is the most any
                // implementation can promise. Anything looser would let a real
                // divergence through.
                XCTAssertEqual(actual.vector[i], expected.vector[i], accuracy: 1e-6,
                               "\(expected.name): component \(i) drifted")
            }
            XCTAssertEqual(actual.loudnessDBFS, expected.loudnessDBFS, accuracy: 1e-6,
                           "\(expected.name): loudness drifted")
            if let expectedTempo = expected.tempoBPM {
                XCTAssertEqual(try XCTUnwrap(actual.tempoBPM), expectedTempo, accuracy: 1e-6,
                               "\(expected.name): tempo drifted")
            } else {
                XCTAssertNil(actual.tempoBPM, "\(expected.name): tempo appeared where the spec has none")
            }
        }
    }

    // MARK: Loading

    /// Walk up to the repository root. Deliberately NOT a bundle resource: the
    /// fixture belongs to `spec/`, shared with every other implementation, and a
    /// copy in the bundle is a copy that can drift from the one others read.
    private static func specURL() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("spec/sonic/mozz-dsp-v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let specDirectory = directory.appendingPathComponent("spec")
            if FileManager.default.fileExists(atPath: specDirectory.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: "spec/sonic/mozz-dsp-v1.json")
    }

    private static func loadSpec() throws -> Spec {
        try JSONDecoder().decode(Spec.self, from: Data(contentsOf: specURL()))
    }
}
