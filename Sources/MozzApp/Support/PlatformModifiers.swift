import SwiftUI

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
}

extension Color {
    /// Cross-platform system background color. iOS ships the app; the macOS test
    /// host just needs it to compile (`Color(.systemBackground)` is iOS-only).
    static var mozzBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.black
        #endif
    }

    /// The near-black content background for the (always-dark, Apple-Music-style)
    /// media detail page, below the colored hero.
    static var mozzDetailBackground: Color { Color(white: 0.07) }
}
