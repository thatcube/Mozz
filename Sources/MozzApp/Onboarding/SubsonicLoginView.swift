import SwiftUI
import MozzCore
import MozzSubsonic

/// Subsonic / OpenSubsonic sign-in. Deliberately simpler than the Jellyfin
/// picker — Subsonic has no zero-conf discovery in the wild, so we just take
/// a URL + username + password (with an optional API key field for servers
/// that advertise `apiKeyAuthentication`).
///
/// The password is used ONCE to derive a stable-salted MD5 credential and is
/// discarded from memory; only the envelope is persisted (see
/// ``SubsonicAuthenticator``).
struct SubsonicLoginView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var status: String?
    @State private var isBusy = false

    var body: some View {
        Form {
            Section {
                TextField("http://navidrome.local:4533", text: $serverURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
            } header: {
                Text("Server")
            } footer: {
                Text("The URL to your Subsonic-compatible server (Navidrome, Gonic, Ampache, LMS). Paste the browser address; a trailing `/rest` will be stripped.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            } header: {
                Text("Account")
            } footer: {
                Text("Mozz never stores your password. It derives a stable-salted MD5 token from it and stores only the token.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                TextField("API key", text: $apiKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
            } header: {
                Text("OpenSubsonic API Key (optional)")
            } footer: {
                Text("If your server supports apiKeyAuthentication, enter a token here to use it instead of a password.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let status {
                Section { Text(status).foregroundStyle(.secondary).font(.footnote) }
            }
            Section {
                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        if isBusy { ProgressView().padding(.trailing, 4) }
                        Text(isBusy ? "Signing in…" : "Sign In")
                    }
                }
                .disabled(!canSubmit || isBusy)
            }
        }
        .navigationTitle("Subsonic")
        .inlineNavigationTitle()
    }

    private var canSubmit: Bool {
        guard SubsonicAuthenticator.normalize(serverURL) != nil else { return false }
        let hasCreds = (!password.isEmpty && !username.isEmpty) ||
                       (!apiKey.isEmpty && !username.isEmpty)
        return hasCreds
    }

    private func signIn() async {
        guard let baseURL = SubsonicAuthenticator.normalize(serverURL) else {
            status = "That doesn't look like a valid URL."
            return
        }
        isBusy = true
        defer { isBusy = false }
        status = nil

        let auth = SubsonicAuthenticator(
            baseURL: baseURL,
            clientInfo: env.clientInfo,
            clientIdentifier: env.clientIdentifier
        )
        do {
            let session: AuthenticatedSession
            if !apiKey.isEmpty {
                session = try await auth.authenticateWithAPIKey(username: username, apiKey: apiKey)
            } else {
                session = try await auth.authenticate(username: username, password: password)
            }
            // Wipe the password from local view state before handing off.
            password = ""
            apiKey = ""
            env.activate(session: session)
        } catch let error as MozzError {
            status = friendly(for: error)
        } catch {
            status = "Sign in failed: \(error.localizedDescription)"
        }
    }

    private func friendly(for error: MozzError) -> String {
        switch error {
        case .unauthorized: return "Wrong username or password."
        case .notFound: return "Server responded, but the requested endpoint is missing. Is this a Subsonic-compatible server?"
        case .unsupported(let m): return m
        case .transport(let m): return "Couldn't reach the server: \(m)"
        default: return "Sign in failed."
        }
    }
}
