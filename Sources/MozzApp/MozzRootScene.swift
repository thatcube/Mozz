import SwiftUI

/// The app's root SwiftUI scene. Kept in the package (not the executable target)
/// so the composition root is a testable library. The real feature UI is wired
/// in during the app/UI phase; this compiles cleanly on both iOS and the macOS
/// host used for fast unit testing.
public struct MozzRootScene: Scene {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            MozzRootView()
        }
    }
}

/// Placeholder root view, replaced by the composed feature UI during the
/// app/UI phase.
public struct MozzRootView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
            Text("Mozz")
                .font(.largeTitle.bold())
            Text("Offline-first music for Plex & Jellyfin")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
