import SwiftUI
import MozzCore
import MozzJellyfin

/// Jellyfin sign-in: pick a server found on your network (or type its URL),
/// then either use **Quick Connect** (approve a code in an existing Jellyfin
/// session) or username/password.
struct JellyfinLoginView: View {
    @EnvironmentObject private var env: AppEnvironment

    /// A server the user picked from the discovered list. Kept separate from the
    /// manual field so discovery is clearly an *offer* (a highlighted row), not a
    /// value silently typed into a text box the user expected to fill themselves.
    @State private var selectedServer: DiscoveredServer?
    /// What the user typed by hand. Empty unless they actively enter an address.
    @State private var manualURL = ""

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

            Section {
                TextField("http://192.168.1.10:8096", text: $manualURL)
                    .urlFieldStyle()
                    .onChange(of: manualURL) { _, new in
                        // Typing a URL means the user is going manual — drop any
                        // discovered selection so the two never fight.
                        if !new.isEmpty { selectedServer = nil }
                    }
            } header: {
                Text("Enter address manually")
            } footer: {
                if let baseURL, selectedServer == nil {
                    Text("Will connect to \(baseURL.absoluteString)")
                }
            }

            Section("Quick Connect") {
                if let code = quickConnectCode {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Enter this code in Jellyfin \u{25B8} Quick Connect:")
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
        if isDiscovering || !discovered.isEmpty {
            Section {
                if discovered.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching your network\u{2026}").foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                } else {
                    ForEach(discovered) { server in
                        Button { toggle(server) } label: {
                            HStack {
                                Image(systemName: "server.rack").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name).foregroundStyle(.primary)
                                    Text(server.baseURL.absoluteString)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedServer?.id == server.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
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
            } footer: {
                Text("Tap a server to select it, or enter an address manually below.")
            }
        }
    }

    /// Toggle selection of a discovered server. Selecting one clears any manually
    /// typed URL (and stale Quick Connect code) so there's a single source of truth.
    private func toggle(_ server: DiscoveredServer) {
        if selectedServer?.id == server.id {
            selectedServer = nil
        } else {
            selectedServer = server
            manualURL = ""
            quickConnectTask?.cancel()
            quickConnectCode = nil
            status = nil
        }
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
        }
        // If the network turned up exactly one server and the user hasn't typed
        // or picked anything, pre-select it \u2014 but visibly, as a checked row,
        // not by stuffing the manual field.
        if discovered.count == 1, selectedServer == nil, manualURL.isEmpty {
            selectedServer = discovered[0]
        }
    }

    /// The base URL sign-in will use: a discovered selection wins, else whatever
    /// was typed manually (normalized: a bare host becomes http://host:8096).
    private var baseURL: URL? {
        if let selectedServer { return selectedServer.baseURL }
        return JellyfinURLNormalizer.normalize(manualURL)
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
        status = "Requesting code\u{2026}"
        quickConnectTask = Task {
            do {
                let session = try await auth.initiateQuickConnect()
                quickConnectCode = session.code
                status = "Waiting for approval\u{2026}"
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
        status = "Signing in\u{2026}"
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
