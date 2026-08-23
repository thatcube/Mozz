#if os(iOS)
import CarPlay
import os
import MozzCore
import MozzDatabase
import MozzPlayback
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
private let carPlayLog = Logger(subsystem: "com.thatcube.Mozz", category: "carplay")

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
    private var artworkTasks: [ObjectIdentifier: (template: CPTemplate, task: Task<Void, Never>)] = [:]
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

    /// Remote ids of every downloaded track, refreshed when the browser is built.
    ///
    /// Held as a set rather than queried per row: a track list can be hundreds of
    /// rows, and this is the difference between one query and one per row while
    /// the driver is waiting for a screen to appear.
    private var downloadedTrackIDs: Set<String> = []
    /// Whether the server answered recently. Drives whether an undownloaded track
    /// is shown as playable — in a car with a LAN-only server, usually it isn't.
    private var serverReachable = true

    private var serverId: ServerID? { env.active?.connection.id }
    private var backend: (any MusicBackend)? { env.active?.backend }
    /// An SF Symbol for a row, in Mozz's red. See `CarPlayArtwork.rowSymbol`.
    private func symbol(_ name: String) -> UIImage? {
        CarPlayArtwork.rowSymbol(name, traits: interfaceController.carTraitCollection)
    }

    private var artworkPixelSize: Int {
        CarPlayArtwork.pixelSize(for: interfaceController.carTraitCollection)
    }

    // MARK: Root

    /// Note whether the server is currently answering, so rows can be shown as
    /// playable or not. Driven by real playback failures rather than a speculative
    /// reachability probe — a probe would be one more thing to be wrong, and the
    /// authoritative answer is whether audio actually plays.
    func setServerReachable(_ reachable: Bool) {
        guard reachable != serverReachable else { return }
        serverReachable = reachable
    }

    /// Refresh what's playable offline. Called on connect and whenever the root is
    /// rebuilt, so a download finished on the phone shows up in the car.
    func refreshOfflineState() async {
        let records = (try? await env.repository.downloadedTracks()) ?? []
        downloadedTrackIDs = Set(records.map(\.remoteId))
    }

    /// The tab bar shown when the car connects.
    ///
    /// The phone's own tabs, so somebody who has used the app knows where things
    /// are before they ever plug in — which matters far more in a car than it does
    /// on a phone, and means the category list only has to be learned once.
    ///
    /// The phone's third tab, Search, has no equivalent here at all. CarPlay
    /// refuses `CPSearchTemplate` to audio apps twice over: `CPTabBarTemplate`
    /// rejects it during validation, and pushing one raises an ObjC exception
    /// rather than failing a completion handler — so the app doesn't degrade, it
    /// dies, mid-drive. Spotify and Apple Music have no CarPlay search either.
    /// Finding a specific song in the car is Siri's job.
    func makeRootTemplate() -> CPTemplate {
        let home = makeHomeTemplate()
        home.tabTitle = "Home"
        home.tabImage = CarPlayArtwork.tabSymbol("house")

        let library = makeLibraryTemplate()
        library.tabTitle = "Library"
        library.tabImage = CarPlayArtwork.tabSymbol("books.vertical")

        return CPTabBarTemplate(templates: [home, library])
    }

    // MARK: Tabs

    /// Home: the two things a driver reaches for before anything else — the songs
    /// they have marked as liked, and what they were just listening to.
    private func makeHomeTemplate() -> CPListTemplate {
        let template = loadingTemplate(title: "Home")
        load(into: template) { [weak self] in
            guard let self, let serverId else { return [] }
            let liked = CPListItem(text: "Liked Songs", detailText: nil)
            liked.setImage(symbol("heart.fill"))
            liked.handler = { [weak self] _, completion in
                self?.push(self?.makeLikedSongsTemplate(), completion: completion) ?? completion()
            }
            var sections = [CPListSection(items: [liked])]
            let records = try await env.repository.recentlyPlayedTracks(serverId: serverId, limit: 100)
            if !records.isEmpty {
                let tracks = records.map { $0.toDomain() }
                sections.append(self.trackSection(
                    tracks, artworkKeys: records.map(\.artworkKey),
                    title: "Recently Played", for: template,
                    limit: self.maximumItemsWithHeaderRow
                ))
            }
            return sections
        }
        return template
    }

    private func makeLikedSongsTemplate() -> CPListTemplate {
        let template = loadingTemplate(title: "Liked Songs")
        load(into: template) { [weak self] in
            guard let self else { return [] }
            let records = try await env.repository.likedTracks(serverId: self.serverId)
            guard !records.isEmpty else { return [self.messageSection("Nothing liked yet")] }
            let tracks = records.map { $0.toDomain() }
            return [
                CPListSection(items: [self.shuffleItem(tracks: tracks)]),
                self.trackSection(
                    tracks, artworkKeys: records.map(\.artworkKey), title: nil,
                    for: template, limit: self.maximumItemsWithHeaderRow
                ),
            ]
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

    /// The same category list as the phone's Library tab, in the same order, so
    /// muscle memory carries over. "Liked Songs" appears here as well as on Home
    /// for exactly that reason — it is where the app puts it.
    private func makeLibraryTemplate() -> CPListTemplate {
        func row(_ title: String, _ glyph: String, _ detail: String? = nil,
                 _ make: @escaping (CarPlayBrowser) -> CPListTemplate) -> CPListItem {
            let item = CPListItem(text: title, detailText: detail)
            item.setImage(self.symbol(glyph))
            item.handler = { [weak self] _, completion in
                guard let self else { return completion() }
                self.push(make(self), completion: completion)
            }
            return item
        }
        let items = [
            row("Songs", "music.note") { $0.makeSongsTemplate() },
            row("Liked Songs", "heart") { $0.makeLikedSongsTemplate() },
            row("Playlists", "music.note.list") { $0.makePlaylistsTemplate() },
            row("Artists", "music.mic") { $0.makeArtistsTemplate() },
            row("Albums", "square.stack") { $0.makeAlbumsTemplate() },
            row("Genres", "guitars") { $0.makeGenresTemplate() },
            row("Downloaded", "arrow.down.circle", "Plays without your server") {
                $0.makeDownloadedTemplate()
            },
        ]
        return CPListTemplate(title: "Library", sections: [CPListSection(items: items)])
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
            return [self.trackSection(tracks, artworkKeys: records.map(\.artworkKey), title: nil,
                                      for: template)]
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
            return [
                CPListSection(items: [self.shuffleItem(tracks: tracks)]),
                self.trackSection(
                    tracks, artworkKeys: records.map(\.artworkKey), title: nil,
                    for: template, limit: self.maximumItemsWithHeaderRow
                ),
            ]
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
                    for: template, limit: self.maximumItemsWithHeaderRow
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
                    for: template, limit: self.maximumItemsWithHeaderRow
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
        _ tracks: [Track], artworkKeys: [String?], title: String?,
        for template: CPListTemplate, limit: Int? = nil
    ) -> CPListSection {
        var rows: [(CPListItem, String?)] = []
        let items: [CPListItem] = tracks.prefix(limit ?? maximumItems).enumerated().map { index, track in
            let downloaded = downloadedTrackIDs.contains(track.id)
            let item = CPListItem(text: track.title, detailText: track.artistName)
            rows.append((item, index < artworkKeys.count ? artworkKeys[index] : nil))
            if downloaded {
                // The universal convention for "you have this already".
                item.setAccessoryImage(symbol("arrow.down.circle.fill"))
            }
            // Grey out what genuinely can't play rather than hiding it: the driver
            // should still see their library and understand WHY a track is
            // unavailable, not find it silently missing. CarPlay renders a
            // disabled row dimmed and non-interactive.
            item.isEnabled = downloaded || serverReachable
            item.handler = { [weak self] _, completion in
                self?.play(tracks: tracks, startAt: index, completion: completion) ?? completion()
            }
            return item
        }
        fillArtwork(rows, for: template)
        return CPListSection(items: items, header: title, sectionIndexTitle: nil)
    }

    private func shuffleItem(tracks: [Track]) -> CPListItem {
        let item = CPListItem(text: "Shuffle", detailText: nil)
        item.setImage(symbol("shuffle"))
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

    /// Tell the driver why nothing happened.
    ///
    /// A failed play used to be completely silent — the single most complained-
    /// about behaviour in offline music apps, and worst in a car, where there's no
    /// way to investigate. An alert is the right weight here: it is the driver's
    /// own tap that failed, so it isn't an interruption, and CarPlay gives audio
    /// apps no lighter-weight surface (there is no toast, and
    /// `CPInformationTemplate` is unavailable to audio apps).
    func presentFailure(_ failure: PlaybackFailure) {
        // Reflect reachability so the rest of the library greys out correctly
        // rather than offering more things that will fail the same way.
        setServerReachable(!failure.isConnectivity)

        var actions = [CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }]
        // Offer the way out, not just the bad news: their downloads still play.
        if failure.isConnectivity, !downloadedTrackIDs.isEmpty {
            actions.insert(
                CPAlertAction(title: "Play Downloaded", style: .default) { [weak self] _ in
                    self?.interfaceController.dismissTemplate(animated: true, completion: nil)
                    self?.playDownloaded()
                },
                at: 0
            )
        }
        let alert = CPAlertTemplate(titleVariants: [failure.message], actions: actions)
        interfaceController.presentTemplate(alert, animated: true) { _, _ in }
    }

    /// Shuffle everything available offline — the useful thing to do when the
    /// server can't be reached.
    private func playDownloaded() {
        Task { @MainActor [weak self] in
            guard let self,
                  let records = try? await env.repository.downloadedTracks(),
                  !records.isEmpty else { return }
            env.playback.playShuffled(records.map { $0.toDomain() })
            showNowPlaying(completion: {})
        }
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

    private func fillArtwork(_ rows: [(CPListItem, String?)], for template: CPTemplate) {
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
        interfaceController.pushTemplate(template, animated: true) { ok, error in
            // A refused push leaves the driver tapping a row that does nothing,
            // with no clue why. CarPlay refuses for reasons that never show up in
            // a simulator or a unit test — depth limits, and templates an audio
            // app isn't entitled to — so record it rather than discarding it.
            if !ok {
                carPlayLog.error("""
                    push refused for \(String(describing: type(of: template)), privacy: .public): \
                    \(error?.localizedDescription ?? "no reason given", privacy: .public)
                    """)
            }
            completion()
        }
    }
}

#endif
