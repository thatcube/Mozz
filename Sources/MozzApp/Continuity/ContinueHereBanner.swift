import MozzContinuity
import SwiftUI

/// Offers to pick up playback that was left on another device.
///
/// Deliberately an *offer*, never an automatic takeover: a checkpoint read from
/// the server may be minutes or days old, and the user's other device might
/// still be playing it. Accepting is the only thing that moves playback.
///
/// The coordinator is taken as an `@ObservedObject` rather than reached through
/// the environment object: a nested `ObservableObject` does not republish
/// through its parent, so `env.continuity.offer` alone would never refresh this
/// view.
struct ContinueHereBanner: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var continuity: ContinuityCoordinator
    /// Suppressed while the full-screen player is open: the banner floats above
    /// the tab bar, which is exactly where the expanded player's transport
    /// controls sit. The offer is state, not a transient toast, so it simply
    /// reappears when the player is dismissed.
    var isPlayerPresented: Bool

    var body: some View {
        if let offer = continuity.offer, !isPlayerPresented {
            card(for: offer)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func card(for offer: ContinuityOffer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline(for: offer))
                    .font(.subheadline.weight(.semibold))
                if !offer.title.isEmpty {
                    Text(subtitle(for: offer))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Listen here") {
                Task { await env.continueHere(offer) }
            }
            // NOT `.borderedProminent`: that draws a white label over the accent
            // color, and Mozz's accent is an adaptive near-white in dark mode —
            // which is how this button ended up white-on-white.
            .buttonStyle(.mozzProminentCompact)

            Button {
                withAnimation { continuity.dismissOffer() }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        // Capsule + the tab bar's own side inset, so the banner reads as part of
        // the same floating dock stack rather than a differently-shaped card
        // sitting slightly proud of it.
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
        .padding(.horizontal, BottomBar.hMargin)
        .accessibilityElement(children: .contain)
    }

    /// Names the other device when the backend can attribute a checkpoint.
    /// Subsonic cannot — its only signal is the client *product* name, which is
    /// identical for every Mozz install — so the copy stays honest and just says
    /// where you left off.
    private func headline(for offer: ContinuityOffer) -> String {
        if let device = offer.deviceName {
            return "Playing on \(device)"
        }
        return "Pick up where you left off"
    }

    private func subtitle(for offer: ContinuityOffer) -> String {
        var line = offer.title
        if !offer.artist.isEmpty { line += " · \(offer.artist)" }
        // Be upfront when only the track survived, rather than silently
        // resuming a one-track queue and looking broken.
        if offer.isTrackOnly { line += " — track only" }
        return line
    }
}
