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

    /// The Apple Music-style top bar: the large title with the Settings avatar
    /// aligned to its trailing edge, on the same line. iOS 26's
    /// `ToolbarItemPlacement.largeTitle` hosts custom content *in* the large-title
    /// row, so we lay out the title + avatar there ourselves to get exact
    /// alignment (a lone item would center and drop the text). `.navigationTitle`
    /// still drives the collapsed/inline title and pushed-view back button.
    /// On iOS 17–25 we fall back to a standard large title with the avatar in the
    /// top-trailing slot; on the macOS test host it's just the title.
    @ViewBuilder func musicNavigationBar(_ title: String) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .largeTitle) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(title).font(.largeTitle.bold())
                            Spacer(minLength: 12)
                            SettingsAvatar().alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
        } else {
            self.navigationTitle(title)
                .navigationBarTitleDisplayMode(.large)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsAvatar() } }
        }
        #else
        self.navigationTitle(title)
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
