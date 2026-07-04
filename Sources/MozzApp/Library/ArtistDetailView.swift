import SwiftUI
import MozzCore
import MozzDatabase

/// Shows an artist's albums, read from the local DB by the artist's remote id.
struct ArtistDetailView: View {
    @EnvironmentObject private var env: AppEnvironment
    let artist: ArtistRecord

    @State private var albums: [AlbumRecord] = []
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(albums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        AlbumCell(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(artist.name)
        .inlineNavigationTitle()
        .overlay {
            if albums.isEmpty && loaded {
                ContentUnavailableView("No Albums", systemImage: "square.stack")
            }
        }
        .task {
            guard let serverId = env.active?.connection.id else { return }
            albums = (try? await env.repository.albums(forArtistRemoteId: artist.remoteId, serverId: serverId)) ?? []
            loaded = true
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
