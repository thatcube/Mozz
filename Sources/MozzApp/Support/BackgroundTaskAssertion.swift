import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Keeps a long-running job (the catalog sync) alive when the user backgrounds
/// the app. iOS suspends an app a few seconds after it leaves the foreground
/// unless it holds a background-task assertion; this requests extra running time
/// and releases it when the work ends.
///
/// A no-op where UIKit is unavailable (macOS host tests). Not infinite — iOS
/// grants minutes, then fires the expiration handler; we end cleanly so the app
/// isn't killed, and the sync resumes from the persisted catalog on next launch.
///
/// All state lives on the main actor (a single owner), so begin/end/expire can't
/// race or double-end the identifier.
@MainActor
final class BackgroundTaskAssertion {
    #if canImport(UIKit)
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(name: String) {
        #if canImport(UIKit)
        taskID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()   // iOS is out of patience — release so we aren't killed.
        }
        #endif
    }

    func end() {
        #if canImport(UIKit)
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
        #endif
    }
}
