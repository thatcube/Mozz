import SwiftUI
import MozzCore

/// The sign-in entry point: choose a backend to connect, or launch the offline
/// demo (a synthetic catalog + bundled clip so the whole app works with no
/// server — ideal for the simulator).
///
/// Design: clean / minimal. Identity comes from the pixel-art Mozz mark, the
/// monochrome brand glyphs, and intentional whitespace — never decorative color.
/// The three providers are grouped into ONE inset card with hairline dividers.
struct OnboardingView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var isLoadingDemo = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 24)

                brandHeader

                Spacer(minLength: 32)

                providerCard

                #if targetEnvironment(simulator)
                // Simulator only: the offline demo (synthetic catalog + bundled
                // clip) — useful because the sim can't reach a real server.
                // Hidden on device builds (incl. Debug) so it's not in the way.
                demoButton
                    .padding(.top, 20)
                #endif

                Spacer(minLength: 24)

                Text("GPL-3.0 · your library stays on your device")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Brand header (upper third)

    private var brandHeader: some View {
        VStack(spacing: 10) {
            Image("MozzLogo")
                .interpolation(.none) // preserve crisp pixel-art edges
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)
            Text("Mozz").font(.largeTitle.bold())
            Text("One app for your music, wherever it lives. Free forever. Open source.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Provider card (centered)

    /// One grouped card holding the three providers, separated by hairline
    /// dividers inset to align with the row text — a single calm surface instead
    /// of three colored pills.
    private var providerCard: some View {
        VStack(spacing: 0) {
            providerRow(brand: .jellyfin) { JellyfinLoginView() }
            rowDivider
            providerRow(brand: .plex) { PlexLoginView() }
            rowDivider
            providerRow(brand: .navidrome) { SubsonicLoginView() }
        }
        .background(Color.mozzSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .tint(.primary)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 56)
    }

    /// A provider row: monochrome brand glyph · name + one-line tagline · chevron.
    /// The glyph is a template SVG tinted with the label color (no chip, no
    /// gradient); the tagline adds quiet, educational content without color.
    private func providerRow<Destination: View>(
        brand: BrandStyle,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(brand.logo, bundle: .module)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(brand.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let tagline = brand.tagline {
                        Text(tagline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(brand.name)
        .accessibilityValue(brand.tagline ?? "")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Simulator demo

    #if targetEnvironment(simulator)
    private var demoButton: some View {
        Button {
            Task {
                isLoadingDemo = true
                try? await env.activateDemo()
                isLoadingDemo = false
            }
        } label: {
            HStack(spacing: 8) {
                if isLoadingDemo {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                }
                Text("Try the offline demo")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .disabled(isLoadingDemo)
    }
    #endif
}
