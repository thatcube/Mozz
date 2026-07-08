import SwiftUI
import MozzCore
import MozzPlex
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#endif

/// Presents Plex sign-in in an `ASWebAuthenticationSession` (an in-app browser
/// that shares Safari's session, so a signed-in user may skip re-entering
/// credentials) and — the key to auto-return — dismisses it programmatically via
/// `cancel()` the moment the PIN poll confirms authorization, landing the user
/// right back in Mozz. This is Plex's documented "polling" native-app flow, as
/// used by the reference clients kunish/zeroflix and Playerseerr: the web session
/// is fire-and-forget, polling is the source of truth (Plex won't redirect to a
/// custom scheme, so we never wait on a callback), and `cancel()` returns the
/// user. The callback scheme is display-only and needs no Info.plist entry.
@MainActor
final class PlexWebAuthSession: NSObject, ObservableObject {
    private var session: ASWebAuthenticationSession?
    /// Set once the sheet closes (user tapped Cancel, or we dismissed it). The
    /// poll uses this to apply a short grace period before treating a close as a
    /// cancellation, so closing the sheet right as the token is issued still wins.
    private(set) var isClosed = false

    func start(url: URL, callbackScheme: String) {
        isClosed = false
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] _, _ in
            // Fires only on user-cancel/error — Plex never redirects to our scheme.
            // Polling drives completion; this just flags the sheet as closed.
            Task { @MainActor in self?.isClosed = true }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false // reuse Safari's Plex session
        self.session = session
        if !session.start() { isClosed = true }
    }

    /// Dismiss the in-app browser — this is what auto-returns the user to Mozz.
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

/// Plex sign-in: request a (strong) link PIN, present the hosted auth page in an
/// in-app browser, poll until it's claimed, auto-dismiss the browser (returning
/// the user to Mozz), then discover the account's servers.
struct PlexLoginView: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var webAuth = PlexWebAuthSession()

    private enum Phase { case idle, authorizing, completing }
    @State private var phase: Phase = .idle
    @State private var status: String?
    @State private var task: Task<Void, Never>?

    // Display-only scheme for ASWebAuthenticationSession; Plex never redirects to
    // it and it needs no Info.plist registration.
    private let callbackScheme = "mozz"

    var body: some View {
        Form {
            Section {
                BrandHero(brand: .plex)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)

            Section {
                switch phase {
                case .idle:
                    Text("Sign in to your Plex account to connect your music library. A secure Plex window opens, and Mozz returns here automatically once you're authorized.")
                        .font(.footnote).foregroundStyle(.secondary)
                case .authorizing:
                    Text("Complete sign-in in the Plex window. Mozz returns here automatically once you're authorized.")
                        .font(.footnote).foregroundStyle(.secondary)
                case .completing:
                    Label("Signed in", mozz: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                }
            }

            // Plex has no fields/keyboard, so its primary action lives inline on
            // the page (right under the explainer) rather than floating above the
            // bottom safe area — a floating button over this near-empty screen
            // reads as stranded.
            if phase == .idle {
                Section {
                    SignInBar(title: "Sign in with Plex") { start() }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowSeparator(.hidden)
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
        .onDisappear {
            task?.cancel()
            webAuth.dismiss()
        }
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
                // Fire-and-forget: present the browser, then poll concurrently.
                webAuth.start(url: url, callbackScheme: callbackScheme)
                status = "Waiting for you to authorize in Plex…"
                let token = try await pollForToken(auth: auth, pin: pin)
                // Authorized — dismiss the browser (auto-return) and hand off to
                // the environment, which owns the setup task so backing out of
                // this screen can't cancel it.
                webAuth.dismiss()
                phase = .completing
                status = "Finding your servers…"
                let session = try await auth.completeLogin(accountToken: token)
                env.activate(session: session)
                // No dismiss needed: RootView switches to the setup screen / app
                // as soon as `isSettingUp`/`active` flips.
            } catch is CancellationError {
                webAuth.dismiss()
                phase = .idle
                status = nil
            } catch {
                webAuth.dismiss()
                phase = .idle
                status = "Plex sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    /// Poll the PIN until it's claimed. If the user closes the browser without
    /// authorizing, a short grace period lets a just-issued token still win before
    /// treating the close as a cancellation.
    private func pollForToken(auth: PlexAuthenticator, pin: PlexPinSession) async throws -> String {
        var graceRemaining = 5
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try Task.checkCancellation()
            if let token = try? await auth.checkPin(id: pin.id, code: pin.code), !token.isEmpty {
                return token
            }
            if webAuth.isClosed {
                graceRemaining -= 1
                if graceRemaining <= 0 { throw CancellationError() }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw MozzError.cancelled
    }
}
