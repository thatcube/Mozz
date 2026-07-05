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

    /// A large navigation-bar title on iOS (the standard collapsing large title
    /// every top-level screen shares). On the macOS test host it just sets the
    /// title (no display-mode API).
    @ViewBuilder func largeNavigationTitle(_ title: String) -> some View {
        #if os(iOS) || os(tvOS)
        self.navigationTitle(title).navigationBarTitleDisplayMode(.large)
        #else
        self.navigationTitle(title)
        #endif
    }

    /// Pins the Settings avatar in the top-trailing nav-bar slot (iOS). No-op on
    /// the macOS test host, where `.topBarTrailing` is unavailable.
    @ViewBuilder func settingsToolbarAvatar() -> some View {
        #if os(iOS)
        self.toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsAvatar() } }
        #else
        self
        #endif
    }

    /// The system `.searchable` search field, kept always-visible below the
    /// large title on iOS (the Apple Music look) via the navigation-bar drawer.
    /// On the macOS test host it falls back to the default placement so the code
    /// still compiles.
    @ViewBuilder func librarySearchable(text: Binding<String>, prompt: String) -> some View {
        #if os(iOS)
        self.searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        #else
        self.searchable(text: text, prompt: prompt)
        #endif
    }
}
