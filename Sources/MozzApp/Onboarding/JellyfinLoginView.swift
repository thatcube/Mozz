import SwiftUI
import MozzCore
import MozzJellyfin

/// Jellyfin sign-in: pick a server found on your network (or type its URL),
/// then either use **Quick Connect** (approve a code in an existing Jellyfin
/// session) or username/password.
struct JellyfinLoginView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var quickConnectCode: String?
    @State private var status: String?
    @State private var isBusy = false
    @State private var quickConnectTask: Task<Void, Never>?

    @State private var discovered: [DiscoveredServer] = []
    @State private var isDiscovering = false

    var body: some View {
        Form {
            discoverySection

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
        .task { await runDiscovery() }
        .onDisappear { quickConnectTask?.cancel() }
    }

    // MARK: Discovery UI

    @ViewBuilder private var discoverySection: some View {
        Section {
            if discovered.isEmpty {
                HStack(spacing: 8) {
                    if isDiscovering {
                        ProgressView()
                        Text("Searching your network…").foregroundStyle(.secondary)
                    } else {
                        Text("No servers found on this network.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Search again") { Task { await runDiscovery() } }
                    }
                }
                .font(.footnote)
            } else {
                ForEach(discovered) { server in
                    Button { select(server) } label: {
                        HStack {
                            Image(systemName: "server.rack").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).foregroundStyle(.primary)
                                Text(server.baseURL.absoluteString)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if serverURL == server.baseURL.absoluteString {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Found on your network")
                if isDiscovering && !discovered.isEmpty {
                    Spacer(); ProgressView().controlSize(.small)
                }
            }
        }
    }

    private func select(_ server: DiscoveredServer) {
        serverURL = server.baseURL.absoluteString
        // Switching servers invalidates any in-flight Quick Connect code.
        quickConnectTask?.cancel()
        quickConnectCode = nil
        status = nil
    }

    private func runDiscovery() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        let discovery = JellyfinServerDiscovery()
        for await server in discovery.discover(timeout: 5) {
            if let idx = discovered.firstIndex(where: { $0.id == server.id }) {
                discovered[idx] = server
            } else {
                discovered.append(server)
            }
            // Prefill the field with the first server found, if the user hasn't
            // typed or picked anything yet, so a one-server LAN is one tap away.
            if serverURL.isEmpty { serverURL = server.baseURL.absoluteString }
        }
    }

    private var baseURL: URL? {
        JellyfinURLNormalizer.normalize(serverURL)
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
                env.activate(session: result)
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
                env.activate(session: result)
            } catch {
                status = "Sign-in failed: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }
}
