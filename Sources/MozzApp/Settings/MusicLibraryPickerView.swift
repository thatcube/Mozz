import SwiftUI

/// Lets the user choose which music library Mozz syncs, for any backend that has
/// more than one.
///
/// Only shown when the server reports several: Plex library sections, Jellyfin
/// music views, or Subsonic music folders. A single-library server has nothing
/// to choose and never sees this.
///
/// Selection is multi-choice only on Plex, which can genuinely span several
/// sections. Jellyfin and Subsonic scope through a single id, so offering
/// several checkboxes there would promise something the sync cannot deliver.
struct MusicLibraryPickerView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var libraries: [MusicLibraryOption] = []
    @State private var selected: Set<String> = []
    @State private var loaded = false

    private var savedSelection: Set<String> {
        Set(libraries.filter(\.isSelected).map(\.id))
    }

    private var isMultiSelect: Bool { env.supportsMultipleLibraries }

    var body: some View {
        Form {
            if !loaded {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading your libraries…")
                    }
                }
            } else if libraries.isEmpty {
                Section {
                    Text("This server has a single music library, so there's nothing to choose.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(libraries) { library in
                        row(for: library)
                    }
                } footer: {
                    Text(isMultiSelect
                         ? "Mozz syncs the libraries you pick. Unpicked ones are removed on the next sync."
                         : "Mozz syncs one library at a time. Switching re-syncs, replacing what's stored.")
                }
            }
        }
        .mozzGroupedList()
        .navigationTitle("Music Library")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    env.applyLibrarySelection(Array(selected))
                    dismiss()
                }
                .disabled(selected.isEmpty || selected == savedSelection)
            }
        }
        .task {
            libraries = await env.musicLibraries()
            selected = savedSelection
            loaded = true
        }
    }

    @ViewBuilder
    private func row(for library: MusicLibraryOption) -> some View {
        if isMultiSelect {
            // Toggles are an accessible multi-select: VoiceOver announces each
            // as a switch with its state.
            Toggle(library.title, isOn: Binding(
                get: { selected.contains(library.id) },
                set: { on in
                    if on { selected.insert(library.id) } else { selected.remove(library.id) }
                }
            ))
        } else {
            Button {
                selected = [library.id]
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
    }
}
