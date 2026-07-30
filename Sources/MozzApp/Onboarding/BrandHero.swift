import SwiftUI

/// Identity metadata for a music backend (Plex / Jellyfin / Navidrome), shared by
/// the onboarding picker rows and each login screen's `BrandHero`.
///
/// The `logo` asset is a monochrome template SVG in `Brands.xcassets`, so each
/// surface decides how to tint it. The picker uses `tint` to draw a real brand
/// mark — the products are recognised by their colors, and three identical grey
/// glyphs made the choice harder than it needed to be. The login heroes stay in
/// the label color: at hero size the shape and name already identify the
/// provider, and a full-bleed brand color there would fight the rest of the app.
struct BrandStyle {
    /// Template-SVG asset name in the module's `Brands.xcassets`.
    let logo: String
    /// Provider display name (the login-screen heading + nav context).
    let name: String
    /// Name shown in the onboarding picker row — usually `name`, but can carry a
    /// short clarifier (e.g. Navidrome's "(Subsonic)") so every row stays a single
    /// balanced line without a subtitle.
    let pickerName: String
    /// One-line subtitle under the login-screen hero, or `nil` to show just the
    /// logo + name. Used only where the screen has no other explanatory text
    /// (Plex's bare screen) — screens with descriptive content below (Jellyfin,
    /// Navidrome) stay name-only to avoid restating it.
    let heroSubtitle: String?
    /// Brand accent, used for the picker's chip (glyph at full strength on a
    /// heavily translucent fill of the same color).
    let tint: Color

    static let jellyfin = BrandStyle(
        logo: "JellyfinLogo",
        name: "Jellyfin",
        pickerName: "Jellyfin",
        heroSubtitle: nil,
        tint: Color(red: 0.53, green: 0.38, blue: 0.95)
    )

    static let plex = BrandStyle(
        logo: "PlexLogo",
        name: "Plex",
        pickerName: "Plex",
        heroSubtitle: "Connect your Plex music library",
        tint: Color(red: 0xE5 / 255, green: 0xA0 / 255, blue: 0x0D / 255)
    )

    static let navidrome = BrandStyle(
        logo: "NavidromeLogo",
        name: "Navidrome",
        pickerName: "Navidrome (Subsonic)",
        heroSubtitle: nil,
        tint: Color(red: 0x2E / 255, green: 0x86 / 255, blue: 0xD6 / 255)
    )
}

/// A provider's logo in a soft circular chip of its own brand color — the mark
/// used in the onboarding picker. The glyph is a template SVG, so it takes the
/// brand color directly while the fill is the same color at low opacity, which
/// keeps every chip equally weighted in both light and dark.
struct BrandChip: View {
    let brand: BrandStyle
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(brand.tint.opacity(0.18))
            Image(brand.logo, bundle: .module)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                // `scaledToFit` fits the SVG's viewBox, not its ink, and Plex's
                // chevron only occupies about half the width and three quarters
                // of the height of its 24×24 canvas (Jellyfin's mark very nearly
                // fills its own). At an equal inset Plex therefore renders
                // visibly smaller, so give it a tighter one to even the two out.
                .padding(size * (brand.logo == "PlexLogo" ? 0.16 : 0.22))
                .foregroundStyle(brand.tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A clean hero shown at the top of each login screen: the brand logo large in
/// the label color, the provider name as a heading, and a one-line subtitle —
/// anchored by generous whitespace. Identity here comes from logo shape and
/// typography; the brand color is reserved for the picker's chips, where three
/// providers sit side by side and need telling apart at a glance.
///
/// The logo is decorative (`accessibilityHidden`); the name carries the heading
/// trait so VoiceOver reads a single, meaningful title.
struct BrandHero: View {
    let brand: BrandStyle
    var logoSize: CGFloat = 58

    var body: some View {
        VStack(spacing: 16) {
            Image(brand.logo, bundle: .module)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: logoSize, height: logoSize)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(brand.name)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                if let heroSubtitle = brand.heroSubtitle {
                    Text(heroSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
