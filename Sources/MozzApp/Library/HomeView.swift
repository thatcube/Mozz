import SwiftUI
import MozzCore
import MozzDatabase

/// The Home tab: browse surfaces built from data we already have — the offline
/// "Mozz Weekly" rediscovery mix (from the recommendation engine), Recently
/// Played (from the play_event log), and Recently Added.
struct HomeView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var mozzWeekly: [TrackRecord] = []
    @State private var mozzWeeklyTitle = "Mozz Weekly"
    @State private var recentlyPlayed: [TrackRecord] = []
    @State private var recentlyAdded: [AlbumRecord] = []
    @State private var loaded = false

    private var mozzWeeklyRep: TrackRecord? {
        mozzWeekly.first { $0.artworkKey != nil } ?? mozzWeekly.first
    }
    private var mozzWeeklyArtwork: ArtworkRef? {
        mozzWeeklyRep?.artworkKey.map(ArtworkRef.init(key:))
    }
    private var mozzWeeklySeed: String {
        mozzWeeklyRep?.artworkKey ?? mozzWeeklyTitle
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    TightHeader(title: "Home")

                    if !mozzWeekly.isEmpty {
                        NavigationLink {
                            MozzWeeklyDetailView()
                        } label: {
                            MozzWeeklyCard(title: mozzWeeklyTitle,
                                           subtitle: mozzWeekly.count == 1 ? "1 song" : "\(mozzWeekly.count) songs",
                                           artwork: mozzWeeklyArtwork,
                                           seed: mozzWeeklySeed)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                    }
                    if !recentlyPlayed.isEmpty {
                        TrackShelf(title: "Recently Played", tracks: recentlyPlayed)
                    }
                    if !recentlyAdded.isEmpty {
                        AlbumShelf(title: "Recently Added", albums: recentlyAdded)
                    }
                    if loaded && mozzWeekly.isEmpty && recentlyPlayed.isEmpty && recentlyAdded.isEmpty {
                        ContentUnavailableView("Nothing Here Yet", systemImage: "house",
                            description: Text("Play something or sync your library — it'll show up here."))
                            .padding(.top, 60)
                    }
                }
                .padding(.bottom, 24)
            }
            .hideNavigationBar()
            .minimizesBottomBarOnScroll()
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        guard let serverId = env.active?.connection.id else { loaded = true; return }
        // Refresh the weekly mix if it's missing/stale, then read the persisted
        // set (instant + offline — no scoring happens on this path).
        await env.ensureMozzWeekly()
        mozzWeekly = (try? await env.recommendations.mozzWeeklyTracks()) ?? []
        if let set = try? await env.recommendations.mozzWeeklySet() { mozzWeeklyTitle = set.title }
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
