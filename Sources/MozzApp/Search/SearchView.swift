import SwiftUI
import MozzCore
import MozzDatabase

/// Full-text search over the local FTS5 index. Queries run against the DB with a
/// short debounce; results are grouped into artists / albums / tracks. Because
/// search hits SQLite directly, it stays well under the sub-100ms bar even at
/// 100k tracks.
///
/// At rest it shows a tight custom header ("Search" + avatar) matching Apple
/// Music's top-aligned title, plus a search field. Focusing the field collapses
/// the header, slides the field up, and reveals a Cancel button. The field uses
/// real iOS 26 Liquid Glass; we can't use the system `.searchable` here because
/// it requires a visible navigation bar, which is incompatible with the tight
/// top-aligned title. When the query is empty it shows a "Recently Searched"
/// list resolved live from the catalog.
struct SearchView: View {
    @EnvironmentObject private var env: AppEnvironment
    /// This tab's navigation path (value-based routing), owned by MainTabsView.
    @Binding var path: [AppRoute]
    @StateObject private var recents = RecentSearchStore()
    @State private var query = ""
    @State private var results = SearchResults(artists: [], albums: [], tracks: [])
    @State private var resolvedRecents: [RecentResolved] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var lastLatencyMs: Double?
    @FocusState private var focused: Bool

    /// Shared height for the search field and the cancel ✕ so they line up.
    private let fieldHeight: CGFloat = 44

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    /// Actively searching — the field is focused or a query has been entered.
    /// Drives the collapse of the title header and the Cancel button.
    private var isActive: Bool { focused || !trimmedQuery.isEmpty }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if !isActive {
                    TightHeader(title: "Search")
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                HStack(spacing: 12) {
                    searchField
                    if isActive {
                        Button { cancelSearch() } label: {
                            Image(systemName: "xmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: fieldHeight, height: fieldHeight)
                                .glassCircle()
                                .accessibilityLabel("Cancel search")
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, isActive ? 8 : 12)
                .padding(.bottom, 10)

                resultsList
                    .minimizesBottomBarOnScroll()
            }
            .animation(.snappy(duration: 0.3), value: isActive)
            .hideNavigationBar()
            .appRouteDestinations()
            .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
            .task(id: recents.items) { await resolveRecents() }
        }
    }

    /// A custom search field with real iOS 26 Liquid Glass. We can't use the
    /// system `.searchable` here because it requires a visible navigation bar,
    /// which is incompatible with the tight top-aligned title — so we recreate
    /// the field (glass material + focus animation + Cancel) to keep both.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Artists, albums, songs", text: $query)
                .focused($focused)
                .submitLabel(.search)
                .plainTextFieldStyle()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: fieldHeight)
        .glassCapsule()
    }

    private var resultsList: some View {
        List {
            if trimmedQuery.isEmpty {
                if !resolvedRecents.isEmpty {
                    Section {
                        ForEach(resolvedRecents) { recentRow($0) }
                    } header: {
                        HStack {
                            Text("Recently Searched").font(.headline).textCase(nil)
                            Spacer()
                            Button("Clear") { recents.clear() }.font(.subheadline)
                        }
                    }
                }
            } else {
                resultSections
            }
        }
        .listStyle(.plain)
        .overlay { emptyState }
        .safeAreaInset(edge: .bottom) {
            if let ms = lastLatencyMs, !trimmedQuery.isEmpty {
                Text(String(format: "found in %.1f ms", ms))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.bottom, 4)
            }
        }
    }

    // MARK: Content

    @ViewBuilder private var emptyState: some View {
        if trimmedQuery.isEmpty {
            if resolvedRecents.isEmpty {
                ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass")
            }
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    @ViewBuilder private var resultSections: some View {
        if !results.artists.isEmpty {
            Section("Artists") {
                ForEach(results.artists) { artist in
                    NavigationLink(value: AppRoute.artist(artist)) {
                        Label(artist.name, systemImage: "music.mic")
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        record(.artist, serverId: artist.serverId, remoteId: artist.remoteId)
                    })
                }
            }
        }
        if !results.albums.isEmpty {
            Section("Albums") {
                ForEach(results.albums) { album in
                    NavigationLink(value: AppRoute.album(album)) {
                        VStack(alignment: .leading) {
                            Text(album.title)
                            Text(album.artistName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        record(.album, serverId: album.serverId, remoteId: album.remoteId)
                    })
                }
            }
        }
        if !results.tracks.isEmpty {
            Section("Tracks") {
                ForEach(results.tracks) { track in
                    TrackRow(track: track, showArtist: true)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            record(.track, serverId: track.serverId, remoteId: track.remoteId)
                            env.playback.play(tracks: [track.toDomain()])
                        }
                }
            }
        }
    }

    @ViewBuilder private func recentRow(_ resolved: RecentResolved) -> some View {
        switch resolved {
        case .artist(let a):
            NavigationLink(value: AppRoute.artist(a)) {
                RecentRowLabel(artworkKey: a.artworkKey, seed: a.name,
                               title: a.name, subtitle: "Artist", circular: true)
            }
            .simultaneousGesture(TapGesture().onEnded {
                record(.artist, serverId: a.serverId, remoteId: a.remoteId)
            })
        case .album(let a):
            NavigationLink(value: AppRoute.album(a)) {
                RecentRowLabel(artworkKey: a.artworkKey, seed: a.title,
                               title: a.title, subtitle: "Album · \(a.artistName)")
            }
            .simultaneousGesture(TapGesture().onEnded {
                record(.album, serverId: a.serverId, remoteId: a.remoteId)
            })
        case .track(let t):
            Button {
                record(.track, serverId: t.serverId, remoteId: t.remoteId)
                env.playback.play(tracks: [t.toDomain()])
            } label: {
                RecentRowLabel(artworkKey: t.artworkKey, seed: t.albumTitle ?? t.title,
                               title: t.title, subtitle: "Song · \(t.artistName)")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Actions

    private func cancelSearch() {
        query = ""
        focused = false
        results = SearchResults(artists: [], albums: [], tracks: [])
        lastLatencyMs = nil
    }

    private func record(_ kind: RecentSearchItem.Kind, serverId: String, remoteId: String) {
        recents.add(RecentSearchItem(kind: kind, serverId: serverId, remoteId: remoteId))
    }

    private func resolveRecents() async {
        var out: [RecentResolved] = []
        for item in recents.items {
            switch item.kind {
            case .artist:
                if let r = try? await env.repository.artist(serverId: item.serverId, remoteId: item.remoteId) {
                    out.append(.artist(r))
                }
            case .album:
                if let r = try? await env.repository.album(serverId: item.serverId, remoteId: item.remoteId) {
                    out.append(.album(r))
                }
            case .track:
                if let r = try? await env.repository.track(serverId: item.serverId, remoteId: item.remoteId) {
                    out.append(.track(r))
                }
            }
        }
        resolvedRecents = out
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = SearchResults(artists: [], albums: [], tracks: [])
            lastLatencyMs = nil
            return
        }
        let repo = env.repository
        let serverId = env.active?.connection.id
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let start = Date()
            let found = (try? await repo.search(trimmed, serverId: serverId)) ??
                SearchResults(artists: [], albums: [], tracks: [])
            guard !Task.isCancelled else { return }
            results = found
            lastLatencyMs = Date().timeIntervalSince(start) * 1000
        }
    }
}

/// A resolved recent-search item — the live catalog record behind a
/// `RecentSearchItem`, ready to render and navigate/play.
enum RecentResolved: Identifiable {
    case artist(ArtistRecord)
    case album(AlbumRecord)
    case track(TrackRecord)

    var id: String {
        switch self {
        case .artist(let a): return "artist\u{1F}\(a.serverId)\u{1F}\(a.remoteId)"
        case .album(let a): return "album\u{1F}\(a.serverId)\u{1F}\(a.remoteId)"
        case .track(let t): return "track\u{1F}\(t.serverId)\u{1F}\(t.remoteId)"
        }
    }
}

/// A single "Recently Searched" row: artwork + title + kind/subtitle.
private struct RecentRowLabel: View {
    let artworkKey: String?
    let seed: String
    let title: String
    let subtitle: String
    var circular = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: artworkKey.map(ArtworkRef.init(key:)),
                        seed: seed, size: 44, cornerRadius: circular ? 22 : 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
