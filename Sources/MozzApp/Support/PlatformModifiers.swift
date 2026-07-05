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

    /// Inset-grouped list style (the rounded "card" look) on iOS/tvOS; falls
    /// back to the default style on macOS, where `.insetGrouped` is unavailable.
    @ViewBuilder func insetGroupedListStyle() -> some View {
        #if os(iOS) || os(tvOS)
        self.listStyle(.insetGrouped)
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

    /// Hides the navigation bar on iOS so a custom scroll-away header (with the
    /// Settings avatar) can stand in for it. No-op on the macOS test host, where
    /// the `.navigationBar` ToolbarPlacement is unavailable.
    @ViewBuilder func hideNavigationBar() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    /// Pins the Settings avatar in the top-trailing nav-bar slot on iOS (used on
    /// Search, whose `.searchable` field requires the nav bar). No-op on macOS.
    @ViewBuilder func trailingSettingsAvatar() -> some View {
        #if os(iOS)
        self.toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsAvatar() } }
        #else
        self
        #endif
    }
}
