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
                    Image("MozzLogo")
                        .interpolation(.none) // preserve crisp pixel-art edges
                        .resizable()
                        .scaledToFit()
                        .frame(width: 112, height: 112)
                    Text("Mozz").font(.largeTitle.bold())
                    Text("Offline-first music for Plex, Jellyfin & Navidrome")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                VStack(spacing: 12) {
                    NavigationLink {
                        JellyfinLoginView()
                    } label: {
                        connectLabel(title: "Jellyfin", systemImage: "server.rack",
                                     colors: Self.jellyfinColors, logo: "JellyfinLogo")
                    }
                    NavigationLink {
                        PlexLoginView()
                    } label: {
                        connectLabel(title: "Plex", systemImage: "play.tv",
                                     colors: Self.plexColors, logo: "PlexLogo", logoSize: 26)
                    }
                    NavigationLink {
                        SubsonicLoginView()
                    } label: {
                        connectLabel(title: "Navidrome (Subsonic)", systemImage: "waveform",
                                     colors: Self.navidromeColors, logo: "NavidromeLogo")
                    }

                    #if targetEnvironment(simulator)
                    // Simulator only: the offline demo (synthetic catalog +
                    // bundled clip) — useful because the sim can't reach a real
                    // server. Hidden on device builds (incl. Debug) so it's not
                    // in the way for real use.
                    Button {
                        Task {
                            isLoadingDemo = true
                            try? await env.activateDemo()
                            isLoadingDemo = false
                        }
                    } label: {
                        connectLabel(title: "Try the offline demo", systemImage: "sparkles",
                                     colors: Self.demoColors, isLoading: isLoadingDemo)
                    }
                    .disabled(isLoadingDemo)
                    #endif
                }
                .tint(Color.primary)
                .padding(.horizontal)

                Text("GPL-3.0 · your library stays on your device")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.bottom)
            }
            .padding()
        }
    }

    /// A "connect" row with a brand-colored icon chip. We deliberately use each
    /// service's signature COLOR with a neutral SF Symbol rather than embedding
    /// the official Plex/Jellyfin/Navidrome logos (those are trademarked assets);
    /// the color carries the recognition and nothing is reproduced.
    private func connectLabel(
        title: String,
        systemImage: String,
        colors: [Color],
        logo: String? = nil,
        logoSize: CGFloat = 20,
        isLoading: Bool = false
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                if isLoading {
                    ProgressView().tint(.white)
                } else if let logo {
                    // Official brand logo (a monochrome template SVG in the module
                    // asset catalog), tinted white to sit on the colored chip.
                    Image(logo, bundle: .module)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: logoSize, height: logoSize)
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer()
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // Brand signature colors (a gradient per service) for the icon chips.
    private static let jellyfinColors = [
        Color(red: 0.667, green: 0.361, blue: 0.765),   // #AA5CC3 purple
        Color(red: 0.0,   green: 0.643, blue: 0.863),   // #00A4DC blue
    ]
    private static let plexColors = [
        Color(red: 0.898, green: 0.627, blue: 0.051),   // #E5A00D gold
        Color(red: 0.808, green: 0.451, blue: 0.086),   // #CE7316 amber
    ]
    private static let navidromeColors = [
        Color(red: 0.180, green: 0.545, blue: 0.965),   // #2E8BF6 blue
        Color(red: 0.094, green: 0.388, blue: 0.863),   // #1863DC deep blue
    ]
    private static let demoColors = [
        Color(.systemGray), Color(.systemGray2),
    ]
}
