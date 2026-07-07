import SwiftUI
import MozzCore
import MozzDatabase

/// An artist on the shared immersive scaffold: a full-bleed hero that fades into
/// the artwork's color, Play/Shuffle, a "Top Songs" section (5, with See All →
/// the full list), and horizontal Albums / Singles shelves. (Playlists shelf is
/// deferred — the schema has no artist↔playlist association.)
struct ArtistDetailView: View {
    @EnvironmentObject private var env: AppEnvironment
    let artist: ArtistRecord

    @State private var songs: [TrackRecord] = []
    @State private var albums: [AlbumRecord] = []
    @State private var loaded = false

    private var topSongs: [TrackRecord] { Array(songs.prefix(5)) }
    private var fullAlbums: [AlbumRecord] { albums.filter { ($0.trackCount ?? 99) > 3 } }
    private var singles: [AlbumRecord] { albums.filter { ($0.trackCount ?? 99) <= 3 } }

    /// Artists frequently have no art of their own — fall back to a representative
    /// album cover so the hero still blooms with color.
    private var heroArtwork: ArtworkRef? {
        if let key = artist.artworkKey { return ArtworkRef(key: key) }
        if let key = albums.first(where: { $0.artworkKey != nil })?.artworkKey { return ArtworkRef(key: key) }
        return nil
    }

    private var metaLine: String? {
        guard loaded, !albums.isEmpty else { return nil }
        return albums.count == 1 ? "1 album" : "\(albums.count) albums"
    }

    var body: some View {
        MediaDetailScaffold(
            hero: MediaHero(style: .fullBleed, artwork: heroArtwork, seed: artist.name),
            title: artist.name,
            meta: metaLine,
            contentHorizontalPadding: 0,
            actions: { DetailPlayActions(play: { play(from: 0) }, shuffle: shuffle, startRadio: startRadio) },
            content: {
                VStack(alignment: .leading, spacing: 30) {
                    if !topSongs.isEmpty { topSongsSection }
                    if !fullAlbums.isEmpty { ArtistAlbumShelf(title: "Albums", albums: fullAlbums) }
                    if !singles.isEmpty { ArtistAlbumShelf(title: "Singles & EPs", albums: singles) }
                    if loaded && songs.isEmpty && albums.isEmpty {
                        ContentUnavailableView("Nothing Here Yet", systemImage: "music.mic")
                            .padding(.top, 40)
                    }
                }
                .padding(.top, 4)
            }
        )
        .task { await load() }
        .handoff(DeepLinkTarget.artistActivity, id: artist.remoteId, title: artist.name)
    }

    private var topSongsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Top Songs").font(.title3.bold())
                Spacer()
                if songs.count > topSongs.count {
                    NavigationLink(value: AppRoute.artistAllSongs(artist)) {
                        Text("See All").font(.subheadline)
                    }
                }
            }
            .padding(.horizontal, 16)
            LazyVStack(spacing: 0) {
                ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, track in
                    ArtistTopSongRow(track: track)
                        .contentShape(Rectangle())
                        .onTapGesture { play(from: index) }
                    if index < topSongs.count - 1 {
                        Divider().padding(.leading, 68)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func play(from index: Int) {
        env.playback.play(tracks: songs.map { $0.toDomain() }, startAt: index)
    }

    private func shuffle() {
        env.playback.playShuffled(songs.map { $0.toDomain() })
    }

    /// An endless station seeded from this artist: the artist plus same-genre
    /// neighbours (genres unioned from the artist's tracks).
    private func startRadio() {
        let genres = Array(Set(songs.flatMap { $0.genres })).prefix(8)
        env.startRadio(artistRemoteId: artist.remoteId, name: artist.name, genres: Array(genres))
    }

    private func load() async {
        guard let serverId = env.active?.connection.id else { loaded = true; return }
        albums = (try? await env.repository.albums(forArtistRemoteId: artist.remoteId, serverId: serverId)) ?? []
        songs = (try? await env.repository.topTracks(forArtistRemoteId: artist.remoteId, serverId: serverId, limit: 500)) ?? []
        loaded = true
    }
}

/// A "Top Songs" row: album-art thumbnail + title + album name + duration
/// (Apple-Music-style; no misleading album track number).
struct ArtistTopSongRow: View {
    let track: TrackRecord
    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: track.artworkKey.map(ArtworkRef.init(key:)),
                        seed: track.albumTitle ?? track.title, size: 44, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                if let album = track.albumTitle, !album.isEmpty {
                    Text(album).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(Format.duration(track.duration))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            SongActionsMenu(track: track)
        }
        .padding(.vertical, 6)
    }
}

/// A horizontal shelf of album covers that push into the album detail.
struct ArtistAlbumShelf: View {
    let title: String
    let albums: [AlbumRecord]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold()).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink(value: AppRoute.album(album)) {
                            AlbumCell(album: album).frame(width: 150)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

/// The full ranked song list behind an artist's "See All". Loads its own songs
/// (same `topTracks` query the artist page uses) so the route carries only the
/// artist — no heavy `[TrackRecord]` payload in the navigation path.
struct ArtistAllSongsView: View {
    @EnvironmentObject private var env: AppEnvironment
    let artist: ArtistRecord
    @State private var songs: [TrackRecord] = []

    var body: some View {
        List {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, showArtist: false)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        env.playback.play(tracks: songs.map { $0.toDomain() }, startAt: index)
                    }
            }
        }
        .listStyle(.plain)
        .navigationTitle("\(artist.name) · Songs")
        .inlineNavigationTitle()
        .task {
            guard let serverId = env.active?.connection.id else { return }
            songs = (try? await env.repository.topTracks(
                forArtistRemoteId: artist.remoteId, serverId: serverId, limit: 500)) ?? []
        }
    }
}

struct AlbumCell: View {
    let album: AlbumRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(artwork: album.artworkKey.map(ArtworkRef.init(key:)), seed: album.title, size: 150, cornerRadius: 8)
                .frame(maxWidth: .infinity)
            Text(album.title).font(.subheadline).lineLimit(1)
            Text(album.year.map(String.init) ?? album.artistName)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
