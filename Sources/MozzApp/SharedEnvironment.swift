import Foundation

/// The one ``AppEnvironment`` for the process, shared by every scene.
///
/// The app used to create its environment inside the SwiftUI scene, as a
/// `@StateObject` on `MozzRootScene`. That is the ordinary way to do it and it
/// works perfectly — right up until a second scene exists.
///
/// CarPlay can launch the app on its own: you get in the car, the head unit
/// connects, and the CarPlay scene is created **without** the phone's window
/// scene ever being built. An environment owned by the window scene therefore
/// wouldn't exist at all, so CarPlay would have no database, no playback engine
/// and no restored session — the app would appear on the dashboard and then be
/// empty. Worse, if the user later unlocked their phone, the window scene would
/// build a *second*, independent environment: two SQLite handles, two playback
/// engines, and a UI that disagrees with the car.
///
/// So ownership moves here. Both scenes ask for the same instance, it is built
/// at most once, and the session is restored at most once no matter which scene
/// gets there first.
@MainActor
enum SharedEnvironment {
    private static var instance: AppEnvironment?
    private static var startTask: Task<Void, Never>?

    /// The process-wide environment, created on first use.
    ///
    /// Falls back to an in-memory environment if the on-disk store can't open, so
    /// the app — and the car — always come up with *something* rather than
    /// failing to launch.
    static var shared: AppEnvironment {
        if let instance { return instance }
        let environment = (try? AppEnvironment.makeDefault()) ?? AppEnvironment.makeInMemoryFallback()
        instance = environment
        return environment
    }

    /// Restore the saved session and run launch automation, exactly once per
    /// process however many scenes ask.
    ///
    /// Both the phone window and the CarPlay scene call this on connect: whichever
    /// arrives first does the work and the other awaits the same task, so a
    /// CarPlay cold start is fully signed in and ready rather than racing the
    /// window scene for the same restore.
    static func start() async {
        let environment = shared
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { @MainActor in
            await environment.restoreSession()
            await environment.runLaunchAutomationIfNeeded()
            // Deliberately not awaited: a Siri request waits on `start()` before it
            // can play anything, and refreshing what the system knows about the
            // library must never sit in front of the music.
            Task { await environment.refreshSiriMediaContext() }
        }
        startTask = task
        await task.value
    }
}
