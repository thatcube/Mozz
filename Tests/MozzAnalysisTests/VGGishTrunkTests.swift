import XCTest
import Foundation
@testable import MozzAnalysis

/// Proves the hand-written convolution stack computes what PyTorch computes.
///
/// This is the test that makes porting a model defensible at all. Six
/// convolutions is not much code, but "not much code" and "the same numbers as
/// the reference implementation" are different claims, and only one of them
/// keeps an iPhone's vectors comparable with a Pixel's.
///
/// The weights are not in the repository — they are 9 MB and belong wherever
/// each platform ships resources — so this skips unless `MOZZ_VGGISH_WEIGHTS`
/// points at the file `tools/export-vggish.py` produced.
final class VGGishTrunkTests: XCTestCase {
    private func trunk() throws -> VGGishTrunk {
        guard let path = ProcessInfo.processInfo.environment["MOZZ_VGGISH_WEIGHTS"] else {
            throw XCTSkip("set MOZZ_VGGISH_WEIGHTS to the exported vggish-trunk.bin")
        }
        return try VGGishTrunk(weights: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json",
                                                  subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTheEmbeddingMatchesPyTorch() throws {
        let trunk = try trunk()
        let fixture = try fixture("conv-fixture")
        let input = try XCTUnwrap(fixture["input"] as? [Double]).map(Float.init)
        let expected = try XCTUnwrap(fixture["embedding"] as? [Double]).map(Float.init)

        let embedding = trunk.embed(patch: input)
        XCTAssertEqual(embedding.count, VGGishTrunk.embeddingSize)
        XCTAssertEqual(embedding.count, expected.count)

        // Half-precision weights, and a different summation order from
        // PyTorch's, so exact equality is not the bar — agreeing to well
        // within the differences that separate one track from another is.
        var worst: Float = 0
        for (got, want) in zip(embedding, expected) {
            worst = Swift.max(worst, abs(got - want))
        }
        XCTAssertLessThan(worst, 0.01, "largest per-value deviation from PyTorch")

        // And the thing that actually matters downstream: the same direction.
        var dot = 0.0, gotNorm = 0.0, wantNorm = 0.0
        for (got, want) in zip(embedding, expected) {
            dot += Double(got) * Double(want)
            gotNorm += Double(got) * Double(got)
            wantNorm += Double(want) * Double(want)
        }
        let cosine = dot / (gotNorm.squareRoot() * wantNorm.squareRoot())
        XCTAssertGreaterThan(cosine, 0.9999, "cosine against the reference embedding")
    }

    func testHalfPrecisionWidensExactly() {
        // The values that break naive conversions: zero, subnormals, the
        // largest finite half, and a plain fraction.
        XCTAssertEqual(VGGishTrunk.float(fromHalf: 0x0000), 0)
        XCTAssertEqual(VGGishTrunk.float(fromHalf: 0x8000), -0.0)
        XCTAssertEqual(VGGishTrunk.float(fromHalf: 0x3C00), 1)
        XCTAssertEqual(VGGishTrunk.float(fromHalf: 0xC000), -2)
        XCTAssertEqual(VGGishTrunk.float(fromHalf: 0x3555), 0.333251953125, accuracy: 1e-9)
        XCTAssertEqual(VGGishTrunk.float(fromHalf: 0x7BFF), 65504)
        XCTAssertEqual(VGGishTrunk.float(fromHalf: 0x0001), 5.9604645e-08, accuracy: 1e-14)
        XCTAssertEqual(VGGishTrunk.float(fromHalf: 0x03FF), 6.0975552e-05, accuracy: 1e-11)
    }

    func testRefusesSomethingThatIsNotWeights() {
        XCTAssertThrowsError(try VGGishTrunk(weights: Data("not weights at all".utf8)))
        XCTAssertThrowsError(try VGGishTrunk(weights: Data()))
    }
}

/// The front end, checked against the patch the reference implementation makes
/// from a known waveform. Needs no weights, so it always runs.
final class VGGishFrontEndTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "mel-fixture", withExtension: "json",
                                                  subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testTheLogMelPatchMatchesTheReference() throws {
        let fixture = try fixture()
        let expected = try XCTUnwrap(fixture["patch"] as? [Double]).map(Float.init)
        let rate = VGGishFrontEnd.sampleRate

        // The same three tones the exporter used.
        let samples = (0..<(rate * 2)).map { i -> Float in
            let t = Double(i) / Double(rate)
            return Float(0.4 * sin(2 * .pi * 220 * t)
                       + 0.25 * sin(2 * .pi * 1310 * t)
                       + 0.1 * sin(2 * .pi * 5000 * t))
        }

        let patches = VGGishFrontEnd().allPatches(samples)
        let patch = try XCTUnwrap(patches.first)
        XCTAssertEqual(patch.count, expected.count)

        var worst: Float = 0
        for (got, want) in zip(patch, expected) { worst = Swift.max(worst, abs(got - want)) }
        XCTAssertLessThan(worst, 0.002, "largest deviation from the reference log-mel")
    }

    func testTheMelScaleIsHTKNotSlaney() {
        // 1127 * ln(1 + f/700). Getting this wrong is silent: the patch still
        // looks like a spectrogram, and the network reads a different one.
        XCTAssertEqual(VGGishFrontEnd.hertzToMel(0), 0, accuracy: 1e-9)
        XCTAssertEqual(VGGishFrontEnd.hertzToMel(700), 1127 * log(2.0), accuracy: 1e-6)
        XCTAssertEqual(VGGishFrontEnd.hertzToMel(7500), 1127 * log(1 + 7500.0 / 700), accuracy: 1e-6)
        XCTAssertEqual(VGGishFrontEnd.hertzToMel(7500), 2773.33, accuracy: 0.01)
    }

    func testSampledPatchesSpanTheWholeWindow() {
        let rate = VGGishFrontEnd.sampleRate
        // Twenty seconds: plenty of patches to choose between.
        let samples = (0..<(rate * 20)).map { i -> Float in
            Float(sin(2 * .pi * 440 * Double(i) / Double(rate)))
        }
        let front = VGGishFrontEnd()
        let sampled = front.patches(samples, limit: 8)
        XCTAssertEqual(sampled.count, 8)
        XCTAssertTrue(sampled.allSatisfy { $0.count == VGGishFrontEnd.patchFrames * 64 })
        // Fewer patches than exist, and they must not all come from the front.
        XCTAssertLessThan(sampled.count, front.allPatches(samples).count)
    }

    func testAudioShorterThanOnePatchProducesNone() {
        let samples = [Float](repeating: 0.1, count: VGGishFrontEnd.sampleRate / 2)
        XCTAssertTrue(VGGishFrontEnd().allPatches(samples).isEmpty)
        XCTAssertTrue(VGGishFrontEnd().patches(samples, limit: 4).isEmpty)
    }
}
