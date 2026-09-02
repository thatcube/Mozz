import XCTest
@testable import MozzAnalysis

/// Deterministic test signals.
///
/// Everything here is generated, never sampled from a file: a fixture that is
/// audio is a fixture nobody can read in a diff, and the properties under test
/// (is a tone closer to a tone than to noise, does a 120 BPM pulse read as
/// 120 BPM) are properties of synthetic signals in the first place.
enum Signal {
    static let rate = 16_000

    static func sine(hz: Double, seconds: Double, amplitude: Double = 0.5) -> [Float] {
        let count = Int(Double(rate) * seconds)
        return (0..<count).map { i in
            Float(amplitude * sin(2 * Double.pi * hz * Double(i) / Double(rate)))
        }
    }

    /// A fixed-seed LCG, so "noise" is the same noise on every machine and in
    /// every run — otherwise the golden fixture below could never exist.
    static func noise(seconds: Double, amplitude: Double = 0.5, seed: UInt64 = 0x5EED) -> [Float] {
        let count = Int(Double(rate) * seconds)
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(state >> 11) / Double(UInt64(1) << 53)
            return Float((unit * 2 - 1) * amplitude)
        }
    }

    /// Clicks at a fixed tempo over a quiet tone, which is about the simplest
    /// thing with an unambiguous pulse.
    static func pulse(bpm: Double, seconds: Double) -> [Float] {
        var samples = sine(hz: 220, seconds: seconds, amplitude: 0.05)
        let period = Int(Double(rate) * 60 / bpm)
        guard period > 0 else { return samples }
        var position = 0
        while position < samples.count {
            for offset in 0..<min(200, samples.count - position) {
                let decay = 1 - Double(offset) / 200
                samples[position + offset] += Float(0.9 * decay)
            }
            position += period
        }
        return samples
    }
}

final class SonicAnalyzerTests: XCTestCase {
    private let analyzer = SonicAnalyzer()

    // MARK: Shape and determinism

    func testVectorIsTheDocumentedWidthAndUnitLength() throws {
        let features = try XCTUnwrap(analyzer.analyze(Signal.sine(hz: 440, seconds: 5)))
        XCTAssertEqual(features.dimension, SonicFeatureLayout.dimension)
        let norm = features.values.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 1e-5, "vectors are compared by cosine, so they must be unit length")
        XCTAssertEqual(features.engine, "mozz-dsp@1")
    }

    func testAnalysisIsDeterministic() throws {
        // The whole cross-platform design rests on this: the same bytes must give
        // the same vector, every time, or a phone and a laptop disagree about
        // what a track sounds like.
        let samples = Signal.noise(seconds: 4)
        let first = try XCTUnwrap(analyzer.analyze(samples))
        let second = try XCTUnwrap(analyzer.analyze(samples))
        XCTAssertEqual(first.values, second.values)
    }

    // MARK: Discrimination — the property the whole thing exists for

    func testTonesAreCloserToTonesThanToNoise() throws {
        let a440 = try XCTUnwrap(analyzer.analyze(Signal.sine(hz: 440, seconds: 5)))
        let a880 = try XCTUnwrap(analyzer.analyze(Signal.sine(hz: 880, seconds: 5)))
        let noise = try XCTUnwrap(analyzer.analyze(Signal.noise(seconds: 5)))

        let toneToTone = try XCTUnwrap(a440.similarity(to: a880))
        let toneToNoise = try XCTUnwrap(a440.similarity(to: noise))
        XCTAssertGreaterThan(toneToTone, toneToNoise,
                             "two pure tones must read as more alike than a tone and white noise")
    }

    func testATrackIsMaximallySimilarToItself() throws {
        let features = try XCTUnwrap(analyzer.analyze(Signal.sine(hz: 440, seconds: 5)))
        XCTAssertEqual(try XCTUnwrap(features.similarity(to: features)), 1.0, accuracy: 1e-4)
    }

    func testSimilarityRefusesToCompareAcrossEngines() throws {
        let features = try XCTUnwrap(analyzer.analyze(Signal.sine(hz: 440, seconds: 5)))
        let alien = SonicFeatures(values: features.values, engine: "someone-elses@3",
                                  tempoBPM: nil, loudnessDBFS: -12, analyzedSeconds: 5)
        XCTAssertNil(features.similarity(to: alien),
                     "two analyzers do not share a coordinate space; a plausible number here would be a lie")
        let shortened = SonicFeatures(values: Array(features.values.dropLast()),
                                      engine: features.engine, tempoBPM: nil,
                                      loudnessDBFS: -12, analyzedSeconds: 5)
        XCTAssertNil(features.similarity(to: shortened))
    }

    // MARK: Rhythm

    func testTempoFindsThePulseOrAMusicalMultipleOfIt() throws {
        let features = try XCTUnwrap(analyzer.analyze(Signal.pulse(bpm: 120, seconds: 12)))
        let bpm = try XCTUnwrap(features.tempoBPM)
        // Half and double time are the same pulse — a well-known ambiguity that
        // this deliberately does not try to resolve.
        let plausible = [60.0, 120.0, 240.0].contains { abs(bpm - $0) < 6 }
        XCTAssertTrue(plausible, "expected ~60/120/240 BPM, measured \(bpm)")
    }

    func testAToneHasNoTempoRatherThanAMadeUpOne() throws {
        let features = try XCTUnwrap(analyzer.analyze(Signal.sine(hz: 440, seconds: 8)))
        XCTAssertNil(features.tempoBPM, "a steady tone has no pulse; reporting one would be invention")
    }

    // MARK: Refusals

    func testSilenceAndVeryShortInputAreNotAnalyzed() {
        let silence = [Float](repeating: 0, count: Signal.rate * 4)
        XCTAssertNil(analyzer.analyze(silence),
                     "a zero vector would sit in the index claiming to be equidistant from everything")
        XCTAssertNil(analyzer.analyze(Signal.sine(hz: 440, seconds: 0.1)))
        XCTAssertNil(analyzer.analyze([]))
    }

    func testLoudnessIsReportedInDBFS() throws {
        let loud = try XCTUnwrap(analyzer.analyze(Signal.sine(hz: 440, seconds: 4, amplitude: 0.5)))
        let quiet = try XCTUnwrap(analyzer.analyze(Signal.sine(hz: 440, seconds: 4, amplitude: 0.05)))
        XCTAssertGreaterThan(loud.loudnessDBFS, quiet.loudnessDBFS)
        XCTAssertLessThan(loud.loudnessDBFS, 0)
    }
}
