import SwiftUI
import MozzCore
import MozzJellyfin

/// Jellyfin sign-in: enter the server URL, then either use **Quick Connect**
/// (approve a code in an existing Jellyfin session) or username/password.
struct JellyfinLoginView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var quickConnectCode: String?
    @State private var status: String?
    @State private var isBusy = false
    @State private var quickConnectTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Server") {
                TextField("http://192.168.1.10:8096", text: $serverURL)
                    .urlFieldStyle()
            }

            Section("Quick Connect") {
                if let code = quickConnectCode {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Enter this code in Jellyfin ▸ Quick Connect:")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(code).font(.system(.title, design: .monospaced).bold())
                    }
                } else {
                    Button("Start Quick Connect") { startQuickConnect() }
                        .disabled(baseURL == nil || isBusy)
                }
            }

            Section("Or sign in") {
                TextField("Username", text: $username)
                    .plainTextFieldStyle()
                SecureField("Password", text: $password)
                Button("Sign In") { signInWithPassword() }
                    .disabled(baseURL == nil || username.isEmpty || isBusy)
            }

            if let status {
                Section { Text(status).foregroundStyle(.secondary).font(.footnote) }
            }
        }
        .navigationTitle("Jellyfin")
        .inlineNavigationTitle()
        .onDisappear { quickConnectTask?.cancel() }
    }

    private var baseURL: URL? {
        URL(string: serverURL.trimmingCharacters(in: .whitespaces))
    }

    private func authenticator() -> JellyfinAuthenticator? {
        guard let baseURL else { return nil }
        return JellyfinAuthenticator(
            baseURL: baseURL, clientInfo: env.clientInfo, clientIdentifier: env.clientIdentifier
        )
    }

    private func startQuickConnect() {
        guard let auth = authenticator() else { return }
        isBusy = true
        status = "Requesting code…"
        quickConnectTask = Task {
            do {
                let session = try await auth.initiateQuickConnect()
                quickConnectCode = session.code
                status = "Waiting for approval…"
                let result = try await auth.awaitQuickConnect(session, timeout: 300)
                try await env.activate(session: result)
                dismiss()
            } catch is CancellationError {
                // View dismissed.
            } catch {
                status = "Quick Connect failed: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    private func signInWithPassword() {
        guard let auth = authenticator() else { return }
        isBusy = true
        status = "Signing in…"
        Task {
            do {
                let result = try await auth.authenticate(username: username, password: password)
                try await env.activate(session: result)
                dismiss()
            } catch {
                status = "Sign-in failed: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }
}
