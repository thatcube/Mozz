import SwiftUI
import MozzPlayback

/// The main app shell once a server is active: a tab bar for Library / Search /
/// Downloads / Settings, with the mini-player docked above it whenever audio is
/// loaded. Tapping the mini-player presents the full Now Playing sheet.
struct MainTabsView: View {
    @EnvironmentObject private var playback: PlaybackEngine
    @State private var showNowPlaying = false

    var body: some View {
        TabView {
            ArtistsView()
                .tabItem { Label("Library", systemImage: "music.note.house") }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .safeAreaInset(edge: .bottom) {
            if playback.currentTrack != nil {
                MiniPlayerView(showNowPlaying: $showNowPlaying)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: playback.currentTrack?.id)
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
    }
}
