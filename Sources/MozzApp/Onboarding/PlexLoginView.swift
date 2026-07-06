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

    @State private var linkURL: URL?
    @State private var status: String?
    @State private var isBusy = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                if let linkURL {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Authorize Mozz in Plex, then return here — this screen finishes automatically.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Open Plex to Sign In") { openURL(linkURL) }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button("Sign in with Plex") { start() }
                        .disabled(isBusy)
                }
            }

            if let status {
                Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Plex")
        .inlineNavigationTitle()
        .onDisappear { task?.cancel() }
    }

    private func start() {
        let auth = PlexAuthenticator(clientInfo: env.clientInfo, clientIdentifier: env.clientIdentifier)
        isBusy = true
        status = "Requesting sign-in…"
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
                status = "Finding your servers…"
                let session = try await auth.completeLogin(accountToken: token)
                try await env.activate(session: session)
                dismiss()
            } catch is CancellationError {
                // Dismissed.
            } catch {
                status = "Plex sign-in failed: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }
}
