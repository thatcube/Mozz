import SwiftUI
import MozzCore
import MozzPlex

/// Plex sign-in via the PIN/link flow: request a short code, the user enters it
/// at plex.tv/link (we offer a button that opens it), we poll until it's
/// claimed, then discover the account's servers and pin the fastest reachable
/// address.
struct PlexLoginView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var code: String?
    @State private var linkURL: URL?
    @State private var status: String?
    @State private var isBusy = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                if let code {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. Open plex.tv/link").font(.footnote).foregroundStyle(.secondary)
                        Text("2. Enter this code:").font(.footnote).foregroundStyle(.secondary)
                        Text(code).font(.system(.largeTitle, design: .monospaced).bold())
                        if let linkURL {
                            Button("Open plex.tv/link") { openURL(linkURL) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    Button("Start Plex sign-in") { start() }
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
        status = "Requesting a link code…"
        task = Task {
            do {
                let pin = try await auth.requestPin()
                code = pin.code
                linkURL = pin.authAppURL(clientInfo: env.clientInfo)
                status = "Waiting for you to link at plex.tv/link…"
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
