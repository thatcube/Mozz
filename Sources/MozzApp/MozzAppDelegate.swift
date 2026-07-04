#if canImport(UIKit)
import UIKit

/// UIKit application delegate hook. iOS-only; the executable target attaches it
/// via `@UIApplicationDelegateAdaptor`. Reserved for process-lifetime concerns
/// that SwiftUI's `App` lifecycle does not cover cleanly (e.g. re-binding a
/// URLSession background-download completion handler on relaunch).
public final class MozzAppDelegate: NSObject, UIApplicationDelegate {
    /// Stored so the downloads subsystem can invoke it once background transfers
    /// have been fully delivered after an out-of-process relaunch.
    public static var backgroundSessionCompletionHandler: (() -> Void)?

    public func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        MozzAppDelegate.backgroundSessionCompletionHandler = completionHandler
    }
}
#endif
