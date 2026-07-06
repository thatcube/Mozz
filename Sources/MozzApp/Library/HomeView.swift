import SwiftUI
import MozzCore
import MozzDatabase
import MozzRecommend

/// The Home tab: browse surfaces built from data we already have — a "Made For
/// You" grid of precomputed mixes (Supermix, Daily/Artist mixes, Replay, Mozz
/// Weekly) alongside Liked Songs, then Recently Played / Added shelves and the
/// listener's playlists. Everything reads precomputed/local data (instant +
/// offline); generation happens off-main on a schedule.
struct HomeView: View {
    @EnvironmentObject private var env: AppEnvironment
    /// This tab's navigation path (value-based routing), owned by MainTabsView so
    /// pop-to-root and depth-preservation-on-switch work across tab changes.
    @Binding var path: [AppRoute]
    @State private var mixes: [RecommendationService.HomeMix] = []
    @State private var recentlyPlayed: [TrackRecord] = []
    @State private var recentlyAdded: [AlbumRecord] = []
    @State private var playlists: [PlaylistRecord] = []
    @State private var likedCount = 0
    @State private var loaded = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    TightHeader(title: "Home")

                    if env.active != nil {
                        madeForYouGrid
                    }
                    if !recentlyPlayed.isEmpty {
                        TrackShelf(title: "Recently Played", tracks: recentlyPlayed)
                    }
                    if !recentlyAdded.isEmpty {
                        AlbumShelf(title: "Recently Added", albums: recentlyAdded)
                    }
                    if !playlists.isEmpty {
                        PlaylistShelf(title: "Your Playlists", playlists: playlists)
                    }
                    if loaded && mixes.isEmpty && recentlyPlayed.isEmpty
                        && recentlyAdded.isEmpty && playlists.isEmpty {
                        ContentUnavailableView("Nothing Here Yet", systemImage: "house",
                            description: Text("Play something or sync your library — it'll show up here."))
                            .padding(.top, 60)
                    }
                }
                .padding(.bottom, 24)
            }
            .hideNavigationBar()
            .minimizesBottomBarOnScroll()
            .appRouteDestinations()
            .task { await load() }
            .refreshable { await load() }
        }
    }

    /// The quick-access grid: Liked Songs plus every precomputed mix, as compact
    /// two-column shortcut tiles. A NON-lazy `Grid` (the set is small and bounded)
    /// — a `LazyVGrid` here collapses the content below it after a pull-to-refresh.
    private var madeForYouGrid: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(Array(gridRows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    cell(row[0])
                    if row.count > 1 {
                        cell(row[1])
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    /// Liked Songs followed by every mix, chunked into rows of two.
    private var gridRows: [[HomeCell]] {
        let cells: [HomeCell] = [.liked] + mixes.map(HomeCell.mix)
        return stride(from: 0, to: cells.count, by: 2).map { Array(cells[$0..<min($0 + 2, cells.count)]) }
    }

    @ViewBuilder private func cell(_ cell: HomeCell) -> some View {
        switch cell {
        case .liked:
            NavigationLink(value: AppRoute.likedSongs) {
                HomeShortcutTile(title: "Liked Songs",
                                 subtitle: likedCount > 0 ? (likedCount == 1 ? "1 song" : "\(likedCount) songs") : "Tap ♥ to add") {
                    LikedSongsSquare()
                }
            }
            .buttonStyle(.plain)
        case .mix(let mix):
            NavigationLink(value: AppRoute.mix(setId: mix.id, title: mix.title,
                                               subtitle: mix.subtitle ?? "Made for You")) {
                HomeShortcutTile(title: mix.title, subtitle: mix.subtitle) {
                    ArtworkView(artwork: mix.artworkKey.map(ArtworkRef.init(key:)),
                                seed: mix.id, size: 56, cornerRadius: 0)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func load() async {
        guard let serverId = env.active?.connection.id else { loaded = true; return }
        // Read everything into locals with NO @State writes in between: writing
        // @State mid-refresh re-renders the ScrollView, which can end the refresh
        // control and cancel the remaining awaits — with `?? []` that wiped every
        // section below the grid. Assign once at the end, and only for reads that
        // succeeded (a cancelled/failed read keeps the prior value, never blank).
        let mixesResult = try? await env.recommendations.homeMixes()
        let played = try? await env.repository.recentlyPlayedTracks(serverId: serverId, limit: 20)
        let added = try? await env.repository.recentlyAddedAlbums(serverId: serverId, limit: 20)
        let lists = try? await env.repository.allPlaylists(serverId: serverId)
        let liked = try? await env.repository.likedTracksCount(serverId: serverId)

        if let mixesResult { mixes = mixesResult }
        if let played { recentlyPlayed = played }
        if let added { recentlyAdded = added }
        if let lists { playlists = lists }
        if let liked { likedCount = liked }
        loaded = true

        // Then refresh the mixes if stale (off-main) and re-read them.
        await env.ensureMozzWeekly()
        await env.ensureHomeMixes()
        if let refreshed = try? await env.recommendations.homeMixes() { mixes = refreshed }
    }

    /// One cell of the quick-access grid.
    private enum HomeCell {
        case liked
        case mix(RecommendationService.HomeMix)
    }
}

/// A compact two-column shortcut tile: a square (artwork or the Liked heart)
/// flush-left, a title and optional subtitle to the right, on a subtle material.
struct HomeShortcutTile<Leading: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        HStack(spacing: 10) {
            leading()
                .frame(width: 56, height: 56)
                .clipped()
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.trailing, 8)
            Spacer(minLength: 0)
        }
        .frame(height: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The Liked Songs square used as a shortcut tile's leading art: a subtle red
/// gradient with a white heart.
struct LikedSongsSquare: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.84, green: 0.27, blue: 0.35),
                     Color(red: 0.50, green: 0.09, blue: 0.16)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        .overlay {
            Image(systemName: "heart.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

/// A horizontal shelf of album cells that push into the album detail.
struct AlbumShelf: View {
    let title: String
    let albums: [AlbumRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold()).padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink(value: AppRoute.album(album)) {
                            AlbumCell(album: album).frame(width: 150)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

/// A horizontal shelf of track cells; tapping plays from that point.
struct TrackShelf: View {
    @EnvironmentObject private var env: AppEnvironment
    let title: String
    let tracks: [TrackRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold()).padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            env.playback.play(tracks: tracks.map { $0.toDomain() }, startAt: index)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(artwork: track.artworkKey.map(ArtworkRef.init(key:)),
                                            seed: track.albumTitle ?? track.title, size: 150, cornerRadius: 8)
                                Text(track.title).font(.subheadline).lineLimit(1)
                                Text(track.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 150)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

/// A horizontal shelf of the listener's playlists that push into the playlist detail.
struct PlaylistShelf: View {
    let title: String
    let playlists: [PlaylistRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold()).padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: AppRoute.playlist(playlist)) {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(artwork: playlist.artworkKey.map(ArtworkRef.init(key:)),
                                            seed: playlist.title, size: 150, cornerRadius: 8)
                                Text(playlist.title).font(.subheadline).lineLimit(1)
                                if let count = playlist.trackCount {
                                    Text(count == 1 ? "1 song" : "\(count) songs")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(width: 150)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}
