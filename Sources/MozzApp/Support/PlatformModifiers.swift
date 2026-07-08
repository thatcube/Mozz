import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Cross-platform view shims. The app ships for iOS, but the package also builds
/// for macOS so the pure-logic and engine modules can be unit-tested quickly on
/// the host via `swift test`. These wrappers keep the (iOS-only) UI layer
/// compiling on macOS without littering every view with `#if os(iOS)`.
extension View {
    /// Inline navigation-bar title on iOS/tvOS; a no-op on macOS.
    @ViewBuilder func inlineNavigationTitle() -> some View {
        #if os(iOS) || os(tvOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// URL-entry configuration (no autocaps/autocorrect, URL keyboard) on iOS.
    @ViewBuilder func urlFieldStyle() -> some View {
        #if os(iOS)
        self.textContentType(.URL)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// Username-entry configuration (no autocaps/autocorrect) on iOS.
    @ViewBuilder func plainTextFieldStyle() -> some View {
        #if os(iOS)
        self.autocorrectionDisabled().textInputAutocapitalization(.never)
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// Marks a field as the account username, so iOS/password-manager AutoFill
    /// can offer to fill it. iOS only; no-op on the macOS test host.
    @ViewBuilder func usernameContentType() -> some View {
        #if os(iOS)
        self.textContentType(.username)
        #else
        self
        #endif
    }

    /// Marks a field as the account password for AutoFill / keychain save. iOS
    /// only; no-op on the macOS test host.
    @ViewBuilder func passwordContentType() -> some View {
        #if os(iOS)
        self.textContentType(.password)
        #else
        self
        #endif
    }

    /// Hides the navigation bar on iOS so a custom scroll-away header (title +
    /// avatar, tight to the top like Apple Music) can stand in for it — the
    /// native SwiftUI large title can't be pulled that high (its top inset is
    /// larger and not reducible). Pass `false` to reveal the bar (e.g. while
    /// native search is active, which needs the bar to host its field). No-op on
    /// the macOS test host.
    @ViewBuilder func hideNavigationBar(_ hidden: Bool = true) -> some View {
        #if os(iOS)
        self.toolbar(hidden ? .hidden : .visible, for: .navigationBar)
        #else
        self
        #endif
    }

    /// Transparent nav bar with light (white) bar-button content, so a hero
    /// image/color shows under the back button. iOS only; no-op on macOS.
    @ViewBuilder func heroNavigationChrome() -> some View {
        #if os(iOS)
        self.toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }

    /// Real iOS 26 Liquid Glass, clipped to a capsule (for the custom search
    /// field). Falls back to a material on iOS 17–25 and the macOS test host.
    @ViewBuilder func glassCapsule() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
        #else
        self.background(.regularMaterial, in: Capsule())
        #endif
    }

    /// Paints a screen with the app's elevation floor (`mozzBackground`) and hides
    /// the default `List`/`ScrollView` system background so the token shows through.
    /// Use on top-level tab screens and pushed pages that aren't the (self-dark)
    /// media-detail scaffold, so the whole app shares one neutral elevation base.
    func mozzScreenBackground() -> some View {
        modifier(MozzScreenBackground())
    }

    /// A circular Liquid Glass background (iOS 26+) — sized by the caller's frame
    /// so the search-cancel ✕ can exactly match the field height. Falls back to a
    /// material circle on iOS 17–25 and the macOS test host.
    @ViewBuilder func glassCircle() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Circle())
        } else {
            self.background(.regularMaterial, in: Circle())
        }
        #else
        self.background(.regularMaterial, in: Circle())
        #endif
    }

    /// Real iOS 26 Liquid Glass clipped to an arbitrary shape (e.g. the rating
    /// reveal's tailed bubble, so it matches the system popover's glass). Falls
    /// back to a material fill + soft shadow on iOS 17–25 and the macOS test host.
    @ViewBuilder func glassBackground<S: Shape>(_ shape: S) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(shape.fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3))
        }
        #else
        self.background(shape.fill(.regularMaterial))
        #endif
    }
}

/// Backing modifier for `mozzScreenBackground()`. Observes the dark-flavor setting
/// so the elevation token re-resolves the instant Dim↔Black is toggled: the tokens
/// read that flag inside a `UIColor` dynamicProvider the system caches per trait
/// collection, and the flavor isn't a trait change. Re-running *this* modifier's
/// body (rather than re-`.id()`-ing the whole tree) refreshes the color without
/// disturbing view identity — so navigation state and any open sheet survive.
private struct MozzScreenBackground: ViewModifier {
    @AppStorage(Color.MozzDarkStyle.storageKey) private var darkStyleRaw = Color.MozzDarkStyle.default.rawValue
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Color.mozzBackground.ignoresSafeArea())
    }
}

extension Color {
    /// User appearance override: follow the system, or force light/dark.
    enum MozzAppearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
        /// The `preferredColorScheme` value (nil = follow system).
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
        static let storageKey = "mozz.appearance"
        static let `default`: MozzAppearance = .system
    }

    /// Which flavor of dark to use whenever dark mode is active (system-triggered
    /// or forced): a neutral gray ladder, or pure-black OLED.
    enum MozzDarkStyle: String, CaseIterable, Identifiable {
        case dim, black
        var id: String { rawValue }
        var label: String { self == .dim ? "Dim" : "Black" }
        static let storageKey = "mozz.darkStyle"
        static let `default`: MozzDarkStyle = .dim
    }

    /// Whether the pure-black OLED dark style is active (a user setting). Read at
    /// color-resolution time so all elevation tokens shift together. Only matters
    /// in dark mode: "dim" = neutral gray ladder, "black" = OLED ladder.
    static var mozzOLED: Bool { UserDefaults.standard.string(forKey: "mozz.darkStyle") == "black" }

    #if canImport(UIKit)
    /// Build a theme-aware color: one value in light, and in dark either the
    /// neutral standard-dark value or the darker OLED value (chosen live from the
    /// `mozz.oledMode` setting). Resolving in a `dynamicProvider` keeps light/dark
    /// automatic; the OLED read makes the whole ladder switch together.
    private static func mozzSurfaceColor(light: UInt, darkStandard: UInt, darkOLED: UInt) -> Color {
        Color(uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(hex: mozzOLED ? darkOLED : darkStandard)
            }
            return UIColor(hex: light)
        })
    }
    #endif

    // MARK: - Elevation surface tokens
    //
    // A small, deliberate elevation ladder. In dark mode higher surfaces are
    // LIGHTER (Material-style: darkest = furthest away); in light mode the base is
    // a soft gray and content is white. OLED shifts every tier toward black.
    //
    //           Standard Dark   OLED Dark   Light
    //  background   #1C1C1E       #000000    #F2F2F7   page / floor
    //  surface      #2C2C2E       #121212    #FFFFFF   cards, list rows
    //  surfaceRaised#3A3A3C       #1C1C1E    #FFFFFF   sheets, detail, popovers
    //  chrome       #2C2C2E       #1C1C1E    material  nav / island / player solid

    /// Layer 0 — the page/screen background (the "floor"). Darkest in dark mode.
    static var mozzBackground: Color {
        #if canImport(UIKit)
        mozzSurfaceColor(light: 0xF2F2F7, darkStandard: 0x1C1C1E, darkOLED: 0x000000)
        #elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.black
        #endif
    }

    /// Layer 1 — cards, list rows, content surfaces. One step above the floor.
    static var mozzSurface: Color {
        #if canImport(UIKit)
        mozzSurfaceColor(light: 0xFFFFFF, darkStandard: 0x2C2C2E, darkOLED: 0x121212)
        #else
        Color(white: 0.17)
        #endif
    }

    /// Layer 2 — sheets, context menus, popovers, the media-detail hero body.
    static var mozzSurfaceRaised: Color {
        #if canImport(UIKit)
        mozzSurfaceColor(light: 0xFFFFFF, darkStandard: 0x3A3A3C, darkOLED: 0x1C1C1E)
        #else
        Color(white: 0.23)
        #endif
    }

    /// The near-black content background for the (always-dark, Apple-Music-style)
    /// media detail page, below the colored hero. Follows the raised tier so it
    /// tracks OLED, staying dark but a touch above the floor.
    static var mozzDetailBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { _ in UIColor(hex: mozzOLED ? 0x000000 : 0x121212) })
        #else
        Color(white: 0.07)
        #endif
    }

    /// The Mozz brand color (#F50031) — a vivid crimson used for brand accents
    /// such as the star rating fill.
    static var mozzBrand: Color { Color(red: 245.0 / 255.0, green: 0.0, blue: 49.0 / 255.0) }

    /// A subtle, theme-aware neutral fill for artwork placeholders — a quiet gray
    /// box (never a colorful tile) shown while real artwork loads or is missing.
    /// Adapts to light/dark so it reads as a calm empty frame in both.
    static var mozzArtworkPlaceholder: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemFill)
        #elseif canImport(AppKit)
        Color(nsColor: .quaternaryLabelColor)
        #else
        Color.gray.opacity(0.2)
        #endif
    }

    /// Layer 3 — the opaque "chrome" surface for nav / island / player when Liquid
    /// Glass is off (setting off / Low Power Mode / Reduce Transparency). Sits one
    /// tier above the page floor so the navigation reads as elevated chrome and the
    /// tab bar, island, and player all match.
    static var mozzChrome: Color {
        #if canImport(UIKit)
        mozzSurfaceColor(light: 0xFFFFFF, darkStandard: 0x2C2C2E, darkOLED: 0x1C1C1E)
        #elseif canImport(AppKit)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(white: 0.12)
        #endif
    }

    /// A secondary grouped-surface background (for cards/rows) that works on both
    /// iOS and the macOS test host. `Color(.secondarySystemBackground)` is
    /// UIKit-only and won't compile for the macOS host used by `swift test`.
    static var mozzSecondaryBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(white: 0.12)
        #endif
    }

    /// Theme-aware gray fill for the search field at rest (before it turns to
    /// Liquid Glass on scroll). Uses `.systemGray5` — one step above the page
    /// floor (`mozzBackground` is `.systemGray6` in light mode), so the field
    /// stays visible against the page in both light and dark, like the system
    /// search bar.
    static var searchFieldRest: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGray5)
        #elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.gray.opacity(0.18)
        #endif
    }
}

#if canImport(UIKit)
private extension UIColor {
    /// An opaque UIColor from a 24-bit `0xRRGGBB` hex literal.
    convenience init(hex: UInt) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif

#if os(iOS)
/// Keeps the interactive swipe-to-go-back gesture working on a screen that hides
/// the system navigation bar (hiding the bar otherwise disables the edge-swipe).
/// Re-enables the `UINavigationController`'s pop gesture with a permissive
/// delegate; safe on pushed detail screens, which always have a parent to pop to.
private struct InteractivePopEnabler: UIViewControllerRepresentable {
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { true }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ vc: UIViewController, context: Context) {
        DispatchQueue.main.async {
            guard let gesture = vc.navigationController?.interactivePopGestureRecognizer else { return }
            gesture.isEnabled = true
            gesture.delegate = context.coordinator
        }
    }
}

extension View {
    /// Preserve swipe-back after `hideNavigationBar()`. No-op on macOS.
    @ViewBuilder func enableInteractivePop() -> some View {
        self.background(InteractivePopEnabler().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}
#else
extension View {
    @ViewBuilder func enableInteractivePop() -> some View { self }
}
#endif
