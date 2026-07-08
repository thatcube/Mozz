import SwiftUI

/// Identity metadata for a music backend (Plex / Jellyfin / Navidrome), shared by
/// the onboarding picker rows and each login screen's `BrandHero`. Deliberately
/// carries NO color: identity comes from the logo shape + type, not decoration.
/// The `logo` asset is a monochrome template SVG in `Brands.xcassets`, tinted with
/// the label color wherever it's drawn.
struct BrandStyle {
    /// Template-SVG asset name in the module's `Brands.xcassets`.
    let logo: String
    /// Provider display name (the login-screen heading + nav context).
    let name: String
    /// Name shown in the onboarding picker row — usually `name`, but can carry a
    /// short clarifier (e.g. Navidrome's "(Subsonic)") so every row stays a single
    /// balanced line without a subtitle.
    let pickerName: String
    /// One-line subtitle under the login-screen hero.
    let heroSubtitle: String

    static let jellyfin = BrandStyle(
        logo: "JellyfinLogo",
        name: "Jellyfin",
        pickerName: "Jellyfin",
        heroSubtitle: "Sign in to your Jellyfin server"
    )

    static let plex = BrandStyle(
        logo: "PlexLogo",
        name: "Plex",
        pickerName: "Plex",
        heroSubtitle: "Sign in to stream your Plex music"
    )

    static let navidrome = BrandStyle(
        logo: "NavidromeLogo",
        name: "Navidrome",
        pickerName: "Navidrome (Subsonic)",
        heroSubtitle: "Sign in to your Subsonic server"
    )
}

/// A clean, MONOCHROME hero shown at the top of each login screen: the brand logo
/// large in the label color, the provider name as a heading, and a one-line
/// subtitle — anchored by generous whitespace. This is the app's answer to the
/// old "bland black void": identity via logo shape + typography, never color.
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
                Text(brand.heroSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
