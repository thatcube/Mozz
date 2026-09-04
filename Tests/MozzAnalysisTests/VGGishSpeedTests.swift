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

        // And the thing that actually matters: a whole track, with its patches
        // convolved across cores the way the runner does it.
        let analyzer = VGGishAnalyzer(trunk: trunk)
        let audio = (0..<(VGGishFrontEnd.sampleRate * 90)).map { i -> Float in
            Float(sin(2 * .pi * 440 * Double(i) / Double(VGGishFrontEnd.sampleRate)) * 0.4)
        }
        _ = analyzer.analyze(audio)                 // warm
        let trackStart = Date()
        _ = analyzer.analyze(audio)
        let perTrack = Date().timeIntervalSince(trackStart)

        print(String(format: "\n  one patch, serial: %.3fs\n  one track (%d patches, parallel): %.2fs = %.1f tracks/min\n  a 9,486-track library: %.1f hours on this machine\n",
                     each, VGGishAnalyzer.patchesPerTrack, perTrack,
                     60 / perTrack, 9486 * perTrack / 3600))
    }
}
