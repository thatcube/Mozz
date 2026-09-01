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
/// splits into two columns — brand on the left, providers on the right — because
/// a single centered column strands the card far below a lone logo on a wide,
/// short canvas. This mirrors the tvOS chooser in Plozz, down to its 40/60 split:
/// the card carries three rows of text and needs the greater share.
struct OnboardingView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isLoadingDemo = false
    @Environment(\.colorScheme) private var scheme
    @AppStorage(Color.MozzDarkStyle.storageKey) private var darkStyleRaw = Color.MozzDarkStyle.default.rawValue
    private var blackout: Bool {
        scheme == .dark && (Color.MozzDarkStyle(rawValue: darkStyleRaw) ?? .default) == .black
    }

    private var isWide: Bool { horizontalSizeClass == .regular }

    /// Gutter either side of the content.
    private var horizontalPadding: CGFloat { isWide ? 48 : 24 }

    var body: some View {
        NavigationStack {
            // The content is centered in the available height, but stays
            // scrollable when it doesn't fit (landscape, large Dynamic Type)
            // instead of being clipped.
            GeometryReader { proxy in
                ScrollView {
                    // ONE flat stack on purpose. The spacers share the leftover
                    // height between them, which is what balances the page — put
                    // any of them inside a nested stack and that stack absorbs
                    // all the slack on its own, pinning the brand to the top and
                    // the card to the bottom.
                    VStack(spacing: 0) {
                        if isWide {
                            Spacer(minLength: 24)
                            wideLayout(availableWidth: proxy.size.width - horizontalPadding * 2)
                            Spacer(minLength: 24)
                        } else {
                            Spacer(minLength: 24)

                            brandHeader(alignment: .center)

                            Spacer(minLength: 32)

                            providerCard

                            #if targetEnvironment(simulator)
                            // Simulator only: the offline demo (synthetic catalog
                            // + bundled clip) — useful because the sim can't reach
                            // a real server. Hidden on device builds (incl. Debug)
                            // so it's not in the way.
                            demoButton
                                .padding(.top, 20)
                            #endif

                            Spacer(minLength: 24)
                        }

                        Text("GPL-3.0 · your library stays on your device")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
            }
        }
    }

    // MARK: Layouts

    /// Two columns, vertically centered against each other: brand on the left,
    /// the provider card (and demo button) on the right. The widths are split
    /// explicitly rather than left to the stack, which would divide the space
    /// evenly and leave the card cramped next to a mostly-empty brand column.
    private func wideLayout(availableWidth: CGFloat) -> some View {
        // Capped so the pair doesn't sprawl across a 13" iPad, and floored at 0:
        // GeometryReader reports .zero on its first layout pass, which would
        // otherwise make this negative and hand a negative width to `.frame`.
        let gap: CGFloat = 56
        let columns = max(0, min(availableWidth, 1000) - gap)

        return HStack(alignment: .center, spacing: gap) {
            brandHeader(alignment: .center)
                .frame(width: columns * 0.4)

            VStack(spacing: 20) {
                providerCard
                #if targetEnvironment(simulator)
                demoButton
                #endif
            }
            .frame(width: columns * 0.6)
        }
    }

    // MARK: Brand header

    /// Logo · wordmark · tagline, as one centered block.
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
    /// of three separate buttons.
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
        // In Black the card's fill is the page's own black, so the hairline is
        // what makes these three rows one surface rather than three labels
        // floating in nothing.
        .overlay {
            if blackout {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.mozzHairline, lineWidth: 1)
            }
        }
        .tint(.primary)
    }

    /// Inset to clear the chip so the dividers line up with the row text.
    private var rowDivider: some View {
        Divider().padding(.leading, 16 + Self.chipSize + 14)
    }

    private static let chipSize: CGFloat = 40

    /// A provider row: brand chip · name · chevron. Every row is a single
    /// balanced line.
    private func providerRow<Destination: View>(
        brand: BrandStyle,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                BrandChip(brand: brand, size: Self.chipSize)
                Text(brand.pickerName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 14)
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
