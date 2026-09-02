import Foundation
#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
import UIKit

/// Analysis that keeps going when the app does not.
///
/// A library is hours of work, and nobody keeps a music app open for hours —
/// so while this only ran in the foreground it was never going to finish.
///
/// `BGProcessingTask` is the right shape for it rather than a workaround:
/// iOS runs these when the device is charging and idle, which is the same
/// bargain the foreground path already makes, and it hands the app a real
/// slice of time rather than the thirty seconds a refresh task gets. The
/// system decides when — there is no way to insist, and asking for one is a
/// request, not a schedule.
///
/// The pass itself is unchanged. It stores each vector as it goes, so being
/// stopped mid-library costs one track: `expirationHandler` cancels, and the
/// next window picks up from the rows already written.
public enum SonicAnalysisBackgroundTask {
    public static let identifier = "com.thatcube.Mozz.sonic-analysis"

    /// Register before the app finishes launching, which is what
    /// `BGTaskScheduler` requires — a late registration traps.
    public static func register(analyze: @escaping @Sendable (BGTask) -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            analyze(task)
        }
    }

    /// Ask for a window. Cheap and idempotent — submitting again replaces the
    /// pending request rather than queueing a second one.
    public static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        // Not "in an hour" — a hint. iOS will not run it sooner, and may run it
        // considerably later depending on how the device is being used.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulators refuse to schedule these, and a device with background
            // refresh switched off refuses too. Neither is worth a crash: the
            // foreground path still works, it just does not run unattended.
        }
    }
}
#endif
