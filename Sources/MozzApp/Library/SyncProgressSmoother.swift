import Foundation
import MozzSync

/// Eases the sync counters toward their real values so the card always looks
/// alive.
///
/// The sync writes in pages (500 items at a time), so the true counts arrive in
/// big steps with long gaps between them — which reads as "frozen" even though
/// the sync is fine. This walks the displayed numbers up to each new target
/// instead of snapping, so there is always motion.
///
/// It is deliberately **never optimistic**: the displayed value only ever chases
/// a number the sync has actually reported, so it can't run ahead and then stall
/// waiting for reality to catch up. When a big step lands it closes most of the
/// gap quickly, then eases in — fast when there's ground to make up, still
/// moving when there isn't.
@MainActor
final class SyncProgressSmoother: ObservableObject {
    @Published private(set) var counts: [SyncProgress.Phase: Int] = [:]
    @Published private(set) var fraction: Double = 0

    private var targetCounts: [SyncProgress.Phase: Int] = [:]
    private var targetFraction: Double = 0
    private var timer: Timer?

    /// Fraction of the remaining gap closed each tick. At 30fps this covers most
    /// of a 500-item step in about a second — brisk, but still visibly counting
    /// rather than snapping.
    private let approach = 0.08
    private let tick = 1.0 / 30.0

    deinit { timer?.invalidate() }

    /// Point the smoother at the latest real progress.
    func update(from progress: SyncProgress?) {
        guard let progress else { return }
        for detail in progress.details {
            targetCounts[detail.phase] = detail.synced
            // A finished phase should read exactly, not approach forever.
            if detail.state == .done { counts[detail.phase] = detail.synced }
            // Seed on first sight so a phase doesn't count up from zero after
            // the app was reopened mid-sync.
            if counts[detail.phase] == nil { counts[detail.phase] = detail.synced }
        }
        if let total = progress.totalCount, total > 0 {
            targetFraction = min(Double(progress.itemsSynced) / Double(total), 1)
        }
        start()
    }

    /// Reset between syncs, so a new run doesn't ease *down* from the old one's
    /// numbers.
    func reset() {
        counts = [:]
        targetCounts = [:]
        fraction = 0
        targetFraction = 0
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
        var moved = false

        for (phase, target) in targetCounts {
            let current = counts[phase] ?? 0
            guard current != target else { continue }
            if current > target {
                counts[phase] = target        // a restart; don't crawl downward
            } else {
                let gap = target - current
                // At least one per tick, so a small gap still ticks over instead
                // of rounding to a standstill just short of the target.
                let stride = max(1, Int((Double(gap) * approach).rounded(.up)))
                counts[phase] = min(current + stride, target)
            }
            moved = true
        }

        if abs(fraction - targetFraction) > 0.0005 {
            if fraction > targetFraction {
                fraction = targetFraction
            } else {
                let gap = targetFraction - fraction
                fraction = min(fraction + max(0.001, gap * approach), targetFraction)
            }
            moved = true
        }

        // Nothing left to animate — stop burning a timer until the next page
        // lands.
        if !moved { stop() }
    }
}
