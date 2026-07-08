import SwiftUI

/// The app's root SwiftUI scene. Builds the composition root once and injects it
/// into the environment, then routes between onboarding and the main UI.
public struct MozzRootScene: Scene {
    @StateObject private var env: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

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
                .onChange(of: scenePhase) { _, phase in
                    // Returning to the foreground resumes the enrichment crawl so an
                    // already-synced library keeps filling in without a manual sync.
                    // No-op when disabled or already running.
                    if phase == .active { env.resumeEnrichmentIfNeeded() }
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
            } else if env.isSettingUp {
                SetupView()
            } else if env.active == nil {
                OnboardingView()
            } else {
                MainTabsView()
            }
        }
        .animation(.default, value: env.active == nil)
        .animation(.default, value: env.isRestoring)
        .animation(.default, value: env.isSettingUp)
        .onOpenURL { url in
            env.handle(url: url)
        }
        .onContinueUserActivity(DeepLinkTarget.albumActivity) { env.handleHandoff(activityType: $0.activityType, userInfo: $0.userInfo) }
        .onContinueUserActivity(DeepLinkTarget.artistActivity) { env.handleHandoff(activityType: $0.activityType, userInfo: $0.userInfo) }
        .onContinueUserActivity(DeepLinkTarget.playlistActivity) { env.handleHandoff(activityType: $0.activityType, userInfo: $0.userInfo) }
        .onContinueUserActivity(DeepLinkTarget.genreActivity) { env.handleHandoff(activityType: $0.activityType, userInfo: $0.userInfo) }
        .onContinueUserActivity(DeepLinkTarget.libraryActivity) { env.handleHandoff(activityType: $0.activityType, userInfo: $0.userInfo) }
    }
}

struct SplashView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image("MozzLogo")
                .interpolation(.none) // preserve crisp pixel-art edges
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
            ProgressView()
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("SplashBackground").ignoresSafeArea())
    }
}
