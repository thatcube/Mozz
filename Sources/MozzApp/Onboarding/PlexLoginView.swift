import SwiftUI
import MozzCore
import MozzPlex

/// Plex sign-in via the hosted OAuth flow: request a (strong) link PIN, send the
/// user to app.plex.tv to authorize, poll until it's claimed, then discover the
/// account's servers and pin the fastest reachable address. The PIN is a long
/// token used only by the hosted page (not typed manually), so this offers a
/// single "Sign in with Plex" action.
struct PlexLoginView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private enum Phase { case idle, awaitingAuthorization, completing }
    @State private var phase: Phase = .idle
    @State private var linkURL: URL?
    @State private var status: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                switch phase {
                case .idle:
                    Button("Sign in with Plex") { start() }
                case .awaitingAuthorization:
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Authorize Mozz in Plex, then return here — this screen finishes automatically.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let linkURL {
                            Button("Open Plex to Sign In") { openURL(linkURL) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                case .completing:
                    Label("Signed in", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                }
            }

            if let status {
                Section {
                    HStack(spacing: 10) {
                        if phase != .idle { ProgressView() }
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Plex")
        .inlineNavigationTitle()
        .onDisappear { task?.cancel() }
    }

    private func start() {
        let auth = PlexAuthenticator(clientInfo: env.clientInfo, clientIdentifier: env.clientIdentifier)
        phase = .awaitingAuthorization
        status = "Opening Plex…"
        task = Task {
            do {
                let pin = try await auth.requestPin()
                let url = pin.authAppURL(clientInfo: env.clientInfo)
                linkURL = url
                // Send the user straight to Plex; the button remains as a fallback
                // if the system declined to open it automatically.
                if let url { openURL(url) }
                status = "Waiting for you to authorize in Plex…"
                let token = try await auth.awaitPin(pin, timeout: 300)
                // Authorized — show a success cue while we finish setup (server
                // discovery probes each server for music, so this can take a few
                // seconds on multi-server accounts).
                phase = .completing
                status = "Finding your servers…"
                let session = try await auth.completeLogin(accountToken: token)
                status = "Setting up your library…"
                try await env.activate(session: session)
                dismiss()
            } catch is CancellationError {
                // Dismissed.
            } catch {
                phase = .idle
                linkURL = nil
                status = "Plex sign-in failed: \(error.localizedDescription)"
            }
        }
    }
}
