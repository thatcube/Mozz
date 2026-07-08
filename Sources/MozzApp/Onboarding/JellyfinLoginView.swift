import SwiftUI
import MozzCore
import MozzJellyfin

/// Jellyfin sign-in, modelled on the iOS Wi-Fi picker: choose a server found on
/// your network (or type its address), then sign in to *that* server via Quick
/// Connect or username/password.
struct JellyfinLoginView: View {
    @EnvironmentObject private var env: AppEnvironment

    /// A server the user picked from the discovered list. Kept separate from the
    /// manual field so discovery is an *offer* (a checked row), never a value
    /// silently typed into the address box.
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
            networkSection
            manualSection
            if baseURL != nil {
                signInSection
            }
            if let status {
                Section { Text(status).foregroundStyle(.secondary).font(.footnote) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if baseURL != nil {
                SignInBar(title: "Sign In", isBusy: isBusy,
                          isEnabled: !username.isEmpty && !password.isEmpty) {
                    signInWithPassword()
                }
            }
        }
        .navigationTitle("Jellyfin")
        .inlineNavigationTitle()
        .task { await runDiscovery() }
        .onDisappear { quickConnectTask?.cancel() }
    }

    // MARK: Servers on your network

    @ViewBuilder private var networkSection: some View {
        Section {
            if !discovered.isEmpty {
                ForEach(discovered) { server in
                    serverRow(server)
                }
            } else if isDiscovering {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching your network\u{2026}").foregroundStyle(.secondary)
                }
                .font(.callout)
            } else {
                HStack {
                    Text("No servers found on this network.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Search again") { Task { await runDiscovery() } }
                }
                .font(.callout)
            }
        } header: {
            HStack {
                Text("Servers on your network")
                if isDiscovering && !discovered.isEmpty {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    /// A selection row (Wi-Fi-picker style): plain label-colored text with a blue
    /// checkmark when chosen. `.buttonStyle(.plain)` keeps the text from turning
    /// accent-blue (which would read as a link, not a selectable item).
    private func serverRow(_ server: DiscoveredServer) -> some View {
        Button {
            select(server)
        } label: {
            HStack(spacing: 12) {
                Image(mozz: "server.rack")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .foregroundStyle(.primary)
                    Text(server.baseURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selectedServer?.id == server.id {
                    Image(mozz: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // One VoiceOver element: the name + address, with a Selected trait to
        // convey the checkmark (which is hidden above) semantically.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(server.name)
        .accessibilityValue(server.baseURL.absoluteString)
        .accessibilityHint("Selects this server to sign in to")
        .accessibilityAddTraits(selectedServer?.id == server.id ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Manual entry

    @ViewBuilder private var manualSection: some View {
        Section {
            TextField("192.168.1.10  or  https://jellyfin.example.com", text: $manualURL)
                .urlFieldStyle()
                .accessibilityLabel("Server address")
                .accessibilityHint("For example, 192.168.1.10 or https://jellyfin.example.com")
                .onChange(of: manualURL) { _, new in
                    // Typing means the user is going manual — drop any list
                    // selection so there's a single source of truth.
                    if !new.isEmpty { selectedServer = nil }
                }
        } header: {
            Text("Or enter an address")
        } footer: {
            if selectedServer == nil, let baseURL {
                Text("Will connect to \(baseURL.absoluteString)")
            }
        }
    }

    // MARK: Sign in

    @ViewBuilder private var signInSection: some View {
        Section("Quick Connect") {
            if let code = quickConnectCode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Enter this code in Jellyfin \u{25B8} Quick Connect:")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(code).font(.system(.title, design: .monospaced).bold())
                        .accessibilityLabel("Quick Connect code")
                        .accessibilityValue(code.map(String.init).joined(separator: " "))
                }
            } else {
                Button("Start Quick Connect") { startQuickConnect() }
                    .disabled(isBusy)
            }
        }

        Section {
            TextField("Username", text: $username)
                .plainTextFieldStyle()
                .usernameContentType()
                .accessibilityLabel("Username")
            SecureField("Password", text: $password)
                .passwordContentType()
                .accessibilityLabel("Password")
        } header: {
            Text("Sign in to \(targetName)")
        }
    }

    /// Name of the server sign-in will target — the discovered server's name, or
    /// the host of a manually typed address.
    private var targetName: String {
        if let selectedServer { return selectedServer.name }
        return baseURL?.host ?? "server"
    }

    // MARK: Selection + discovery

    /// Select a discovered server (Wi-Fi-picker tap). Clears the manual field and
    /// any stale Quick Connect code so there's one source of truth.
    private func select(_ server: DiscoveredServer) {
        selectedServer = server
        manualURL = ""
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
        }
        // Exactly one server and nothing typed/picked → pre-select it, but
        // visibly as a checked row (never by stuffing the address field).
        if discovered.count == 1, selectedServer == nil, manualURL.isEmpty {
            selectedServer = discovered[0]
        }
    }

    /// The base URL sign-in will use: a discovered selection wins, else the typed
    /// address (normalized: a bare host becomes http://host:8096).
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
        status = (baseURL.map(LocalNetworkPermission.isLocalHost) ?? false)
            ? "Signing in\u{2026} If iOS asks, allow local network access."
            : "Signing in\u{2026}"
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
