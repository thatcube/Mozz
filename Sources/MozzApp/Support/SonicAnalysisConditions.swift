import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// Whether now is a fair moment to analyze somebody's library.
///
/// Analysis is the one background job in the app that is genuinely expensive:
/// every track is a server-side transcode, a download, and a burst of DSP. Run
/// unconditionally it would be a phone that gets hot and a data plan that gets
/// eaten, for a feature whose payoff arrives later. So it runs on the terms a
/// person would set themselves — plugged in, on a network nobody is paying by
/// the megabyte — and stops the moment either lapses.
///
/// The core cannot see any of this: `SonicAnalysisService` takes a closure and
/// asks it before every track. This is that closure, plus the notifications
/// that let the app react the instant a charger is pulled rather than at the
/// end of the current track.
public final class SonicAnalysisConditions: @unchecked Sendable {
    /// UserDefaults key for the Settings switch (default on when unset).
    public static let enabledKey = "mozz.sonicAnalysisEnabled"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.thatcube.mozz.sonic-conditions")
    private let lock = NSLock()
    /// Pessimistic until the monitor and the device tell us otherwise: the cost
    /// of a false "no" is a delayed pass, the cost of a false "yes" is someone's
    /// data allowance.
    private var unmetered = false
    private var powered = false
    private var onChange: (@Sendable () -> Void)?

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // `isExpensive` covers cellular and personal hotspots; `isConstrained`
            // is Low Data Mode, which is the user saying this plainly.
            let ok = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            self.set { $0.unmetered = ok }
        }
        monitor.start(queue: queue)
        startPowerObservation()
    }

    deinit { monitor.cancel() }

    /// Called on every transition, so the app can start a pass when conditions
    /// arrive and cancel one when they leave. Set after construction because the
    /// object that wants the callback is usually the one being constructed.
    public func onConditionsChanged(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        onChange = handler
        lock.unlock()
    }

    /// The gate the analysis service polls.
    public func isSatisfied() -> Bool {
        isEnabled && isPowered && isUnmetered
    }

    /// The Settings switch. Separate from the rest so a screen can say which of
    /// the three is the one saying no.
    public var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    public var isPowered: Bool {
        lock.lock(); defer { lock.unlock() }
        return powered
    }

    public var isUnmetered: Bool {
        lock.lock(); defer { lock.unlock() }
        return unmetered
    }

    /// Re-read the power state now.
    ///
    /// Necessary because the battery notification only fires on a *change*: a
    /// phone that was already on a charger before the app launched never sends
    /// one, so an initial read that missed is an initial read that never gets
    /// corrected. Called on every foreground and before every pass.
    public func refresh() {
        #if canImport(UIKit)
        Task { @MainActor in
            UIDevice.current.isBatteryMonitoringEnabled = true
            self.notePowerState(UIDevice.current.batteryState)
        }
        #endif
    }

    private func set(_ mutate: (SonicAnalysisConditions) -> Void) {
        lock.lock()
        let before = unmetered && powered
        mutate(self)
        let after = unmetered && powered
        let handler = onChange
        lock.unlock()
        if before != after { handler?() }
    }

    // MARK: - Power

    #if canImport(UIKit)
    private func startPowerObservation() {
        Task { @MainActor in
            UIDevice.current.isBatteryMonitoringEnabled = true
            NotificationCenter.default.addObserver(
                forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.notePowerState(UIDevice.current.batteryState)
            }
            // A charger already plugged in when the app launches produces no
            // notification at all, so the first read has to be right — and it
            // is not, read in the same turn that enables monitoring: UIKit
            // answers `.unknown` until the next turn. Hence a second look.
            // This cost an iPhone that sat at "waiting for a charger" while
            // plugged in.
            self.notePowerState(UIDevice.current.batteryState)
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.notePowerState(UIDevice.current.batteryState)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.notePowerState(UIDevice.current.batteryState)
        }
    }

    private func notePowerState(_ state: UIDevice.BatteryState) {
        // `.full` counts: a device sitting at 100% on a charger is still on the
        // charger. `.unknown` does not — that is the simulator, and guessing
        // "yes" there would be guessing "yes" on a real device that failed to
        // report. It is also what UIKit says before battery monitoring has
        // settled, which is why this is called more than once.
        let plugged = state == .charging || state == .full
        set { $0.powered = plugged }
    }
    #else
    private func startPowerObservation() {
        // A desktop is not a device someone carries a charger for.
        set { $0.powered = true }
    }
    #endif
}
