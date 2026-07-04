import SwiftUI
import MozzCore
import MozzDatabase
import MozzDownloads

/// An album's track list with play, shuffle, and offline-download controls.
/// Download state is read from the DB and reflected live via the
/// ``DownloadManager`` progress map.
struct AlbumDetailView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var downloads: DownloadManager
    let album: AlbumRecord

    @State private var tracks: [TrackRecord] = []
    @State private var downloadStates: [Int64: DownloadState] = [:]
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                header
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            Section {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(
                        track: track,
                        downloadState: track.id.flatMap { downloadStates[$0] },
                        progress: track.id.flatMap { downloads.progress[$0] }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { play(from: index) }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(album.title)
        .inlineNavigationTitle()
        .task { await load() }
        .onChange(of: downloads.progress.count) { _, _ in
            Task { await refreshDownloadStates() }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(artwork: album.artworkKey.map(ArtworkRef.init(key:)), seed: album.title, size: 200, cornerRadius: 12)
            VStack(spacing: 2) {
                Text(album.title).font(.title3.bold()).multilineTextAlignment(.center)
                Text(album.artistName).foregroundStyle(.secondary)
                if let year = album.year {
                    Text(String(year)).font(.caption).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 12) {
                Button { play(from: 0) } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button { shuffle() } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button {
                Task {
                    await env.downloadAlbum(remoteId: album.remoteId)
                    await refreshDownloadStates()
                }
            } label: {
                Label("Download Album", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(env.active?.capabilities.supportsOriginalFileDownload == false)
        }
        .frame(maxWidth: .infinity)
    }

    private func play(from index: Int) {
        let domain = tracks.map { $0.toDomain() }
        env.playback.play(tracks: domain, startAt: index)
    }

    private func shuffle() {
        let domain = tracks.map { $0.toDomain() }
        env.playback.setShuffle(true)
        env.playback.play(tracks: domain, startAt: 0)
    }

    private func load() async {
        guard let serverId = env.active?.connection.id else { return }
        tracks = (try? await env.repository.tracks(forAlbumRemoteId: album.remoteId, serverId: serverId)) ?? []
        loaded = true
        await refreshDownloadStates()
    }

    private func refreshDownloadStates() async {
        let records = (try? await env.repository.downloads()) ?? []
        var map: [Int64: DownloadState] = [:]
        for record in records {
            if let state = record.downloadState { map[record.trackId] = state }
        }
        downloadStates = map
    }
}

struct TrackRow: View {
    let track: TrackRecord
    var downloadState: DownloadState?
    var progress: Double?
    var showArtist = false

    var body: some View {
        HStack(spacing: 12) {
            if let n = track.trackNumber, !showArtist {
                Text("\(n)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                if showArtist {
                    Text(track.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            downloadIndicator
            Text(Format.duration(track.duration))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var downloadIndicator: some View {
        switch downloadState {
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green).font(.caption)
        case .downloading, .queued:
            ProgressView(value: progress ?? 0).frame(width: 40)
        case .failed:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
        case nil:
            EmptyView()
        }
    }
}
