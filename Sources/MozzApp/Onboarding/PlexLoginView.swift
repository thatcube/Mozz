import SwiftUI
import MozzCore
import MozzPlex
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#endif

/// Wraps `ASWebAuthenticationSession` so Plex sign-in happens in an in-app
/// browser sheet (which shares Safari's cookies — a signed-in user may skip
/// re-entering credentials) and, crucially, can be dismissed programmatically.
/// We don't set a `forwardUrl` (to avoid perturbing the working auth request);
/// instead the login flow polls the PIN and calls ``dismiss()`` the moment it's
/// authorized, which returns the user straight back to Mozz.
@MainActor
final class PlexWebAuthSession: NSObject, ObservableObject {
    private var session: ASWebAuthenticationSession?

    /// Present the auth page. Resumes when the sheet is dismissed — by the user,
    /// or by ``dismiss()`` once polling confirms authorization. `callbackScheme`
    /// is a scheme that is never actually navigated to; it just satisfies the API
    /// (auto-return is driven by polling + `dismiss()`, not a redirect).
    func present(url: URL, callbackScheme: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { _, _ in
                continuation.resume()
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false // reuse Safari's Plex cookies
            self.session = session
            if !session.start() {
                continuation.resume()
            }
        }
    }

    /// Dismiss the in-app browser (called once polling confirms authorization).
    func dismiss() {
        session?.cancel()
        session = nil
    }
}

extension PlexWebAuthSession: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if canImport(UIKit)
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
            #else
            ASPresentationAnchor()
            #endif
        }
    }
}

/// Plex sign-in via the hosted OAuth flow, presented in an in-app browser that
/// returns to Mozz automatically once authorized. Requests a (strong) link PIN,
/// shows the Plex auth page, polls until it's claimed, then discovers the
/// account's servers and pins the fastest reachable address.
struct PlexLoginView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @StateObject private var webAuth = PlexWebAuthSession()

    private enum Phase { case idle, authorizing, completing }
    @State private var phase: Phase = .idle
    @State private var status: String?
    @State private var task: Task<Void, Never>?

    private let callbackScheme = "mozz"

    var body: some View {
        Form {
            Section {
                switch phase {
                case .idle:
                    Button("Sign in with Plex") { start() }
                case .authorizing:
                    Text("Complete sign-in in the Plex window. Mozz returns here automatically once you're authorized.")
                        .font(.footnote).foregroundStyle(.secondary)
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
        phase = .authorizing
        status = "Opening Plex…"
        task = Task {
            do {
                let pin = try await auth.requestPin()
                guard let url = pin.authAppURL(clientInfo: env.clientInfo) else {
                    throw MozzError.unsupported("Couldn't build the Plex sign-in URL.")
                }
                status = "Waiting for you to authorize in Plex…"
                let token = try await authorize(pin: pin, url: url, auth: auth)
                phase = .completing
                status = "Finding your servers…"
                let session = try await auth.completeLogin(accountToken: token)
                status = "Setting up your library…"
                try await env.activate(session: session)
                dismiss()
            } catch is CancellationError {
                phase = .idle
                status = nil
            } catch {
                webAuth.dismiss()
                phase = .idle
                status = "Plex sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    /// Present the in-app auth sheet and poll for the PIN token concurrently. The
    /// token poll is the source of truth; when it succeeds we dismiss the sheet
    /// (auto-returning to Mozz). If the user closes the sheet first, we abort.
    private func authorize(pin: PlexPinSession, url: URL, auth: PlexAuthenticator) async throws -> String {
        enum Outcome { case token(String); case sheetClosed }
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask { @MainActor in
                await webAuth.present(url: url, callbackScheme: callbackScheme)
                return .sheetClosed
            }
            group.addTask {
                .token(try await auth.awaitPin(pin, pollInterval: 1, timeout: 300))
            }
            defer { group.cancelAll() }
            for try await outcome in group {
                switch outcome {
                case .token(let token):
                    webAuth.dismiss()
                    return token
                case .sheetClosed:
                    // The sheet was closed before authorization completed (we only
                    // dismiss it ourselves AFTER a token, which returns above).
                    throw CancellationError()
                }
            }
            throw CancellationError()
        }
    }
}
