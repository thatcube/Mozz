import SwiftUI

/// Dedicated appearance page (pushed from Settings). Self-explanatory rows, no
/// description blurbs: theme override, which dark flavor to use, and the player's
/// Liquid Glass chrome.
struct AppearanceSettingsView: View {
    @AppStorage(Color.MozzAppearance.storageKey) private var appearanceRaw = Color.MozzAppearance.default.rawValue
    @AppStorage(Color.MozzDarkStyle.storageKey) private var darkStyleRaw = Color.MozzDarkStyle.default.rawValue
    @AppStorage("mozz.liquidGlass") private var liquidGlassEnabled = true

    @Environment(\.colorScheme) private var scheme
    private var blackout: Bool {
        scheme == .dark && (Color.MozzDarkStyle(rawValue: darkStyleRaw) ?? .default) == .black
    }

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
                    .disabled(blackout)
            } footer: {
                // Rather than leave a switch that flips and changes nothing:
                // glass is a lit, frosted surface, which is a lighter shade of
                // whatever is behind it by definition — the one thing Black
                // does not allow.
                if blackout {
                    Text("Off in Black, which has no lifted surfaces.")
                }
            }
        }
        .mozzGroupedList()
        .mozzReadableWidth()
        .navigationTitle("Appearance")
        .inlineNavigationTitle()
    }
}
