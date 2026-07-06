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
                    Section("Server") {
                        ForEach(servers) { server in
                            Button { switchTo(server) } label: {
                                HStack {
                                    Text(server.name).foregroundStyle(.primary)
                                    Spacer()
                                    if server.isCurrent {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .disabled(isSwitching || server.isCurrent)
                        }
                        if isSwitching {
                            HStack(spacing: 10) { ProgressView(); Text("Switching server…") }
                        }
                    }
                }

                Section {
                    ForEach(libraries) { library in
                        Button { toggle(library.id) } label: {
                            HStack {
                                Text(library.title).foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(library.id) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Music Libraries")
                } footer: {
                    Text(libraries.isEmpty
                         ? "This server has no music libraries."
                         : "All libraries sync by default. Deselected libraries won't sync and their tracks are removed on the next sync.")
                }

                if !libraries.isEmpty {
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

    private func load() async {
        servers = await env.plexServers()
        libraries = await env.plexMusicLibraries()
        selected = Set(libraries.filter(\.isSelected).map(\.id))
        loaded = true
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func switchTo(_ server: PlexServerOption) {
        isSwitching = true
        loaded = false
        Task {
            await env.selectPlexServer(id: server.id)
            await load()
            isSwitching = false
        }
    }

    private func apply() {
        env.setSelectedMusicLibraries(Array(selected))
        dismiss()
    }
}
