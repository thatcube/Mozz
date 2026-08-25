import SwiftUI

/// The app's root SwiftUI scene. Builds the composition root once and injects it
/// into the environment, then routes between onboarding and the main UI.
public struct MozzRootScene: Scene {
    @StateObject private var env: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    public init() {
        // The environment is owned by the process, not by this scene — CarPlay can
        // launch the app without this window ever being created, and both scenes
        // must share one database and one playback engine. See `SharedEnvironment`.
        _env = StateObject(wrappedValue: SharedEnvironment.shared)
    }

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .environment(env.playback)
                .environmentObject(env.downloads)
                .environmentObject(env.toasts)
                .task {
                    // Idempotent: if CarPlay already started the session on a cold
                    // start from the car, this awaits that same work instead of
                    // repeating it.
                    await SharedEnvironment.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Returning to the foreground resumes the enrichment crawl so an
                    // already-synced library keeps filling in without a manual sync.
                    // No-op when disabled or already running.
                    if phase == .active {
                        env.resumeEnrichmentIfNeeded()
                        // An idle device has to re-read the shared checkpoint:
                        // another device may have taken over while this one was
                        // asleep, and stale state here would be published over
                        // the newer session on the next write (ADR-0010).
                        env.reconcileContinuity()
                        // Listening history rides the same hook but is rate
                        // limited inside the coordinator — a resume point goes
                        // stale in seconds, a play does not.
                        env.syncHistoryIfDue()
                    }
                    if phase == .background {
                        // Last chance to run — get any pending checkpoint out.
                        env.flushContinuity()
                    }
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
            } else if !env.libraryChoice.isEmpty {
                // Sign-in is parked waiting for a library choice; this takes
                // precedence over the setup screen it interrupts.
                OnboardingLibraryChoiceView()
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
