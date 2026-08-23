#if os(iOS)
import CarPlay
import MozzCore
import MozzDatabase
import UIKit

/// Builds the CarPlay browsing hierarchy and turns taps into playback.
///
/// Everything is read from the local database, never the network: the catalog is
/// already on the device, which is what makes the car feel instant and keeps
/// browsing working in a tunnel. The only network the car needs is the audio
/// itself (and not even that, for downloaded tracks).
///
/// Templates are built empty with a "Loading…" row and filled in when the query
/// returns. CarPlay explicitly supports updating a list after it is on screen,
/// and it is much better than making the driver stare at a blank screen while a
/// large library is queried.
@MainActor
final class CarPlayBrowser {
    private let env: AppEnvironment
    private unowned let interfaceController: CPInterfaceController

    /// Per-template artwork fill tasks, cancelled when that template goes away so
    /// browsing quickly through a big library doesn't leave a pile of image
    /// requests running for screens nobody is looking at.
    ///
    /// The template is retained alongside its task. Keying on `ObjectIdentifier`
    /// alone is keying on an address: an artwork task holds only the rows, so it
    /// can outlive its template, and a new template allocated at the same address
    /// would collide — the stale task would then clear the *new* entry, leaving
    /// that one untracked and impossible to cancel. Holding the template keeps the
    /// address alive for as long as the entry is.
    private var artworkTasks: [ObjectIdentifier: (template: CPListTemplate, task: Task<Void, Never>)] = [:]
    /// Per-template content load tasks, likewise.
    private var loadTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(env: AppEnvironment, interfaceController: CPInterfaceController) {
        self.env = env
        self.interfaceController = interfaceController
    }

    deinit {
        for entry in artworkTasks.values { entry.task.cancel() }
        for task in loadTasks.values { task.cancel() }
    }

    /// How many rows we will put in one list.
    ///
    /// CarPlay silently TRIMS anything past its own ceiling — across all sections,
    /// not per section — so the SDK's number is used rather than a guess. A
    /// library with more albums than this is browsed by artist or genre instead;
    /// a list of ten thousand albums is not something anyone can use while driving.
    private var maximumItems: Int {
        min(CPListTemplate.maximumItemCount, 500)
    }

    /// Room for a list that also carries a leading "Shuffle" row.
    ///
    /// Without this the shuffle row pushes the total one over the ceiling and
    /// CarPlay quietly drops the last track of a maximum-length album.
    private var maximumItemsWithHeaderRow: Int {
        max(0, maximumItems - 1)
    }

    private var serverId: ServerID? { env.active?.connection.id }
    private var backend: (any MusicBackend)? { env.active?.backend }
    private var artworkPixelSize: Int {
        CarPlayArtwork.pixelSize(for: interfaceController.carTraitCollection)
    }

    // MARK: Root

    /// The tab bar shown when the car connects.
    ///
    /// Five tabs is CarPlay's maximum, so the split is by what a driver actually
    /// reaches for: what they were just listening to, their own playlists, and
    /// then the library proper. Songs, genres and downloads live behind "Library"
    /// rather than burning a tab each.
    func makeRootTemplate() -> CPTemplate {
        let recent = makeRecentlyPlayedTemplate()
        recent.tabTitle = "Recent"
        recent.tabImage = UIImage(systemName: "clock")

        let playlists = makePlaylistsTemplate()
        playlists.tabTitle = "Playlists"
        playlists.tabImage = UIImage(systemName: "music.note.list")

        let albums = makeAlbumsTemplate()
        albums.tabTitle = "Albums"
        albums.tabImage = UIImage(systemName: "square.stack")

        let artists = makeArtistsTemplate()
        artists.tabTitle = "Artists"
        artists.tabImage = UIImage(systemName: "music.mic")

        let library = makeLibraryTemplate()
        library.tabTitle = "Library"
        library.tabImage = UIImage(systemName: "books.vertical")

        let tabs = CPTabBarTemplate(templates: [recent, playlists, albums, artists, library])
        return tabs
    }

    // MARK: Tabs

    private func makeRecentlyPlayedTemplate() -> CPListTemplate {
        let template = loadingTemplate(title: "Recent")
        load(into: template) { [weak self] in
            guard let self, let serverId else { return [] }
            let records = try await env.repository.recentlyPlayedTracks(serverId: serverId, limit: 100)
            guard !records.isEmpty else {
                return [self.messageSection("Nothing played yet")]
            }
            let tracks = records.map { $0.toDomain() }
            return [self.trackSection(tracks, artworkKeys: records.map(\.artworkKey), title: nil)]
        }
        return template
    }

    private func makePlaylistsTemplate() -> CPListTemplate {
        let template = loadingTemplate(title: "Playlists")
        load(into: template) { [weak self] in
            guard let self, let serverId else { return [] }
            let playlists = try await env.repository.allPlaylists(serverId: serverId)
            guard !playlists.isEmpty else { return [self.messageSection("No playlists")] }
            var rows: [(CPListItem, String?)] = []
            let items: [CPListItem] = playlists.prefix(maximumItems).map { playlist in
                let subtitle = playlist.trackCount.map { "\($0) song\($0 == 1 ? "" : "s")" }
                let item = CPListItem(text: playlist.title, detailText: subtitle)
                item.handler = { [weak self] _, completion in
                    self?.openPlaylist(playlist, completion: completion) ?? completion()
                }
                rows.append((item, playlist.artworkKey))
                return item
            }
            self.fillArtwork(rows, for: template)
            return [CPListSection(items: items)]
        }
        return template
    }

    private func makeAlbumsTemplate() -> CPListTemplate {
        let template = loadingTemplate(title: "Albums")
        load(into: template) { [weak self] in
            guard let self, let serverId else { return [] }
            let albums = try await env.repository.albumsPage(
                serverId: serverId, offset: 0, limit: maximumItems
            )
            guard !albums.isEmpty else { return [self.messageSection("No albums yet")] }
            return [self.albumSection(albums, for: template)]
        }
        return template
    }

    private func makeArtistsTemplate() -> CPListTemplate {
        let template = loadingTemplate(title: "Artists")
        load(into: template) { [weak self] in
            guard let self, let serverId else { return [] }
            let artists = try await env.repository.artistsPage(
                serverId: serverId, offset: 0, limit: maximumItems
            )
            guard !artists.isEmpty else { return [self.messageSection("No artists yet")] }
            var rows: [(CPListItem, String?)] = []
            let items: [CPListItem] = artists.map { artist in
                let subtitle = artist.albumCount.map { "\($0) album\($0 == 1 ? "" : "s")" }
                let item = CPListItem(text: artist.name, detailText: subtitle)
                item.handler = { [weak self] _, completion in
                    self?.openArtist(artist, completion: completion) ?? completion()
                }
                rows.append((item, artist.artworkKey))
                return item
            }
            self.fillArtwork(rows, for: template)
            return [CPListSection(items: items)]
        }
        return template
    }

    /// The catch-all tab: everything that doesn't warrant one of the five slots.
    private func makeLibraryTemplate() -> CPListTemplate {
        let songs = CPListItem(text: "Songs", detailText: nil)
        songs.handler = { [weak self] _, completion in
            self?.push(self?.makeSongsTemplate(), completion: completion) ?? completion()
        }
        let genres = CPListItem(text: "Genres", detailText: nil)
        genres.handler = { [weak self] _, completion in
            self?.push(self?.makeGenresTemplate(), completion: completion) ?? completion()
        }
        let downloaded = CPListItem(text: "Downloaded", detailText: "Available offline")
        downloaded.handler = { [weak self] _, completion in
            self?.push(self?.makeDownloadedTemplate(), completion: completion) ?? completion()
        }
        let template = CPListTemplate(
            title: "Library",
            sections: [CPListSection(items: [songs, genres, downloaded])]
        )
        return template
    }

    // MARK: Second level

    private func makeSongsTemplate() -> CPListTemplate {
        let template = loadingTemplate(title: "Songs")
        load(into: template) { [weak self] in
            guard let self, let serverId else { return [] }
            let records = try await env.repository.tracksPage(
                serverId: serverId, offset: 0, limit: maximumItems
            )
            guard !records.isEmpty else { return [self.messageSection("No songs yet")] }
            let tracks = records.map { $0.toDomain() }
            return [self.trackSection(tracks, artworkKeys: records.map(\.artworkKey), title: nil)]
        }
        return template
    }

    private func makeGenresTemplate() -> CPListTemplate {
        let template = loadingTemplate(title: "Genres")
        load(into: template) { [weak self] in
            guard let self, let serverId else { return [] }
            let genres = try await env.repository.genres(serverId: serverId)
            guard !genres.isEmpty else { return [self.messageSection("No genres")] }
            let items: [CPListItem] = genres.prefix(maximumItems).map { genre in
                let item = CPListItem(text: genre, detailText: nil)
                item.handler = { [weak self] _, completion in
                    self?.openGenre(genre, completion: completion) ?? completion()
                }
                return item
            }
            return [CPListSection(items: items)]
        }
        return template
    }

    private func makeDownloadedTemplate() -> CPListTemplate {
        let template = loadingTemplate(title: "Downloaded")
        load(into: template) { [weak self] in
            guard let self else { return [] }
            let records = try await env.repository.downloadedTracks()
            guard !records.isEmpty else {
                return [self.messageSection("Nothing downloaded yet")]
            }
            let tracks = records.map { $0.toDomain() }
            return [self.trackSection(tracks, artworkKeys: records.map(\.artworkKey), title: nil)]
        }
        return template
    }

    private func openArtist(_ artist: ArtistRecord, completion: @escaping () -> Void) {
        let template = loadingTemplate(title: artist.name)
        load(into: template) { [weak self] in
            guard let self, let serverId else { return [] }
            let albums = try await env.repository.albums(
                forArtistRemoteId: artist.remoteId, serverId: serverId
            )
            guard !albums.isEmpty else { return [self.messageSection("No albums")] }
            return [self.albumSection(albums, for: template)]
        }
        push(template, completion: completion)
    }

    private func openGenre(_ genre: String, completion: @escaping () -> Void) {
        let template = loadingTemplate(title: genre)
        load(into: template) { [weak self] in
            guard let self, let serverId else { return [] }
            let albums = try await env.repository.albums(forGenre: genre, serverId: serverId)
            guard !albums.isEmpty else { return [self.messageSection("No albums")] }
            return [self.albumSection(albums, for: template)]
        }
        push(template, completion: completion)
    }

    private func openAlbum(_ album: AlbumRecord, completion: @escaping () -> Void) {
        let template = loadingTemplate(title: album.title)
        load(into: template) { [weak self] in
            guard let self, let serverId else { return [] }
            let records = try await env.repository.tracks(
                forAlbumGroupKey: album.albumGroupKey, serverId: serverId
            )
            guard !records.isEmpty else { return [self.messageSection("No songs")] }
            let tracks = records.map { $0.toDomain() }
            // Album track lists lead with a shuffle row: it's the one action that
            // is otherwise impossible from a list, and it's a single tap.
            return [
                CPListSection(items: [self.shuffleItem(tracks: tracks)]),
                self.trackSection(
                    tracks, artworkKeys: records.map(\.artworkKey), title: album.artistName,
                    limit: self.maximumItemsWithHeaderRow
                ),
            ]
        }
        push(template, completion: completion)
    }

    private func openPlaylist(_ playlist: PlaylistRecord, completion: @escaping () -> Void) {
        let template = loadingTemplate(title: playlist.title)
        load(into: template) { [weak self] in
            guard let self, let serverId else { return [] }
            let records = try await env.repository.tracks(
                forPlaylistRemoteId: playlist.remoteId, serverId: serverId
            )
            guard !records.isEmpty else { return [self.messageSection("Empty playlist")] }
            let tracks = records.map { $0.toDomain() }
            return [
                CPListSection(items: [self.shuffleItem(tracks: tracks)]),
                self.trackSection(
                    tracks, artworkKeys: records.map(\.artworkKey), title: nil,
                    limit: self.maximumItemsWithHeaderRow
                ),
            ]
        }
        push(template, completion: completion)
    }

    // MARK: Sections

    private func albumSection(_ albums: [AlbumRecord], for template: CPListTemplate) -> CPListSection {
        var rows: [(CPListItem, String?)] = []
        let items: [CPListItem] = albums.prefix(maximumItems).map { album in
            let item = CPListItem(text: album.title, detailText: album.artistName)
            item.handler = { [weak self] _, completion in
                self?.openAlbum(album, completion: completion) ?? completion()
            }
            rows.append((item, album.artworkKey))
            return item
        }
        fillArtwork(rows, for: template)
        return CPListSection(items: items)
    }

    /// A list of tracks. Tapping any row plays the WHOLE list from that point, so
    /// picking a song mid-album behaves the way it does everywhere else rather
    /// than stranding the driver on a queue of one.
    private func trackSection(
        _ tracks: [Track], artworkKeys: [String?], title: String?, limit: Int? = nil
    ) -> CPListSection {
        let items: [CPListItem] = tracks.prefix(limit ?? maximumItems).enumerated().map { index, track in
            let item = CPListItem(text: track.title, detailText: track.artistName)
            item.handler = { [weak self] _, completion in
                self?.play(tracks: tracks, startAt: index, completion: completion) ?? completion()
            }
            return item
        }
        return CPListSection(items: items, header: title, sectionIndexTitle: nil)
    }

    private func shuffleItem(tracks: [Track]) -> CPListItem {
        let item = CPListItem(text: "Shuffle", detailText: nil)
        item.setImage(UIImage(systemName: "shuffle"))
        item.handler = { [weak self] _, completion in
            guard let self else { return completion() }
            env.playback.playShuffled(tracks)
            showNowPlaying(completion: completion)
        }
        return item
    }

    private func messageSection(_ text: String) -> CPListSection {
        CPListSection(items: [CPListItem(text: text, detailText: nil)])
    }

    // MARK: Playback

    private func play(tracks: [Track], startAt index: Int, completion: @escaping () -> Void) {
        env.playback.play(tracks: tracks, startAt: index)
        showNowPlaying(completion: completion)
    }

    /// Push Now Playing after starting something, so the driver ends up looking
    /// at what's playing rather than the list they just tapped.
    private func showNowPlaying(completion: @escaping () -> Void) {
        // Already there — pushing a second copy would put it on the stack twice.
        guard !(interfaceController.topTemplate is CPNowPlayingTemplate) else {
            return completion()
        }
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true) { _, _ in
            completion()
        }
    }

    // MARK: Template plumbing

    private func loadingTemplate(title: String) -> CPListTemplate {
        let item = CPListItem(text: "Loading…", detailText: nil)
        item.isEnabled = false
        return CPListTemplate(title: title, sections: [CPListSection(items: [item])])
    }

    /// Run an async query and swap the template's contents when it returns.
    ///
    /// Failures show a message rather than an empty list: a driver seeing nothing
    /// can't tell "your library is empty" from "something broke".
    private func load(
        into template: CPListTemplate,
        query: @escaping () async throws -> [CPListSection]
    ) {
        let key = ObjectIdentifier(template)
        loadTasks[key]?.cancel()
        loadTasks[key] = Task { @MainActor [weak self, weak template] in
            do {
                let sections = try await query()
                guard !Task.isCancelled, let template else { return }
                if sections.isEmpty {
                    template.updateSections([self?.messageSection("Not signed in") ?? CPListSection(items: [])])
                } else {
                    template.updateSections(sections)
                }
            } catch {
                guard !Task.isCancelled, let template else { return }
                template.updateSections([
                    self?.messageSection("Couldn't load") ?? CPListSection(items: [])
                ])
            }
            self?.loadTasks[key] = nil
        }
    }

    private func fillArtwork(_ rows: [(CPListItem, String?)], for template: CPListTemplate) {
        let key = ObjectIdentifier(template)
        artworkTasks[key]?.task.cancel()
        let pixelSize = artworkPixelSize
        let backend = self.backend
        let task = Task { @MainActor [weak self] in
            await CarPlayArtwork.fill(
                rows: rows.map { (item: $0.0, artworkKey: $0.1) },
                backend: backend,
                pixelSize: pixelSize
            )
            // Only clear OUR entry — a newer fill for the same template will have
            // replaced it, and clearing that would orphan its task.
            guard let self, artworkTasks[key]?.template === template else { return }
            artworkTasks[key] = nil
        }
        artworkTasks[key] = (template, task)
    }

    private func push(_ template: CPTemplate?, completion: @escaping () -> Void) {
        guard let template else { return completion() }
        interfaceController.pushTemplate(template, animated: true) { _, _ in completion() }
    }
}
#endif
