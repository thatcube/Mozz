import SwiftUI
import MozzCore
import MozzSync

/// Shown after sign-in while the environment finishes setting up the server and
/// runs the first catalog sync. Setup is owned by `AppEnvironment`, so this
/// screen is purely a status view — leaving it can't cancel anything. As soon as
/// there's playable content the user can jump straight into the app; the sync
/// keeps running in the background.
struct SetupView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: "music.note.house.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text(env.setupError == nil ? "Setting up your library" : "Setup hit a snag")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            if env.setupError == nil {
                progress
            }

            Spacer()

            if env.setupError != nil {
                Button("Back to sign in") { env.signOut() }
                    .buttonStyle(.borderedProminent)
            } else if env.canEnterEarly {
                Button {
                    env.enterAppNow()
                } label: {
                    Text("Browse now").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 40)
                Text("Your library keeps syncing in the background.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder private var progress: some View {
        VStack(spacing: 10) {
            if let p = env.syncProgress {
                if let total = p.totalCount, total > 0 {
                    ProgressView(value: Double(min(p.itemsSynced, total)), total: Double(total))
                        .frame(maxWidth: 260)
                } else {
                    ProgressView().controlSize(.large)
                }
                Text(phaseLabel(p))
                    .font(.footnote).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            } else {
                ProgressView().controlSize(.large)
                Text(env.syncStatusText ?? "Connecting…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        if let error = env.setupError { return error }
        return "This can take a moment on first sign-in — larger libraries take longer."
    }

    private func phaseLabel(_ p: SyncProgress) -> String {
        let name: String
        switch p.phase {
        case .capabilities: name = "Checking server"
        case .artists:      name = "Artists"
        case .albums:       name = "Albums"
        case .tracks:       name = "Songs"
        case .playlists:    name = "Playlists"
        case .pruning:      name = "Finishing up"
        case .done:         name = "Done"
        }
        if let total = p.totalCount, total > 0 {
            return "\(name) — \(p.itemsSynced) of \(total)"
        }
        return p.itemsSynced > 0 ? "\(name) — \(p.itemsSynced)" : name
    }
}
