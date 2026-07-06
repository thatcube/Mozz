import SwiftUI
import MozzCore
import MozzDatabase
import MozzDownloads

/// An album on the shared media-detail scaffold: a full square cover hero that
/// fades into the extracted color, Play/Shuffle + Download actions, and numbered
/// track rows with a footer (year · N songs · duration).
struct AlbumDetailView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var downloads: DownloadManager
    let album: AlbumRecord

    @State private var tracks: [TrackRecord] = []
    @State private var downloadStates: [Int64: DownloadState] = [:]
    @State private var loaded = false

    private var canDownload: Bool { env.active?.capabilities.supportsOriginalFileDownload != false }

    var body: some View {
        MediaDetailScaffold(
            hero: MediaHero(style: .centeredArtwork,
                            artwork: album.artworkKey.map(ArtworkRef.init(key:)),
                            seed: album.title),
            title: album.title,
            subtitle: album.artistName,
            meta: metaLine,
            actions: {
                VStack(spacing: 10) {
                    DetailPlayActions(play: { play(from: 0) }, shuffle: shuffle)
                    if canDownload {
                        Button {
                            Task {
                                await env.downloadAlbum(groupKey: album.albumGroupKey)
                                await refreshDownloadStates()
                            }
                        } label: {
                            Label("Download Album", systemImage: "arrow.down.circle")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .controlSize(.large)
                    }
                }
            },
            content: {
                DetailSongRows(
                    tracks: tracks,
                    showArtist: false,
                    downloadStates: downloadStates,
                    progress: downloads.progress,
                    onPlay: { play(from: $0) }
                )
            }
        )
        .task { await load() }
        .onChange(of: downloads.progress.count) { _, _ in
            Task { await refreshDownloadStates() }
        }
    }

    /// "2021 · 12 songs · 48 min" — omits pieces that aren't known yet.
    private var metaLine: String? {
        guard loaded else { return album.year.map(String.init) }
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append(tracks.count == 1 ? "1 song" : "\(tracks.count) songs")
        let total = Format.longDuration(tracks.reduce(0) { $0 + $1.duration })
        if !total.isEmpty { parts.append(total) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func play(from index: Int) {
        env.playback.play(tracks: tracks.map { $0.toDomain() }, startAt: index)
    }

    private func shuffle() {
        env.playback.setShuffle(true)
        env.playback.play(tracks: tracks.map { $0.toDomain() }, startAt: 0)
    }

    private func load() async {
        guard let serverId = env.active?.connection.id else { return }
        tracks = (try? await env.repository.tracks(forAlbumGroupKey: album.albumGroupKey, serverId: serverId)) ?? []
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
            if showArtist {
                // Multi-album context (Liked Songs, full song list, mixes,
                // playlists): show the track's album cover. Inside an album every
                // row shares one cover, so `showArtist` is off and we show the
                // track number instead.
                ArtworkView(artwork: track.artworkKey.map(ArtworkRef.init(key:)),
                            seed: track.albumTitle ?? track.title, size: 44, cornerRadius: 6)
            } else if let n = track.trackNumber {
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
            SongActionsMenu(track: track, downloadState: downloadState)
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
