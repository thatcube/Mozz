import Foundation
import MozzSync

/// Eases the sync counters toward their real values so the card always looks
/// alive.
///
/// The sync writes in pages (500 items at a time), so the true counts arrive in
/// big steps with long gaps between them — which reads as "frozen" even though
/// the sync is fine.
///
/// The pacing is the whole trick. A fixed easing rate is barely better than the
/// raw numbers on a slow server: it sprints through the 500 in about a second
/// and then sits still for the twenty-odd seconds until the next page lands. So
/// this **measures how long pages actually take on this server** and spreads
/// each step over roughly that long, which keeps the number climbing
/// continuously whatever pace the server sets.
///
/// It stays strictly **un-optimistic**: the displayed value only ever chases a
/// number the sync has already reported, and is clamped to it, so it can never
/// run ahead of reality. If a page lands early the remaining gap grows and the
/// rate is recomputed upward, so it catches up rather than falling behind.
@MainActor
final class SyncProgressSmoother: ObservableObject {
    @Published private(set) var counts: [SyncProgress.Phase: Int] = [:]
    @Published private(set) var fraction: Double = 0

    /// Sub-integer positions, so a slow phase (a handful of items spread over
    /// half a minute) still advances instead of rounding to nothing each tick.
    private var positions: [SyncProgress.Phase: Double] = [:]
    private var rates: [SyncProgress.Phase: Double] = [:]
    private var targetCounts: [SyncProgress.Phase: Int] = [:]

    private var fractionPosition: Double = 0
    private var fractionRate: Double = 0
    private var targetFraction: Double = 0

    /// Rolling estimate of the seconds between page arrivals on this server.
    /// The first real interval corrects the seed.
    private var pageInterval: Double = 6
    private var lastArrival: Date?
    private var timer: Timer?

    private let tick = 1.0 / 30.0
    /// Aim to take slightly *longer* than the measured gap between pages, so the
    /// counter is usually still climbing when the next one lands rather than
    /// parked and waiting for it.
    private let stretch = 1.2
    /// Guard rails, so one freak interval can't freeze the counter for a minute
    /// or send it sprinting.
    private let minimumSpread = 1.5
    private let maximumSpread = 45.0

    deinit { timer?.invalidate() }

    /// Point the smoother at the latest real progress.
    func update(from progress: SyncProgress?) {
        guard let progress else { return }

        // Only a real page arrival should feed the interval estimate — the card
        // re-renders for plenty of other reasons.
        let advanced = progress.details.contains { detail in
            detail.synced > (targetCounts[detail.phase] ?? 0)
        }
        if advanced {
            let now = Date()
            if let last = lastArrival {
                let elapsed = now.timeIntervalSince(last)
                // Ignore absurd gaps (backgrounded app, first paint) so they
                // can't poison the average.
                if elapsed > 0.25, elapsed < 120 {
                    pageInterval = pageInterval * 0.6 + elapsed * 0.4
                }
            }
            lastArrival = now
        }

        let spread = min(max(pageInterval * stretch, minimumSpread), maximumSpread)

        for detail in progress.details {
            let previousTarget = targetCounts[detail.phase]
            targetCounts[detail.phase] = detail.synced

            // Seed on first sight so a phase doesn't count up from zero when the
            // app is reopened mid-sync.
            if positions[detail.phase] == nil {
                positions[detail.phase] = Double(detail.synced)
                counts[detail.phase] = detail.synced
            }
            // A finished phase reads exactly rather than approaching forever.
            if detail.state == .done {
                positions[detail.phase] = Double(detail.synced)
                counts[detail.phase] = detail.synced
                rates[detail.phase] = 0
                continue
            }
            // Re-pace whenever the target moves: spread the *current* remaining
            // gap over roughly one page interval.
            if previousTarget != detail.synced {
                let gap = Double(detail.synced) - (positions[detail.phase] ?? 0)
                rates[detail.phase] = gap > 0 ? gap / spread : 0
            }
        }

        if let total = progress.totalCount, total > 0 {
            let newTarget = min(Double(progress.itemsSynced) / Double(total), 1)
            if newTarget != targetFraction {
                targetFraction = newTarget
                let gap = targetFraction - fractionPosition
                fractionRate = gap > 0 ? gap / spread : 0
            }
        }
        start()
    }

    /// Reset between syncs, so a new run doesn't ease *down* from the old one's
    /// numbers.
    func reset() {
        counts = [:]
        positions = [:]
        rates = [:]
        targetCounts = [:]
        fraction = 0
        fractionPosition = 0
        fractionRate = 0
        targetFraction = 0
        lastArrival = nil
        pageInterval = 6
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

        for (phase, target) in targetCounts {
            let goal = Double(target)
            var position = positions[phase] ?? goal

            if position > goal {
                position = goal                  // a restart; don't crawl downward
            } else if position < goal {
                position = min(position + (rates[phase] ?? 0) * tick, goal)
                // Still short of the target means there is more to show, even if
                // this tick's movement rounded to the same integer.
                moving = moving || position < goal
            }
            positions[phase] = position

            let shown = Int(position.rounded(.down))
            if counts[phase] != shown { counts[phase] = shown }
        }

        if fractionPosition < targetFraction {
            fractionPosition = min(fractionPosition + fractionRate * tick, targetFraction)
            fraction = fractionPosition
            moving = moving || fractionPosition < targetFraction
        } else if fractionPosition > targetFraction {
            fractionPosition = targetFraction
            fraction = fractionPosition
        }

        // Caught up — stop burning a timer until the next page lands.
        if !moving { stop() }
    }
}
