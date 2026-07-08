import SwiftUI
import MozzCore
import MozzSubsonic

/// Subsonic/OpenSubsonic sign-in: type a server address, then authenticate
/// with either a username/password (the common case — Mozz derives and
/// stores only a salted MD5 token, never the plaintext password) or a
/// username/API key (OpenSubsonic servers that issue one).
///
/// No server discovery here (unlike Jellyfin's LAN broadcast) — Subsonic/
/// OpenSubsonic has no standard discovery protocol, so this is address entry
/// only, matching how most Subsonic apps work.
struct SubsonicLoginView: View {
    @EnvironmentObject private var env: AppEnvironment

    private enum SignInMode: String, CaseIterable, Identifiable {
        case password = "Password"
        case apiKey = "API Key"
        var id: String { rawValue }
    }

    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var mode: SignInMode = .password
    @State private var status: String?
    @State private var isBusy = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                TextField("navidrome.example.com", text: $serverAddress)
                    .urlFieldStyle()
            } header: {
                Text("Server address")
            } footer: {
                if let baseURL {
                    Text("Will connect to \(baseURL.absoluteString)")
                }
            }

            Section {
                Picker("Sign in with", selection: $mode) {
                    ForEach(SignInMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                TextField("Username", text: $username)
                    .plainTextFieldStyle()
                switch mode {
                case .password:
                    SecureField("Password", text: $password)
                case .apiKey:
                    SecureField("API Key", text: $apiKey)
                }

                Button("Sign In") { signIn() }
                    .disabled(!canSignIn || isBusy)
            } header: {
                Text("Sign in")
            } footer: {
                Text("Works with Navidrome and other OpenSubsonic-compatible servers (Gonic, Ampache, LMS).")
            }

            if let status {
                Section {
                    HStack(spacing: 10) {
                        if isBusy { ProgressView() }
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Subsonic")
        .inlineNavigationTitle()
        .onDisappear { task?.cancel() }
    }

    private var baseURL: URL? {
        SubsonicURLNormalizer.normalize(serverAddress)
    }

    private var canSignIn: Bool {
        guard baseURL != nil, !username.isEmpty else { return false }
        switch mode {
        case .password: return !password.isEmpty
        case .apiKey: return !apiKey.isEmpty
        }
    }

    private func signIn() {
        guard let baseURL else { return }
        let authenticator = SubsonicAuthenticator(baseURL: baseURL, clientIdentifier: env.clientIdentifier)
        isBusy = true
        status = "Signing in\u{2026}"
        task = Task {
            do {
                let session: AuthenticatedSession
                switch mode {
                case .password:
                    session = try await authenticator.authenticate(username: username, password: password)
                case .apiKey:
                    session = try await authenticator.authenticate(username: username, apiKey: apiKey)
                }
                env.activate(session: session)
            } catch is CancellationError {
                // View dismissed.
            } catch {
                status = "Sign-in failed: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }
}
