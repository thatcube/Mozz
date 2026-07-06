import SwiftUI

/// The app's root SwiftUI scene. Builds the composition root once and injects it
/// into the environment, then routes between onboarding and the main UI.
public struct MozzRootScene: Scene {
    @StateObject private var env: AppEnvironment

    public init() {
        // Fall back to an in-memory environment if the on-disk one can't open,
        // so the app always launches.
        let environment = (try? AppEnvironment.makeDefault()) ?? AppEnvironment.makeInMemoryFallback()
        _env = StateObject(wrappedValue: environment)
    }

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .environmentObject(env.playback)
                .environmentObject(env.downloads)
                .task {
                    await env.restoreSession()
                    await env.runLaunchAutomationIfNeeded()
                }
        }
    }
}

/// Switches between the restore splash, onboarding, and the main tabbed UI.
struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Group {
            if env.isRestoring {
                SplashView()
            } else if env.active == nil {
                OnboardingView()
            } else {
                MainTabsView()
            }
        }
        .animation(.default, value: env.active == nil)
        .animation(.default, value: env.isRestoring)
    }
}

struct SplashView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list").font(.system(size: 44))
            ProgressView()
        }
        .foregroundStyle(.secondary)
    }
}
