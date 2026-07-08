import SwiftUI
import MozzCore
import MozzSubsonic

/// Subsonic / OpenSubsonic sign-in. The user enters a server address, a
/// username, and either a password (turned into a stable MD5 token — the
/// password is discarded) or an OpenSubsonic API key. Discovery isn't part of
/// the Subsonic protocol, so this is a plain manual form.
struct SubsonicLoginView: View {
    @EnvironmentObject private var env: AppEnvironment

    private enum Method: String, CaseIterable, Identifiable {
        case password = "Password"
        case apiKey = "API Key"
        var id: String { rawValue }
    }

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var method: Method = .password
    @State private var status: String?
    @State private var isBusy = false

    var body: some View {
        Form {
            Section {
                BrandHero(brand: .navidrome)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)

            Section {
                TextField("https://music.example.com", text: $serverURL)
                    .urlFieldStyle()
                    .accessibilityLabel("Server address")
                    .accessibilityHint("For example, https://music.example.com")
            } header: {
                Text("Server address")
            } footer: {
                if let baseURL {
                    Text("Will connect to \(baseURL.absoluteString)")
                } else {
                    Text("Works with Navidrome and other Subsonic-compatible servers (Gonic, Ampache, LMS…).")
                }
            }

            Section {
                TextField("Username", text: $username)
                    .plainTextFieldStyle()
                    .usernameContentType()
                    .accessibilityLabel("Username")
                Picker("Sign in with", selection: $method) {
                    ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch method {
                case .password:
                    SecureField("Password", text: $password)
                        .passwordContentType()
                        .accessibilityLabel("Password")
                case .apiKey:
                    SecureField("API key", text: $apiKey)
                        .accessibilityLabel("API key")
                }
            } header: {
                Text("Sign in to \(targetName)")
            } footer: {
                if method == .apiKey {
                    Text("Uses OpenSubsonic API-key authentication. Requires a server that supports it (e.g. Navidrome).")
                } else {
                    Text("Your password is turned into a token on this device and never stored in plain text.")
                }
            }

            if let status {
                Section { Text(status).foregroundStyle(.secondary).font(.footnote) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            SignInBar(title: "Sign In", isBusy: isBusy, isEnabled: canSubmit) { signIn() }
        }
        .navigationTitle("Navidrome")
        .inlineNavigationTitle()
    }

    // MARK: Derived state

    private var baseURL: URL? {
        SubsonicURLNormalizer.normalize(serverURL)
    }

    private var targetName: String {
        baseURL?.host ?? "server"
    }

    private var canSubmit: Bool {
        guard baseURL != nil, !username.isEmpty else { return false }
        switch method {
        case .password: return !password.isEmpty
        case .apiKey: return !apiKey.isEmpty
        }
    }

    // MARK: Actions

    private func signIn() {
        guard let baseURL else { return }
        let auth = SubsonicAuthenticator(
            baseURL: baseURL,
            clientInfo: env.clientInfo,
            clientIdentifier: env.clientIdentifier
        )
        isBusy = true
        status = LocalNetworkPermission.isLocalHost(baseURL)
            ? "Signing in\u{2026} If iOS asks, allow local network access."
            : "Signing in\u{2026}"
        Task {
            do {
                let session: AuthenticatedSession
                switch method {
                case .password:
                    session = try await auth.authenticate(username: username, password: password)
                case .apiKey:
                    session = try await auth.authenticate(username: username, apiKey: apiKey)
                }
                env.activate(session: session)
            } catch {
                status = "Sign-in failed: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }
}
