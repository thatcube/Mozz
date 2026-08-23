#if canImport(UIKit)
import UIKit
#if os(iOS)
import Intents
#endif

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

    #if os(iOS)
    /// One handler, kept for the life of the process: Siri resolves a request and
    /// then handles it as two separate calls, and the handler remembers between
    /// them what it just promised to play.
    private let mediaIntents = MediaIntentHandler()

    /// Route Siri's media requests — from a HomePod, CarPlay, the Siri button or
    /// Shortcuts — into the running app rather than an extension.
    ///
    /// Handling these in-process is what makes background playback work: the audio
    /// session, the queue and the playback engine already live here, so Siri can
    /// start music without the phone being unlocked or the app coming to the
    /// front. An extension would have to hand off to the app anyway, and couldn't
    /// answer as quickly.
    public func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        switch intent {
        case is INPlayMediaIntent, is INAddMediaIntent, is INUpdateMediaAffinityIntent:
            return mediaIntents
        default:
            return nil
        }
    }
    #endif
}
#endif
