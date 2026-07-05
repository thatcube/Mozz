import SwiftUI
import MozzCore
import MozzDatabase

/// A scroll-away screen header: a large title with the Settings avatar at the
/// trailing edge, on the same line. Placed as the first item in a screen's
/// scrolling content so the title lands in the same spot on every tab and the
/// avatar is always aligned with it.
struct ScreenHeader: View {
    let title: String

    var body: some View {
        HStack(alignment: .center) {
            Text(title).font(.largeTitle.bold())
            Spacer()
            SettingsAvatar()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// The Home tab: a browse surface built from data we already have — Recently
/// Played (from the on-device play_event log) and Recently Added — with room to
/// grow into recommendation shelves once track_features lands.
struct HomeView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var recentlyPlayed: [TrackRecord] = []
    @State private var recentlyAdded: [AlbumRecord] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ScreenHeader(title: "Home")

                    if !recentlyPlayed.isEmpty {
                        TrackShelf(title: "Recently Played", tracks: recentlyPlayed)
                    }
                    if !recentlyAdded.isEmpty {
                        AlbumShelf(title: "Recently Added", albums: recentlyAdded)
                    }
                    if loaded && recentlyPlayed.isEmpty && recentlyAdded.isEmpty {
                        ContentUnavailableView("Nothing Here Yet", systemImage: "house",
                            description: Text("Play something or sync your library — it'll show up here."))
                            .padding(.top, 60)
                    }
                }
                .padding(.bottom, 24)
            }
            .hideNavigationBar()
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        guard let serverId = env.active?.connection.id else { loaded = true; return }
        recentlyPlayed = (try? await env.repository.recentlyPlayedTracks(serverId: serverId, limit: 20)) ?? []
        recentlyAdded = (try? await env.repository.recentlyAddedAlbums(serverId: serverId, limit: 20)) ?? []
        loaded = true
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
                        NavigationLink {
                            AlbumDetailView(album: album)
                        } label: {
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
