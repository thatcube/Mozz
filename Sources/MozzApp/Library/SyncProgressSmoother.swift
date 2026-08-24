import Foundation
import MozzSync

/// The pacing maths behind the sync counters, kept free of timers and actors so
/// it can be stepped deterministically in tests.
///
/// One of these per phase. It answers a single question: given where the counter
/// is now, where the server says it should be, and how long this phase usually
/// takes to deliver a page, how far should the counter move this tick?
struct SyncCounterPacer {
    /// Where the displayed counter currently sits. Fractional, so a slow phase
    /// (a few items spread over half a minute) still advances instead of
    /// rounding to nothing every tick.
    private(set) var position: Double = 0
    /// The last count the sync actually reported. The counter never passes this.
    private(set) var target: Double = 0

    /// Rolling estimate of the seconds between this phase's page arrivals.
    private(set) var pageInterval: Double
    private var lastArrival: Date?
    private var seeded = false

    /// Aim to take a little longer than the measured gap, so the counter is
    /// usually still climbing when the next page lands rather than parked.
    static let stretch = 1.25
    /// Guard rails, so one freak interval can't freeze the counter or send it
    /// sprinting.
    static let minimumSpread = 4.0
    static let maximumSpread = 60.0
    /// Floor in items/second, so the tail of a step never decays to a standstill.
    static let minimumRate = 0.8

    init(defaultInterval: Double = 15) {
        pageInterval = defaultInterval
    }

    /// How long a whole step should be spread over.
    var spread: Double {
        min(max(pageInterval * Self.stretch, Self.minimumSpread), Self.maximumSpread)
    }

    /// Record a freshly reported count.
    ///
    /// Crucially this is **per phase**. The sync runs its phases concurrently,
    /// so a shared "did anything move" signal fires far more often than any one
    /// phase delivers a page — which made every counter race through its step in
    /// a fraction of the real interval and then sit still.
    mutating func report(_ count: Int, at now: Date = Date()) {
        let value = Double(count)

        // First sight: adopt the value outright rather than counting up to it
        // from zero, which would misrepresent a sync already in progress.
        guard seeded else {
            position = value
            target = value
            lastArrival = now
            seeded = true
            return
        }

        guard value != target else { return }

        if value > target, let last = lastArrival {
            let elapsed = now.timeIntervalSince(last)
            // Ignore absurd gaps — a backgrounded app, a stalled server — so
            // they can't poison the estimate.
            if elapsed > 0.25, elapsed < 300 {
                pageInterval = pageInterval * 0.6 + elapsed * 0.4
            }
        }
        if value > target { lastArrival = now }

        target = value
        // A restart (or a re-scoped library) moves the target backwards; drop to
        // it rather than crawling down.
        if position > target { position = target }
    }

    /// Mark the phase finished: the counter should read exactly, not approach.
    mutating func settle(at count: Int) {
        position = Double(count)
        target = Double(count)
        seeded = true
    }

    /// Advance the counter by `elapsed` seconds. Returns whether there is still
    /// ground to cover.
    @discardableResult
    mutating func advance(by elapsed: Double) -> Bool {
        guard position < target else {
            position = min(position, target)
            return false
        }
        // Recomputed from the *current* remaining gap every tick rather than
        // fixed when the page arrived: a stored rate goes stale the moment
        // anything unexpected happens, and a stale rate of zero is exactly the
        // frozen counter this exists to prevent.
        let gap = target - position
        let rate = max(gap / spread, Self.minimumRate)
        position = min(position + rate * elapsed, target)
        return position < target
    }

    /// The value to show.
    var displayed: Int { Int(position.rounded(.down)) }
}

/// Eases the sync counters toward their real values so the card always looks
/// alive.
///
/// The sync writes in pages (500 items at a time) and a big library on a slow
/// server can take twenty-odd seconds per page, so the raw counts sit still and
/// then leap — which reads as frozen even though nothing is wrong.
///
/// Each phase is paced independently by a ``SyncCounterPacer``, using how long
/// *that* phase actually takes to deliver a page. It stays strictly
/// un-optimistic: the displayed value only ever chases a number the sync has
/// already reported, and is clamped to it, so it can never run ahead of reality.
@MainActor
final class SyncProgressSmoother: ObservableObject {
    @Published private(set) var counts: [SyncProgress.Phase: Int] = [:]
    @Published private(set) var fraction: Double = 0

    private var pacers: [SyncProgress.Phase: SyncCounterPacer] = [:]
    private var fractionPacer = SyncCounterPacer()
    /// The fraction is paced in per-mille, so the integer-flavoured pacer has
    /// enough resolution to move smoothly across a progress bar.
    private static let fractionScale = 1000.0

    private var timer: Timer?
    private let tick = 1.0 / 30.0

    deinit { timer?.invalidate() }

    /// Point the smoother at the latest real progress.
    func update(from progress: SyncProgress?) {
        guard let progress else { return }
        let now = Date()

        for detail in progress.details {
            var pacer = pacers[detail.phase] ?? SyncCounterPacer()
            if detail.state == .done {
                pacer.settle(at: detail.synced)
            } else {
                pacer.report(detail.synced, at: now)
            }
            pacers[detail.phase] = pacer
            if counts[detail.phase] != pacer.displayed {
                counts[detail.phase] = pacer.displayed
            }
        }

        if let total = progress.totalCount, total > 0 {
            let permille = Int((Double(progress.itemsSynced) / Double(total) * Self.fractionScale).rounded())
            fractionPacer.report(min(permille, Int(Self.fractionScale)), at: now)
        }
        start()
    }

    /// Reset between syncs, so a new run doesn't ease *down* from the old one's
    /// numbers.
    func reset() {
        counts = [:]
        pacers = [:]
        fractionPacer = SyncCounterPacer()
        fraction = 0
        stop()
    }

    private func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func step() {
        var moving = false

        for (phase, var pacer) in pacers {
            moving = pacer.advance(by: tick) || moving
            pacers[phase] = pacer
            if counts[phase] != pacer.displayed { counts[phase] = pacer.displayed }
        }

        moving = fractionPacer.advance(by: tick) || moving
        let value = fractionPacer.position / Self.fractionScale
        if abs(fraction - value) > 0.0001 { fraction = value }

        // Caught up — stop burning a timer until the next page lands.
        if !moving { stop() }
    }
}
