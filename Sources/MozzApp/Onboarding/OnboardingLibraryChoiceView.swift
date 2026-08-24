import SwiftUI

/// Shown during sign-in when the server has more than one music library, so the
/// user picks before the first sync runs rather than discovering afterwards that
/// Mozz indexed the wrong one.
///
/// Skipped entirely for a single-library server — `AppEnvironment` only
/// populates `libraryChoice` when there is a genuine choice.
struct OnboardingLibraryChoiceView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var selected: Set<String> = []

    private var isMultiSelect: Bool { env.supportsMultipleLibraries }

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)

            Image(mozz: "square.stack.3d.up")
                .resizable().scaledToFit().frame(width: 46, height: 46)
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text(isMultiSelect ? "Choose your libraries" : "Choose your library")
                    .font(.title2.bold())
                Text(isMultiSelect
                     ? "This server has more than one music library. Pick the ones you want in Mozz."
                     : "This server has more than one music library. Pick the one you want in Mozz.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            List(env.libraryChoice) { library in
                Button {
                    if isMultiSelect {
                        if selected.contains(library.id) {
                            selected.remove(library.id)
                        } else {
                            selected.insert(library.id)
                        }
                    } else {
                        selected = [library.id]
                    }
                } label: {
                    HStack {
                        Text(library.title).foregroundStyle(.primary)
                        Spacer()
                        if selected.contains(library.id) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .accessibilityAddTraits(selected.contains(library.id) ? [.isSelected] : [])
            }
            .listStyle(.plain)
            .frame(maxHeight: 320)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button("Continue") {
                    env.applyOnboardingLibraryChoice(Array(selected))
                }
                .buttonStyle(.mozzProminent)
                .disabled(selected.isEmpty)

                // An escape hatch, so an unexpected library list can never trap
                // someone on this screen. Empty selection = whatever the server
                // would have picked on its own, i.e. today's behaviour.
                Button("Use all of them") {
                    env.applyOnboardingLibraryChoice([])
                }
                .font(.subheadline)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .task {
            // Preselect what the server would have used anyway, so Continue is
            // live immediately and the default matches the old behaviour.
            selected = Set(env.libraryChoice.filter(\.isSelected).map(\.id))
        }
    }
}
