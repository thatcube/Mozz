import SwiftUI
import MozzCore

/// Lets the user choose which Plex server to use (an account can have several)
/// and which of that server's music libraries to sync (all by default). Switching
/// server re-activates + re-syncs; applying a library selection re-syncs with just
/// the chosen libraries (deselected ones are pruned on the next sync).
struct PlexLibraryPickerView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var servers: [PlexServerOption] = []
    @State private var libraries: [PlexMusicLibraryOption] = []
    @State private var selected: Set<String> = []
    @State private var loaded = false
    @State private var isSwitching = false

    /// The selection persisted at load time — used to disable "Apply" until the
    /// user actually changes something.
    private var savedSelection: Set<String> {
        Set(libraries.filter(\.isSelected).map(\.id))
    }

    var body: some View {
        Form {
            if !loaded {
                Section { HStack(spacing: 10) { ProgressView(); Text("Loading your Plex servers…") } }
            } else {
                if servers.count > 1 {
                    Section {
                        // Menu Picker = one clean "Server ▸ <current>" row (no
                        // duplicate label, no non-selectable header row) that opens
                        // an accessible single-select menu. Choosing switches server.
                        Picker("Server", selection: serverSelection) {
                            ForEach(servers) { server in
                                Text(server.name).tag(server.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(isSwitching)
                        if isSwitching {
                            HStack(spacing: 10) { ProgressView(); Text("Switching server…") }
                        }
                    }
                }

                Section {
                    if libraries.count <= 1 {
                        // Nothing to choose with a single library — show it as
                        // informational (a lone toggle you could turn off but never
                        // turn back on would be a trap).
                        ForEach(libraries) { library in
                            LabeledContent(library.title) {
                                Text("Syncing").foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        // Toggles = accessible multi-select: VoiceOver announces
                        // each as a switch with its on/off state.
                        ForEach(libraries) { library in
                            Toggle(library.title, isOn: librarySelection(library.id))
                        }
                    }
                } header: {
                    Text("Music Libraries")
                } footer: {
                    Text(libraryFooter)
                }

                if libraries.count > 1 {
                    Section {
                        Button("Sync Selected Libraries") { apply() }
                            .disabled(selected.isEmpty || selected == savedSelection || isSwitching)
                    }
                }
            }
        }
        .navigationTitle("Plex Libraries")
        .inlineNavigationTitle()
        .task { await load() }
    }

    private var libraryFooter: String {
        if libraries.isEmpty { return "This server has no music libraries." }
        if libraries.count == 1 {
            return "Mozz syncs this library. When a server has more than one music library, you can choose which to sync here."
        }
        return "All libraries sync by default. Deselected libraries won't sync and their tracks are removed on the next sync."
    }

    /// Single-select binding for the server Picker: reads the current server,
    /// and switches when a different one is chosen.
    private var serverSelection: Binding<String> {
        Binding(
            get: { servers.first(where: \.isCurrent)?.id ?? "" },
            set: { newID in switchTo(id: newID) }
        )
    }

    /// Per-library on/off binding for the Toggles.
    private func librarySelection(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                if isOn { selected.insert(id) } else { selected.remove(id) }
            }
        )
    }

    private func load() async {
        servers = await env.plexServers()
        libraries = await env.plexMusicLibraries()
        selected = Set(libraries.filter(\.isSelected).map(\.id))
        loaded = true
    }

    private func switchTo(id newID: String) {
        guard !newID.isEmpty, !isSwitching,
              newID != servers.first(where: \.isCurrent)?.id else { return }
        isSwitching = true
        loaded = false
        Task {
            await env.selectPlexServer(id: newID)
            await load()
            isSwitching = false
        }
    }

    private func apply() {
        env.setSelectedMusicLibraries(Array(selected))
        dismiss()
    }
}
