import SwiftUI
import MozzCore

/// The sign-in entry point: choose a backend to connect, or launch the offline
/// demo (a synthetic catalog + bundled clip so the whole app works with no
/// server — ideal for the simulator).
///
/// Design: clean / minimal. Identity comes from the pixel-art Mozz mark, the
/// monochrome brand glyphs, and intentional whitespace — never decorative color.
/// The three providers are grouped into ONE inset card with hairline dividers.
///
/// Layout adapts to width. A compact width (iPhone) stacks the brand above the
/// card, centered. A regular width (iPad, and the large iPhones in landscape)
/// splits into two columns — brand left-aligned on the left, providers on the
/// right — because a single centered column strands the card far below a lone
/// logo on a wide, short canvas. This mirrors the tvOS chooser in Plozz, which
/// solves the same problem with the same side-by-side split.
struct OnboardingView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isLoadingDemo = false

    private var isWide: Bool { horizontalSizeClass == .regular }

    var body: some View {
        NavigationStack {
            // The content is centered in the available height, but stays
            // scrollable when it doesn't fit (landscape, large Dynamic Type)
            // instead of being clipped.
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 24)

                        if isWide {
                            wideLayout
                        } else {
                            compactLayout
                        }

                        Spacer(minLength: 24)

                        Text("GPL-3.0 · your library stays on your device")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, isWide ? 48 : 24)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
            }
        }
    }

    // MARK: Layouts

    /// Two columns: brand on the left, the provider card (and demo button) on
    /// the right, both vertically centered against each other. Capped and
    /// centered as a unit so the pair doesn't sprawl across a 13" iPad.
    private var wideLayout: some View {
        HStack(alignment: .center, spacing: 64) {
            brandHeader(alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 20) {
                providerCard
                #if targetEnvironment(simulator)
                demoButton
                #endif
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 980)
    }

    /// The original single centered column, unchanged on iPhone.
    private var compactLayout: some View {
        VStack(spacing: 0) {
            brandHeader(alignment: .center)

            Spacer(minLength: 32)

            providerCard

            #if targetEnvironment(simulator)
            // Simulator only: the offline demo (synthetic catalog + bundled
            // clip) — useful because the sim can't reach a real server.
            // Hidden on device builds (incl. Debug) so it's not in the way.
            demoButton
                .padding(.top, 20)
            #endif
        }
    }

    // MARK: Brand header

    /// Logo · wordmark · tagline. `alignment` drives both the stack and the
    /// text, so the leading variant reads as one flush-left block rather than
    /// centered text inside a left-aligned column.
    private func brandHeader(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 10) {
            Image("MozzLogo")
                .interpolation(.none) // preserve crisp pixel-art edges
                .resizable()
                .scaledToFit()
                .frame(width: isWide ? 128 : 104, height: isWide ? 128 : 104)
                .accessibilityHidden(true)
            Text("Mozz").font(.largeTitle.bold())
            Text("One app for your music, wherever it lives.\nFree forever and open source.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(alignment == .leading ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Provider card

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

    /// A provider row: monochrome brand glyph · name · chevron. Every row is a
    /// single balanced line; the glyph is a template SVG tinted with the label
    /// color (no chip, no gradient).
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
                Text(brand.pickerName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(brand.pickerName)
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
