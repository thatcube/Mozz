import SwiftUI
import MozzCore
import MozzPlayback

/// The main app shell once a server is active.
///
/// **Candidate B** drops the native `tabViewBottomAccessory` and renders the
/// now-playing surface as a single custom overlay — `NowPlayingMorphContainer` —
/// layered above the `TabView`. That container is BOTH the docked Liquid Glass
/// island and the full-screen drawer: it morphs between them in one hierarchy,
/// so the collapse clips, bounces and settles into glass without any cross-layer
/// hand-off. The tab bar itself is still the native floating pill (Home / Library
/// / Search; Settings lives behind the avatar in each tab's header).
///
/// Because the island no longer participates in the tab bar's own layout, each
/// tab reserves a little extra bottom space so scrolled content clears the
/// floating island (`reserveIslandSpace`).
struct MainTabsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var playback: PlaybackEngine
    @StateObject private var ui = PlayerUIModel()

    private var hasTrack: Bool { playback.currentTrack != nil }

    var body: some View {
        ZStack {
            tabs
            if hasTrack {
                NowPlayingMorphContainer(playback: playback, ui: ui)
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
            HomeView().reserveIslandSpace(hasTrack)
                .tabItem { Label("Home", systemImage: "house") }
            LibraryHomeView().reserveIslandSpace(hasTrack)
                .tabItem { Label("Library", systemImage: "music.note.list") }
            SearchView().reserveIslandSpace(hasTrack)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
    }
}

private extension View {
    /// Reserves bottom safe-area space for the floating island so a tab's
    /// scrolled content isn't hidden behind it (island height + gap ≈ 64pt).
    /// The native accessory used to do this for us; a custom overlay does not.
    @ViewBuilder
    func reserveIslandSpace(_ hasTrack: Bool) -> some View {
        self.safeAreaInset(edge: .bottom, spacing: 0) {
            if hasTrack { Color.clear.frame(height: 64) }
        }
    }
}
