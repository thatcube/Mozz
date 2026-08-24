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

    @Environment(\.colorScheme) private var colorScheme

    /// The banner reads as a *notification*, so it runs at inverted contrast —
    /// light on a dark UI, dark on a light one — which also stops it blending
    /// into the tab bar sitting directly beneath it.
    ///
    /// Done by flipping `colorScheme` for the whole subtree rather than
    /// hand-picking inverted colors, so every semantic color moves together. The
    /// "Listen here" pill matters most here: it fills with `Color.primary`, so
    /// under a naive inversion it would land light-on-light again — flipping the
    /// scheme keeps it automatically opposite to whatever the banner became.
    private var flipped: ColorScheme { colorScheme == .dark ? .light : .dark }

    var body: some View {
        if let offer = continuity.offer, !isPlayerPresented {
            card(for: offer)
                .environment(\.colorScheme, flipped)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func card(for offer: ContinuityOffer) -> some View {
        HStack(spacing: 12) {
            // Show the cover when the stored queue told us what's playing; fall
            // back to the handoff glyph for a track-only offer, where an empty
            // artwork frame would just read as a broken image.
            if offer.title.isEmpty {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .accessibilityHidden(true)
            } else {
                ArtworkView(
                    artwork: offer.artwork,
                    seed: offer.snapshot.cursor.current.remoteID,
                    size: 38,
                    cornerRadius: 6
                )
                .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                headline(for: offer)
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
        // A solid fill, not material: the point is a definite inverted surface,
        // and a blur would sample the background and wash the inversion out.
        // Under the flipped scheme this resolves light in dark mode and dark in
        // light mode.
        .background(Capsule().fill(Color.mozzBannerSurface))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.18), radius: 12, y: 4)
        .padding(.horizontal, BottomBar.hMargin)
        .accessibilityElement(children: .contain)
    }

    /// Names the source device in the brand color, with a glyph for what it is,
    /// so the eye lands on *where the music is* rather than on the boilerplate.
    ///
    /// Subsonic cannot attribute a checkpoint to a device — its only signal is
    /// the client *product* name, identical for every Mozz install — so the copy
    /// stays honest there and just says where you left off.
    @ViewBuilder
    private func headline(for offer: ContinuityOffer) -> some View {
        if let device = offer.deviceName {
            HStack(spacing: 5) {
                Text("Playing on")
                HStack(spacing: 3) {
                    Image(systemName: icon(for: offer.deviceKind))
                        .imageScale(.small)
                    Text(device)
                        .lineLimit(1)
                }
                // Fixed brand red, legible on either inverted surface.
                .foregroundStyle(Color.mozzBrand)
            }
            .font(.subheadline.weight(.semibold))
        } else {
            Text("Pick up where you left off")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func icon(for kind: ContinuityDeviceKind?) -> String {
        switch kind {
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .desktop: return "desktopcomputer"
        case .tv: return "appletv"
        case .speaker: return "hifispeaker"
        case .web: return "globe"
        case .unknown, .none: return "waveform"
        }
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
