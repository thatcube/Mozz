import SwiftUI

/// Dedicated appearance page (pushed from Settings). Self-explanatory rows, no
/// description blurbs: theme override, which dark flavor to use, and the player's
/// Liquid Glass chrome.
struct AppearanceSettingsView: View {
    @AppStorage(Color.MozzAppearance.storageKey) private var appearanceRaw = Color.MozzAppearance.default.rawValue
    @AppStorage(Color.MozzDarkStyle.storageKey) private var darkStyleRaw = Color.MozzDarkStyle.default.rawValue
    @AppStorage("mozz.liquidGlass") private var liquidGlassEnabled = true

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $appearanceRaw) {
                    ForEach(Color.MozzAppearance.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Dark Style", selection: $darkStyleRaw) {
                    ForEach(Color.MozzDarkStyle.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            Section {
                Toggle("Liquid Glass", isOn: $liquidGlassEnabled)
            }
        }
        .navigationTitle("Appearance")
        .inlineNavigationTitle()
    }
}
