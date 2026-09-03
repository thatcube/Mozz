import XCTest
import Foundation
@testable import MozzAnalysis

/// How long one 0.96-second patch takes, which decides whether a library can be
/// analyzed at all. Skipped without weights, like the parity test.
final class VGGishSpeedTests: XCTestCase {
    func testOnePatchIsFastEnoughToAnalyzeALibrary() throws {
        guard let path = ProcessInfo.processInfo.environment["MOZZ_VGGISH_WEIGHTS"] else {
            throw XCTSkip("set MOZZ_VGGISH_WEIGHTS")
        }
        let trunk = try VGGishTrunk(weights: Data(contentsOf: URL(fileURLWithPath: path)))
        var generator = SystemRandomNumberGenerator()
        let patch = (0..<(96 * 64)).map { _ in Float.random(in: -4...2, using: &generator) }

        _ = trunk.embed(patch: patch)               // warm caches
        let started = Date()
        let runs = 3
        for _ in 0..<runs { _ = trunk.embed(patch: patch) }
        let each = Date().timeIntervalSince(started) / Double(runs)
        // A 90-second window is 94 patches; the runner samples fewer than that.
        print(String(format: "\n  one patch: %.3fs   →  %.1fs for a 90s window, %.1fs for 12 sampled patches\n",
                     each, each * 94, each * 12))
    }
}
