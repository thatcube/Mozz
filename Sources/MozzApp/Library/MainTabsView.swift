import SwiftUI
import MozzCore
import MozzPlayback

/// The main app shell once a server is active.
///
/// This uses the **native** iOS 26 `TabView` (the floating pill tab bar) plus
/// `tabViewBottomAccessory` for the docked mini-player — the exact API Apple
/// Music uses — so the tab bar matches the system look on the user's device. On
/// iOS 17–25 it falls back to a `safeAreaInset` mini-bar.
///
/// The full-screen player is a *custom* overlay layered above the TabView so we
/// keep full coordinate control over the artwork transition: the artwork grows
/// out of the accessory slot on open, rides the finger 1:1 on drag, and springs
/// back into the accessory slot on release. Coordinates are bridged across the
/// system's accessory-hosting boundary via global-space frames in `PlayerUIModel`.
struct MainTabsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var playback: PlaybackEngine
    @StateObject private var ui = PlayerUIModel()

    private var hasTrack: Bool { playback.currentTrack != nil }

    var body: some View {
        ZStack {
            tabs
            if ui.isFullPresented, playback.currentTrack != nil {
                FullPlayerView(playback: playback, ui: ui) {
                    ui.isFullPresented = false
                }
                .zIndex(100)
            }
        }
        .onChange(of: hasTrack) { _, has in
            // Test hook: auto-open the full player so its layout/transition can be
            // inspected in the Simulator, where no gesture injection is available.
            if has, ProcessInfo.processInfo.environment["MOZZ_AUTOEXPAND"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { ui.isFullPresented = true }
            }
        }
    }

    private var tabs: some View {
        TabView {
            ArtistsView()
                .tabItem { Label("Library", systemImage: "music.note.list") }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .miniAccessory(env: env, playback: playback, ui: ui, hasTrack: hasTrack)
    }
}

private extension View {
    /// Docks the mini-player using the native accessory on iOS 26+, or a
    /// `safeAreaInset` fallback on iOS 17–25 (and on the macOS test host, where
    /// `tabViewBottomAccessory` is unavailable entirely).
    @ViewBuilder
    func miniAccessory(env: AppEnvironment, playback: PlaybackEngine,
                       ui: PlayerUIModel, hasTrack: Bool) -> some View {
        #if os(iOS)
        if #available(iOS 26.1, *) {
            self.tabViewBottomAccessory(isEnabled: hasTrack) {
                MiniPlayerAccessory(playback: playback, ui: ui) { ui.isFullPresented = true }
                    .environmentObject(env)
            }
        } else if #available(iOS 26.0, *) {
            self.tabViewBottomAccessory {
                if hasTrack {
                    MiniPlayerAccessory(playback: playback, ui: ui) { ui.isFullPresented = true }
                        .environmentObject(env)
                }
            }
        } else {
            self.legacyMiniBar(env: env, playback: playback, ui: ui, hasTrack: hasTrack)
        }
        #else
        self.legacyMiniBar(env: env, playback: playback, ui: ui, hasTrack: hasTrack)
        #endif
    }

    /// Pre-iOS-26 fallback: a floating mini-bar pinned above the tab bar. We draw
    /// our own Liquid-Glass-ish material here since the system doesn't.
    @ViewBuilder
    func legacyMiniBar(env: AppEnvironment, playback: PlaybackEngine,
                       ui: PlayerUIModel, hasTrack: Bool) -> some View {
        self.safeAreaInset(edge: .bottom, spacing: 0) {
            if hasTrack {
                MiniPlayerAccessory(playback: playback, ui: ui) { ui.isFullPresented = true }
                    .environmentObject(env)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
    }
}
