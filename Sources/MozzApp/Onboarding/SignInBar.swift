import SwiftUI

/// A prominent, full-width primary action pinned at the bottom of a login form
/// (via `.safeAreaInset(edge: .bottom)`). Using a dedicated filled button —
/// rather than a plain row inside the `Form` — gives the primary sign-in action
/// a clear, always-reachable affordance, which is both the conventional iOS
/// pattern for a login CTA and easier to find with VoiceOver / Switch Control.
struct SignInBar: View {
    let title: String
    var isBusy: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().tint(Color.mozzProminentLabel)
                }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.mozzProminent)
        .disabled(!isEnabled || isBusy)
        .accessibilityLabel(isBusy ? "Signing in" : title)
        .padding()
        .background(.bar)
    }
}
