#if os(iOS)
import Intents
import SwiftUI
import UIKit

/// The Settings entry for Siri, and the only place the HomePod story is told.
///
/// Two things are worth surfacing here. Siri needs permission before it may look
/// at the library at all, and iOS otherwise asks for it the first time someone
/// speaks a request — which, when that request came from a HomePod, means a
/// confusing failure with the phone in another room. And nothing else in the app
/// would ever tell someone that asking a speaker for music off their own server
/// is possible in the first place.
struct SiriSettingsSection: View {
    @State private var status = INPreferences.siriAuthorizationStatus()

    var body: some View {
        Section {
            switch status {
            case .authorized:
                LabeledContent {
                    Text("On")
                } label: {
                    Label("Siri", mozz: "music.mic")
                }
            case .notDetermined:
                Button(action: requestAuthorization) {
                    Label("Use Mozz with Siri", mozz: "music.mic")
                }
            default:
                Button(action: openSystemSettings) {
                    LabeledContent {
                        Text("Off")
                    } label: {
                        Label("Siri", mozz: "music.mic")
                    }
                }
                .accessibilityHint("Opens Settings, where Siri can be turned on for Mozz")
            }
            Text(Self.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Siri & HomePod")
        }
    }

    private static let explanation = """
        Ask by name — "Play Miles Davis on Mozz." Works from a HomePod too, \
        with Recognize My Voice on in the Home app.
        """

    private func requestAuthorization() {
        INPreferences.requestSiriAuthorization { newStatus in
            Task { @MainActor in status = newStatus }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
#endif
