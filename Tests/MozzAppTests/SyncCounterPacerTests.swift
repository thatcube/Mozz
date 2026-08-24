import Foundation
import Testing
@testable import MozzApp

/// The sync counters are meant to keep moving between page arrivals. These pin
/// the pacing down deterministically, because eyeballing a progress card is a
/// bad way to tell "too fast" from "not moving".
@Suite("Sync counter pacing")
struct SyncCounterPacerTests {

    /// Step a pacer forward, sampling the displayed value each simulated second.
    private func run(_ pacer: inout SyncCounterPacer, seconds: Int) -> [Int] {
        var samples: [Int] = []
        for _ in 0..<seconds {
            for _ in 0..<30 { pacer.advance(by: 1.0 / 30.0) }
            samples.append(pacer.displayed)
        }
        return samples
    }

    @Test("First sight adopts the count instead of counting up from zero")
    func seedsOnFirstReport() {
        var pacer = SyncCounterPacer()
        pacer.report(3_000)
        // Opening the app mid-sync must not animate 0 → 3000.
        #expect(pacer.displayed == 3_000)
    }

    @Test("A page arrival is spread out, not consumed instantly")
    func spreadsAStep() {
        let start = Date()
        var pacer = SyncCounterPacer(defaultInterval: 20)
        pacer.report(0, at: start)
        pacer.report(500, at: start.addingTimeInterval(20))

        let samples = run(&pacer, seconds: 3)
        // The whole point: three seconds in, it is still climbing — not parked
        // at 500 having burned through the step in the first second.
        #expect(samples.last! < 500, "consumed the step too fast: \(samples)")
        #expect(samples.first! > 0, "did not move at all: \(samples)")
    }

    @Test("The counter never runs past what the sync reported")
    func neverOptimistic() {
        let start = Date()
        var pacer = SyncCounterPacer(defaultInterval: 5)
        pacer.report(0, at: start)
        pacer.report(500, at: start.addingTimeInterval(5))
        _ = run(&pacer, seconds: 120)
        #expect(pacer.displayed == 500)
    }

    @Test("It keeps moving every second while behind")
    func alwaysMoving() {
        let start = Date()
        var pacer = SyncCounterPacer(defaultInterval: 20)
        pacer.report(0, at: start)
        pacer.report(500, at: start.addingTimeInterval(20))

        let samples = run(&pacer, seconds: 8)
        // No two consecutive samples may be equal while there's ground to cover;
        // a stalled number is the bug this class exists to fix.
        for (a, b) in zip(samples, samples.dropFirst()) {
            #expect(b > a, "counter stalled: \(samples)")
        }
    }

    @Test("A slow server stretches the step further than a fast one")
    func adaptsToServerSpeed() {
        func displayedAfterOneSecond(interval: Double) -> Int {
            let start = Date()
            var pacer = SyncCounterPacer(defaultInterval: interval)
            pacer.report(0, at: start)
            pacer.report(500, at: start.addingTimeInterval(interval))
            var p = pacer
            return run(&p, seconds: 1).last!
        }
        // The same 500-item page should crawl on a slow server and move briskly
        // on a fast one.
        #expect(displayedAfterOneSecond(interval: 45) < displayedAfterOneSecond(interval: 5))
    }

    @Test("Measured arrivals correct an over-optimistic default")
    func learnsTheInterval() {
        let start = Date()
        var pacer = SyncCounterPacer(defaultInterval: 5)
        pacer.report(0, at: start)
        // Three pages, each 30s apart — a genuinely slow server.
        pacer.report(500, at: start.addingTimeInterval(30))
        pacer.report(1_000, at: start.addingTimeInterval(60))
        pacer.report(1_500, at: start.addingTimeInterval(90))
        #expect(pacer.pageInterval > 15, "should have learned it is slow: \(pacer.pageInterval)")
    }

    @Test("A restart drops back rather than crawling downward")
    func handlesRestart() {
        var pacer = SyncCounterPacer()
        pacer.report(5_000)
        pacer.report(0)
        #expect(pacer.displayed == 0)
    }

    @Test("A finished phase reads exactly")
    func settles() {
        var pacer = SyncCounterPacer(defaultInterval: 30)
        pacer.report(0)
        pacer.report(6_480)
        pacer.settle(at: 6_480)
        #expect(pacer.displayed == 6_480)
    }
}
