import SwiftUI
import MozzApp

/// Thin app entry point. All real composition lives in the `MozzApp` package
/// module (`MozzRootScene`), so the executable target stays a shell and the
/// feature layer remains a testable library.
@main
struct MozzMain: App {
    @UIApplicationDelegateAdaptor(MozzAppDelegate.self) private var appDelegate

    var body: some Scene {
        MozzRootScene()
    }
}
