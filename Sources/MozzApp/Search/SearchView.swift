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
    /// True once the page has scrolled off its top. Drives the search field's
    /// at-rest gray fill → Liquid Glass swap so content shows through it as it
    /// pins, matching the system search bar.
    @State private var scrolled = false
    @FocusState private var focused: Bool

    /// Shared height for the search field and the cancel ✕ so they line up.
    private let fieldHeight: CGFloat = 44

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    /// Actively searching — the field is focused or a query has been entered.
    /// Drives the collapse of the title header and the Cancel button.
    private var isActive: Bool { focused || !trimmedQuery.isEmpty }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                // Only the search field pins (it's the section header); the title
                // + avatar sit above it as ordinary content so they scroll away
                // 1:1 like the system large title, and every other header
                // ("Recently Searched", "Artists", …) is plain inline content so
                // it scrolls too.
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !isActive {
                        TightHeader(title: "Search")
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Section {
                        resultsContent
                    } header: {
                        searchFieldBar
                    }
                }
                // Scope the header collapse animation to the content only, so it
                // doesn't compound with the keyboard's safe-area animation on the
                // outer ScrollView (that pairing could thrash the pinned layout).
                .animation(.snappy(duration: 0.3), value: isActive)
            }
            .overlay { emptyState }
            .safeAreaInset(edge: .bottom) { latencyLabel }
            .tracksScrolled($scrolled)
            .minimizesBottomBarOnScroll()
            .scrollsToTopOnSignal()
            .hideNavigationBar()
            .appRouteDestinations()
            .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
            .task(id: recents.items) { await resolveRecents() }
        }
    }

    /// The pinned top bar: the search field (+ Cancel while active). Its
    /// background is left clear so, once pinned, the scrolling content shows
    /// around/through the Liquid Glass pill — like the native search bar.
    private var searchFieldBar: some View {
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
    }

    /// A custom search field. We can't use the system `.searchable` here because
    /// it requires a visible navigation bar, which is incompatible with the tight
    /// top-aligned title — so we recreate the field (focus animation + Cancel).
    /// At rest it's a plain theme-aware gray fill (no glass); once the page
    /// scrolls (or the field is focused) it becomes real Liquid Glass so content
    /// shows through it as it pins, matching the system search bar.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Artists, albums, songs", text: $query)
                .focused($focused)
                .submitLabel(.search)
                .plainTextFieldStyle()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: fieldHeight, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear text")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: fieldHeight)
        // The gray/glass surface lives in a BACKGROUND layer, never wrapping the
        // content — so the TextField's identity is stable (swapping it on focus
        // was tearing down the field mid-first-responder and freezing the app),
        // and the glass is genuinely ABSENT at rest (Apple's field is a plain
        // gray capsule until it pins under scrolling content — no glass, no glass
        // shadow). The glass only fades in once scrolled/focused.
        .background {
            ZStack {
                Capsule().fill(Color.searchFieldRest)
                    .opacity(fieldShowsGlass ? 0 : 1)
                if fieldShowsGlass {
                    GlassCapsuleFill().transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: fieldShowsGlass)
        }
        // The visible pill is 44pt tall, but a bare custom TextField only takes
        // focus when the glyphs themselves are tapped — the icon, padding and
        // capsule margins are dead zones (unlike the system search bar, which
        // forwards a tap anywhere in the pill). Make the whole capsule the tap
        // target so focusing matches native's larger hit area.
        .contentShape(Capsule())
        .onTapGesture { focused = true }
    }

    /// The field shows Liquid Glass once the page has scrolled off the top or the
    /// field is focused; at rest at the top it's the gray fill.
    private var fieldShowsGlass: Bool { scrolled || isActive }

    @ViewBuilder private var resultsContent: some View {
        if trimmedQuery.isEmpty {
            if !resolvedRecents.isEmpty {
                recentlyHeader
                ForEach(resolvedRecents) { resolved in
                    VStack(spacing: 0) {
                        recentRow(resolved)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 5)
                        rowDivider
                    }
                }
            }
        } else {
            resultSections
        }
    }

    /// Non-sticky "Recently Searched" header with its Clear button — plain scroll
    /// content (unlike the old sticky `List` section header).
    private var recentlyHeader: some View {
        HStack {
            Text("Recently Searched").font(.headline)
            Spacer()
            Button("Clear") { recents.clear() }.font(.subheadline)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    /// A plain, non-sticky result category header ("Artists" / "Albums" / …).
    private func inlineHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    /// Row separator, inset past the 44pt artwork (matching the native list).
    private var rowDivider: some View { Divider().padding(.leading, 76) }

    @ViewBuilder private var latencyLabel: some View {
        if let ms = lastLatencyMs, !trimmedQuery.isEmpty {
            Text(String(format: "found in %.1f ms", ms))
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.bottom, 4)
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
            inlineHeader("Artists")
            ForEach(results.artists) { artist in
                VStack(spacing: 0) {
                    Button {
                        record(.artist, serverId: artist.serverId, remoteId: artist.remoteId)
                        path.append(.artist(artist))
                    } label: {
                        SearchResultRow(artworkKey: artist.artworkKey, seed: artist.name,
                                        title: artist.name, circular: true)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 5)
                    rowDivider
                }
            }
        }
        if !results.albums.isEmpty {
            inlineHeader("Albums")
            ForEach(results.albums) { album in
                VStack(spacing: 0) {
                    Button {
                        record(.album, serverId: album.serverId, remoteId: album.remoteId)
                        path.append(.album(album))
                    } label: {
                        SearchResultRow(artworkKey: album.artworkKey, seed: album.title,
                                        title: album.title, subtitle: album.artistName)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 5)
                    rowDivider
                }
            }
        }
        if !results.tracks.isEmpty {
            inlineHeader("Tracks")
            ForEach(results.tracks) { track in
                VStack(spacing: 0) {
                    TrackRow(track: track, showArtist: true)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            record(.track, serverId: track.serverId, remoteId: track.remoteId)
                            env.playback.play(tracks: [track.toDomain()])
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 5)
                    rowDivider
                }
            }
        }
    }

    @ViewBuilder private func recentRow(_ resolved: RecentResolved) -> some View {
        switch resolved {
        case .artist(let a):
            Button {
                record(.artist, serverId: a.serverId, remoteId: a.remoteId)
                path.append(.artist(a))
            } label: {
                SearchResultRow(artworkKey: a.artworkKey, seed: a.name,
                                title: a.name, subtitle: "Artist", circular: true)
            }
            .buttonStyle(.plain)
        case .album(let a):
            Button {
                record(.album, serverId: a.serverId, remoteId: a.remoteId)
                path.append(.album(a))
            } label: {
                SearchResultRow(artworkKey: a.artworkKey, seed: a.title,
                                title: a.title, subtitle: "Album · \(a.artistName)")
            }
            .buttonStyle(.plain)
        case .track(let t):
            Button {
                record(.track, serverId: t.serverId, remoteId: t.remoteId)
                env.playback.play(tracks: [t.toDomain()])
            } label: {
                SearchResultRow(artworkKey: t.artworkKey, seed: t.albumTitle ?? t.title,
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

/// A single search row — artwork + title + optional subtitle. Shared by the
/// "Recently Searched" list and the live result sections so every row gets the
/// same 44pt album/artist artwork and a full-width, comfortably tall touch
/// target. Artists render with circular artwork; albums and songs use a rounded
/// square. When `subtitle` is nil (e.g. artist results, where the section header
/// already says "Artists") the title sits vertically centered on its own.
private struct SearchResultRow: View {
    let artworkKey: String?
    let seed: String
    let title: String
    var subtitle: String?
    var circular = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: artworkKey.map(ArtworkRef.init(key:)),
                        seed: seed, size: 44, cornerRadius: circular ? 22 : 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

/// A standalone Liquid Glass capsule for use as a background layer (iOS 26+),
/// with a material fallback below. Unlike `glassCapsule()` it does NOT wrap the
/// field's content, so the search field's surface can be swapped gray↔glass in a
/// background layer without ever changing the content's (TextField's) identity.
private struct GlassCapsuleFill: View {
    var body: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: Capsule())
        } else {
            Capsule().fill(.regularMaterial)
        }
        #else
        Capsule().fill(.regularMaterial)
        #endif
    }
}

/// Tracks whether a scroll view has moved off its top, toggling a `Bool`. Used
/// to swap the search field from its at-rest gray fill to Liquid Glass once
/// content scrolls under it. No-op before iOS 18 (the field just stays gray).
private struct ScrolledTracker: ViewModifier {
    @Binding var scrolled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, y in
                // Set plainly (no withAnimation): the field animates its own
                // gray→glass opacity locally. Animating from here during the
                // keyboard's geometry changes risks a relayout feedback loop.
                let isScrolled = y > 6
                if isScrolled != scrolled { scrolled = isScrolled }
            }
        } else {
            content
        }
    }
}

private extension View {
    func tracksScrolled(_ scrolled: Binding<Bool>) -> some View {
        modifier(ScrolledTracker(scrolled: scrolled))
    }
}
