import SwiftUI
import MozzPlayback
import MozzDownloads

/// The profile avatar shown at the top-right of each top-level screen. Tapping
/// it opens Settings as a sheet — so Settings doesn't need a bottom tab (which
/// isn't a normal place for it), matching Apple Music / Spotify.
///
/// Shows the user's own profile photo from the server when there is one (Plex's
/// account avatar, a Jellyfin profile image); otherwise the generic person icon.
/// The photo is loaded through the shared artwork cache, so it's fetched once
/// and renders on the first frame everywhere else it appears.
///
/// Self-contained (owns its presentation state) so any screen can drop it into a
/// scrolling header or a toolbar. When the full-screen player is presented it's
/// covered by that overlay, so it naturally disappears "while watching."
struct SettingsAvatar: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var showSettings = false

    private static let side: CGFloat = 30

    var body: some View {
        Button {
            showSettings = true
        } label: {
            Group {
                if let url = env.userAvatarURL {
                    CachedArtworkImage(url: url) { icon }
                        .frame(width: Self.side, height: Self.side)
                        .clipShape(Circle())
                } else {
                    icon
                }
            }
            .accessibilityLabel("Settings")
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSettings) {
            // Re-inject the same environment objects the root scene provides, so
            // Settings (and its children, e.g. Benchmarks) resolve them even if
            // the sheet doesn't inherit the presenter's environment.
            SettingsView()
                .environmentObject(env)
                .environment(env.playback)
                .environmentObject(env.downloads)
        }
    }

    /// The fallback (and the placeholder while a photo loads).
    private var icon: some View {
        Image(mozz: "person.crop.circle.fill")
            .resizable()
            .frame(width: Self.side, height: Self.side)
            .foregroundStyle(.secondary)
    }
}
