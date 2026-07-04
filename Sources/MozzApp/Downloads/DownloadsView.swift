import SwiftUI
import MozzCore
import MozzDatabase

/// Lists tracks available offline, shows total storage used, and allows deleting
/// downloads. Everything here is backed by the DB's download table, so it works
/// with no network.
struct DownloadsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var tracks: [TrackRecord] = []
    @State private var usage = StorageUsage()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label("Storage Used", systemImage: "internaldrive")
                        Spacer()
                        Text(Format.bytes(usage.totalBytes)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Offline Tracks")
                        Spacer()
                        Text("\(usage.downloadedTrackCount)").foregroundStyle(.secondary)
                    }
                }
                Section("Downloaded") {
                    ForEach(tracks) { track in
                        TrackRow(track: track, downloadState: .downloaded, showArtist: true)
                            .contentShape(Rectangle())
                            .onTapGesture { env.playback.play(tracks: [track.toDomain()]) }
                    }
                    .onDelete(perform: delete)
                }
            }
            .navigationTitle("Downloads")
            .overlay {
                if tracks.isEmpty {
                    ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                        description: Text("Download albums to play them offline."))
                }
            }
            .task { await refresh() }
            .refreshable { await refresh() }
        }
    }

    private func refresh() async {
        tracks = (try? await env.repository.downloadedTracks()) ?? []
        usage = (try? await env.repository.storageUsage()) ?? StorageUsage()
    }

    private func delete(at offsets: IndexSet) {
        let toDelete = offsets.compactMap { tracks[$0].id }
        Task {
            for id in toDelete {
                try? await env.downloads.deleteDownload(trackInternalId: id)
            }
            await refresh()
        }
    }
}
