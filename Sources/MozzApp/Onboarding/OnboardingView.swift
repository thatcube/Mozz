import SwiftUI
import MozzCore

/// The sign-in entry point: choose a backend to connect, or launch the offline
/// demo (a synthetic catalog + bundled clip so the whole app works with no
/// server — ideal for the simulator).
struct OnboardingView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var isLoadingDemo = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list").font(.system(size: 56))
                    Text("Mozz").font(.largeTitle.bold())
                    Text("Offline-first music for Plex & Jellyfin")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                Spacer()

                VStack(spacing: 12) {
                    NavigationLink {
                        JellyfinLoginView()
                    } label: {
                        connectLabel(title: "Connect to Jellyfin", systemImage: "server.rack")
                    }
                    NavigationLink {
                        PlexLoginView()
                    } label: {
                        connectLabel(title: "Connect to Plex", systemImage: "play.tv")
                    }
                    NavigationLink {
                        SubsonicLoginView()
                    } label: {
                        connectLabel(title: "Connect to Subsonic", systemImage: "waveform")
                    }

                    Button {
                        Task {
                            isLoadingDemo = true
                            try? await env.activateDemo()
                            isLoadingDemo = false
                        }
                    } label: {
                        HStack {
                            if isLoadingDemo { ProgressView().tint(.white) }
                            connectLabel(title: "Try the offline demo", systemImage: "sparkles")
                        }
                    }
                    .disabled(isLoadingDemo)
                }
                .padding(.horizontal)

                Text("GPL-3.0 · your library stays on your device")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.bottom)
            }
            .padding()
        }
    }

    private func connectLabel(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.accentColor.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
