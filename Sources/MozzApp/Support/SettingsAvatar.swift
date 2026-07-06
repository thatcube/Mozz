import SwiftUI
import MozzPlayback
import MozzDownloads

/// The profile avatar shown at the top-right of each top-level screen. Tapping
/// it opens Settings as a sheet — so Settings doesn't need a bottom tab (which
/// isn't a normal place for it), matching Apple Music / Spotify.
///
/// Self-contained (owns its presentation state) so any screen can drop it into a
/// scrolling header or a toolbar. When the full-screen player is presented it's
/// covered by that overlay, so it naturally disappears "while watching."
struct SettingsAvatar: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var showSettings = false

    var body: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .frame(width: 30, height: 30)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Settings")
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSettings) {
            // Re-inject the same environment objects the root scene provides, so
            // Settings (and its children, e.g. Benchmarks) resolve them even if
            // the sheet doesn't inherit the presenter's environment.
            SettingsView()
                .environmentObject(env)
                .environmentObject(env.playback)
                .environmentObject(env.downloads)
        }
    }
}
