import Foundation
import Testing
import MozzCore
import MozzDatabase
import MozzEnrichment
import MozzSchema
import SwiftProtobuf
@testable import MozzCommands

/// The dispatcher driven the way a non-Swift shell drives it: serialised bytes
/// in, serialised bytes out, against a real database.
///
/// `MozzSchemaTests` proves the two clients agree on the wire format. This
/// proves the format is actually connected to the library — that a desktop or
/// Android shell asking for a page of albums gets that page, rather than a
/// well-formed empty answer.
@Suite struct CommandDispatcherTests {

    // MARK: Fixtures

    private static func makeLibrary(tracks: Int = 400) async throws -> LibraryRepository {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("commands-\(UUID().uuidString).sqlite")
        let db = try MusicDatabase.open(at: url)
        try await SyntheticCatalog(db).generate(
            serverId: SyntheticCatalog.defaultServerID,
            size: .init(artists: tracks / 25, albums: tracks / 8, tracks: tracks)
        )
        return LibraryRepository(db)
    }

    private static func dispatcher(_ repository: LibraryRepository) throws -> CommandDispatcher {
        // Catalog tests never touch playback settings or downloads; isolated
        // in-memory stores keep them independent. The playback-settings and
        // download tests below build their own dispatcher over a store that
        // shares the catalog's database, so a write is visible to the next read.
        let store = PlaybackSettingsStore(try MusicDatabase.inMemory())
        let downloads = DownloadStore(try MusicDatabase.inMemory())
        return CommandDispatcher(service: LibraryCommandService(
            repository: repository, playbackSettings: store, downloads: downloads))
    }

    /// Round-trip a request the way a shell would: encode, hand over bytes,
    /// decode what comes back. Never reaches into the dispatcher's internals,
    /// because a shell cannot either.
    private static func send(
        _ dispatcher: CommandDispatcher,
        _ build: (inout Mozz_V1_Request) -> Void
    ) async throws -> Mozz_V1_Response {
        var request = Mozz_V1_Request()
        request.id = 1
        build(&request)
        let bytes = await dispatcher.handle(try request.serializedData())
        return try Mozz_V1_Response(serializedBytes: bytes)
    }

    // MARK: Reading the library

    @Test func albumsComeBackAsAPageWithACursor() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)
        let expected = try await repository.albumsPage(
            serverId: SyntheticCatalog.defaultServerID, after: nil, limit: 10)

        let response = try await Self.send(dispatcher) {
            var albums = Mozz_V1_AlbumsRequest()
            albums.serverID = SyntheticCatalog.defaultServerID
            albums.limit = 10
            $0.albums = albums
        }

        guard case .albums(let payload) = response.result else {
            Issue.record("expected albums, got \(String(describing: response.result))")
            return
        }
        #expect(payload.albums.count == 10)
        #expect(payload.page.hasNext, "a 10-of-50 page should offer a cursor")
        // The rows must carry real data, not an empty shell that happens to
        // have the right count.
        #expect(payload.albums.allSatisfy { !$0.title.isEmpty })
        #expect(payload.albums.allSatisfy { !$0.remoteID.isEmpty })
        let actual = try #require(payload.albums.first)
        let expectedAlbum = try #require(expected.rows.first)
        #expect(actual.id == (expectedAlbum.id ?? 0))
        #expect(actual.serverID == SyntheticCatalog.defaultServerID)
        #expect(actual.artistRemoteID == expectedAlbum.artistRemoteId)
        #expect(actual.groupKey == expectedAlbum.albumGroupKey)
        #expect(actual.hasSortTitle)
        #expect(actual.sortTitle == expectedAlbum.sortTitle)
        #expect(actual.genres == expectedAlbum.genres)
        #expect(!actual.genres.isEmpty)
        #expect(actual.isFavorite == expectedAlbum.isFavorite)
        #expect(actual.hasAddedAt)
        #expect(actual.addedAt == expectedAlbum.addedAt)
        let release = AlbumReleaseClassifier.kind(trackCount: expectedAlbum.trackCount)
        #expect(actual.hasReleaseKind)
        #expect(actual.releaseKind == release.rawValue)
        #expect(actual.hasIsSingleOrEp)
        #expect(actual.isSingleOrEp == release.isSingleOrEP)
    }

    @Test func artistsComeBackAsAPageWithACursor() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)
        let expected = try await repository.artistsPage(
            serverId: SyntheticCatalog.defaultServerID, after: nil, limit: 5)

        let response = try await Self.send(dispatcher) {
            var artists = Mozz_V1_ArtistsRequest()
            artists.serverID = SyntheticCatalog.defaultServerID
            artists.limit = 5
            $0.artists = artists
        }

        guard case .artists(let payload) = response.result else {
            Issue.record("expected artists, got \(String(describing: response.result))")
            return
        }
        #expect(payload.artists.count == 5)
        #expect(payload.page.hasNext, "a 5-of-16 page should offer a cursor")
        #expect(payload.artists.allSatisfy { !$0.name.isEmpty })
        #expect(payload.artists.allSatisfy { !$0.remoteID.isEmpty })
        let actual = try #require(payload.artists.first)
        let expectedArtist = try #require(expected.rows.first)
        #expect(actual.id == (expectedArtist.id ?? 0))
        #expect(actual.serverID == SyntheticCatalog.defaultServerID)
        #expect(actual.hasSortName)
        #expect(actual.sortName == expectedArtist.sortName)
        #expect(actual.hasHeroArtworkKey)
        #expect(actual.heroArtworkKey == expectedArtist.artworkKey)
        #expect(actual.genres == expectedArtist.genres)
        #expect(!actual.genres.isEmpty)
        #expect(actual.isFavorite == expectedArtist.isFavorite)
    }

    @Test func tracksComeBackAsAPageWithACursor() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)
        let expected = try await repository.tracksPage(
            serverId: SyntheticCatalog.defaultServerID, after: nil, limit: 12)

        let response = try await Self.send(dispatcher) {
            var tracks = Mozz_V1_TracksRequest()
            tracks.serverID = SyntheticCatalog.defaultServerID
            tracks.limit = 12
            $0.tracks = tracks
        }

        guard case .tracks(let payload) = response.result else {
            Issue.record("expected tracks, got \(String(describing: response.result))")
            return
        }
        #expect(payload.tracks.count == 12)
        #expect(payload.page.hasNext, "a 12-of-400 page should offer a cursor")
        #expect(payload.tracks.allSatisfy { !$0.title.isEmpty })
        #expect(payload.tracks.allSatisfy { !$0.remoteID.isEmpty })
        #expect(payload.tracks.allSatisfy { $0.durationSeconds > 0 })
        let actual = try #require(payload.tracks.first)
        let expectedTrack = try #require(expected.rows.first)
        #expect(actual.id == (expectedTrack.id ?? 0))
        #expect(actual.serverID == SyntheticCatalog.defaultServerID)
        #expect(actual.hasAlbumTitle)
        #expect(actual.albumTitle == expectedTrack.albumTitle)
        #expect(actual.hasAlbumRemoteID)
        #expect(actual.albumRemoteID == expectedTrack.albumRemoteId)
        #expect(actual.hasTrackNumber)
        #expect(actual.trackNumber == Int32(expectedTrack.trackNumber ?? 0))
        #expect(actual.hasDiscNumber)
        #expect(actual.discNumber == Int32(expectedTrack.discNumber ?? 0))
        #expect(actual.hasArtworkKey)
        #expect(actual.artworkKey == expectedTrack.artworkKey)
        #expect(actual.isFavorite == expectedTrack.isFavorite)
        #expect(actual.hasAddedAt)
        #expect(actual.addedAt == expectedTrack.addedAt)
        if let gain = expectedTrack.normalizationGainDB {
            #expect(actual.hasNormalizationGainDb)
            #expect(actual.normalizationGainDb == gain)
        }
    }

    /// Walking the pages must visit each album once — the property the cursor
    /// exists for, now checked through the wire rather than only in the
    /// repository's own tests.
    @Test func walkingTheCursorVisitsEveryAlbumExactlyOnce() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)

        var seen: [String] = []
        var cursor: String?
        var pages = 0

        repeat {
            let response = try await Self.send(dispatcher) {
                var albums = Mozz_V1_AlbumsRequest()
                albums.serverID = SyntheticCatalog.defaultServerID
                albums.limit = 7
                if let cursor {
                    var token = Mozz_V1_PageCursor()
                    token.token = cursor
                    albums.after = token
                }
                $0.albums = albums
            }

            guard case .albums(let payload) = response.result else {
                Issue.record("page \(pages) failed: \(String(describing: response.result))")
                return
            }
            seen.append(contentsOf: payload.albums.map(\.remoteID))
            cursor = payload.page.hasNext ? payload.page.next.token : nil
            pages += 1
            #expect(pages < 50, "the cursor walk did not terminate")
        } while cursor != nil

        #expect(!seen.isEmpty)
        #expect(Set(seen).count == seen.count, "an album came back on two different pages")
    }

    @Test func anArtistComesBackByRemoteId() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)

        let page = try await repository.artistsPage(
            serverId: SyntheticCatalog.defaultServerID, after: nil, limit: 1)
        let known = try #require(page.rows.first)

        let response = try await Self.send(dispatcher) {
            var artist = Mozz_V1_ArtistRequest()
            artist.serverID = SyntheticCatalog.defaultServerID
            artist.remoteID = known.remoteId
            $0.artist = artist
        }

        guard case .artist(let payload) = response.result else {
            Issue.record("expected artist, got \(String(describing: response.result))")
            return
        }
        let albums = try await repository.albums(
            forArtistRemoteId: known.remoteId,
            serverId: SyntheticCatalog.defaultServerID
        )
        let hero = ArtistDetailPresentation.heroArtworkKey(artist: known, albums: albums)
        #expect(payload.artist.remoteID == known.remoteId)
        #expect(payload.artist.name == known.name)
        #expect(payload.artist.id == (known.id ?? 0))
        #expect(payload.artist.serverID == SyntheticCatalog.defaultServerID)
        #expect(payload.artist.hasSortName)
        #expect(payload.artist.sortName == known.sortName)
        #expect(payload.artist.hasHeroArtworkKey)
        #expect(payload.artist.heroArtworkKey == hero)
        #expect(payload.artist.genres == known.genres)
        #expect(!payload.artist.genres.isEmpty)
        #expect(payload.artist.isFavorite == known.isFavorite)
    }

    @Test func artistAlbumsComeBackForAnArtist() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)

        let page = try await repository.artistsPage(
            serverId: SyntheticCatalog.defaultServerID, after: nil, limit: 1)
        let known = try #require(page.rows.first)
        let expected = try await repository.albums(
            forArtistRemoteId: known.remoteId,
            serverId: SyntheticCatalog.defaultServerID
        )

        let response = try await Self.send(dispatcher) {
            var artistAlbums = Mozz_V1_ArtistAlbumsRequest()
            artistAlbums.serverID = SyntheticCatalog.defaultServerID
            artistAlbums.remoteID = known.remoteId
            $0.artistAlbums = artistAlbums
        }

        guard case .artistAlbums(let payload) = response.result else {
            Issue.record("expected artistAlbums, got \(String(describing: response.result))")
            return
        }
        #expect(payload.albums.map(\.remoteID) == expected.map(\.remoteId))
        #expect(payload.albums.allSatisfy { !$0.title.isEmpty })
    }

    @Test func albumTracksComeBackForAnAlbumRemoteId() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)

        let page = try await repository.albumsPage(
            serverId: SyntheticCatalog.defaultServerID, after: nil, limit: 1)
        let known = try #require(page.rows.first)
        let expected = try await repository.tracks(
            forAlbumGroupContaining: known.remoteId,
            serverId: SyntheticCatalog.defaultServerID
        )

        let response = try await Self.send(dispatcher) {
            var albumTracks = Mozz_V1_AlbumTracksRequest()
            albumTracks.serverID = SyntheticCatalog.defaultServerID
            albumTracks.remoteID = known.remoteId
            $0.albumTracks = albumTracks
        }

        guard case .albumTracks(let payload) = response.result else {
            Issue.record("expected albumTracks, got \(String(describing: response.result))")
            return
        }
        #expect(payload.tracks.map(\.remoteID) == expected.map(\.remoteId))
        #expect(payload.tracks.allSatisfy { !$0.title.isEmpty })
    }

    @Test func albumTracksPreferTheAlbumGroupKeyWhenPresent() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)

        let page = try await repository.albumsPage(
            serverId: SyntheticCatalog.defaultServerID, after: nil, limit: 1)
        let known = try #require(page.rows.first)
        let expected = try await repository.tracks(
            forAlbumGroupKey: known.albumGroupKey,
            serverId: SyntheticCatalog.defaultServerID
        )

        let response = try await Self.send(dispatcher) {
            var albumTracks = Mozz_V1_AlbumTracksRequest()
            albumTracks.serverID = SyntheticCatalog.defaultServerID
            albumTracks.remoteID = "ignored-when-group-key-is-present"
            albumTracks.groupKey = known.albumGroupKey
            $0.albumTracks = albumTracks
        }

        guard case .albumTracks(let payload) = response.result else {
            Issue.record("expected albumTracks, got \(String(describing: response.result))")
            return
        }
        #expect(payload.tracks.map(\.remoteID) == expected.map(\.remoteId))
    }

    @Test func countsComeBackForTheServer() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)

        let expectedArtists = try await repository.artistCount(serverId: SyntheticCatalog.defaultServerID)
        let expectedAlbums = try await repository.albumCount(serverId: SyntheticCatalog.defaultServerID)
        let expectedTracks = try await repository.trackCount(serverId: SyntheticCatalog.defaultServerID)

        let response = try await Self.send(dispatcher) {
            var counts = Mozz_V1_CountsRequest()
            counts.serverID = SyntheticCatalog.defaultServerID
            $0.counts = counts
        }

        guard case .counts(let payload) = response.result else {
            Issue.record("expected counts, got \(String(describing: response.result))")
            return
        }
        #expect(payload.artists == Int32(expectedArtists))
        #expect(payload.albums == Int32(expectedAlbums))
        #expect(payload.tracks == Int32(expectedTracks))
    }

    // MARK: Failing usefully

    @Test func anAbsentArtistIsAFailureRatherThanAnEmptyArtist() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)

        let response = try await Self.send(dispatcher) {
            var artist = Mozz_V1_ArtistRequest()
            artist.serverID = SyntheticCatalog.defaultServerID
            artist.remoteID = "no-such-artist"
            $0.artist = artist
        }

        guard case .failure(let failure) = response.result else {
            Issue.record("a missing artist must not come back as a blank one")
            return
        }
        #expect(failure.message.contains("no-such-artist"))
    }

    /// A corrupt cursor must say so rather than quietly starting over.
    ///
    /// Silently returning the first page would look, to someone scrolling, like
    /// the list jumping back to the top for no reason — and it would do it
    /// forever, because the bad cursor would keep being handed back.
    @Test func anUnreadableCursorFailsRatherThanRestartingTheList() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)

        let response = try await Self.send(dispatcher) {
            var albums = Mozz_V1_AlbumsRequest()
            albums.serverID = SyntheticCatalog.defaultServerID
            albums.limit = 10
            var token = Mozz_V1_PageCursor()
            token.token = "not-a-real-cursor"
            albums.after = token
            $0.albums = albums
        }

        guard case .failure(let failure) = response.result else {
            Issue.record("a bad cursor silently returned a page instead of failing")
            return
        }
        #expect(failure.message.contains("cursor"))
    }

    @Test func albumTracksWithoutAnAlbumIdentifierFailsUsefully() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)

        let response = try await Self.send(dispatcher) {
            var albumTracks = Mozz_V1_AlbumTracksRequest()
            albumTracks.serverID = SyntheticCatalog.defaultServerID
            $0.albumTracks = albumTracks
        }

        guard case .failure(let failure) = response.result else {
            Issue.record("albumTracks without an album id must fail")
            return
        }
        #expect(failure.message.contains("remoteId or groupKey"))
    }

    /// Bytes that are not a request at all must not take the process down.
    ///
    /// This crosses a C ABI in production, where a thrown Swift error is a
    /// crash rather than an exception the caller can catch.
    @Test func garbageBytesProduceAFailureRatherThanACrash() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)

        let bytes = await dispatcher.handle(Data([0xFF, 0xFE, 0xFD, 0xFC]))
        let response = try Mozz_V1_Response(serializedBytes: bytes)

        guard case .failure(let failure) = response.result else {
            Issue.record("malformed input must come back as a failure")
            return
        }
        #expect(failure.message.contains("malformed"))
    }

    /// A command declared in the schema but not yet implemented must answer
    /// honestly. The alternative — an empty success — is indistinguishable from
    /// a library with nothing in it, which is the kind of silence this whole
    /// arrangement exists to remove.
    @Test func aDeclaredButUnimplementedCommandSaysSo() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)

        let response = try await Self.send(dispatcher) {
            var watch = Mozz_V1_WatchLibraryRequest()
            watch.serverID = SyntheticCatalog.defaultServerID
            $0.watchLibrary = watch
        }

        guard case .failure(let failure) = response.result else {
            Issue.record("an unimplemented command must not report success")
            return
        }
        #expect(failure.message.contains("not implemented"))
    }

    /// The request id is how a caller pairs a response with what it asked for.
    /// Losing it would make concurrent requests indistinguishable.
    @Test func theRequestIdComesBackOnEveryPath() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)

        var request = Mozz_V1_Request()
        request.id = 99_001
        request.artist = {
            var artist = Mozz_V1_ArtistRequest()
            artist.serverID = SyntheticCatalog.defaultServerID
            artist.remoteID = "definitely-missing"
            return artist
        }()

        let bytes = await dispatcher.handle(try request.serializedData())
        let response = try Mozz_V1_Response(serializedBytes: bytes)

        #expect(response.id == 99_001, "the id must survive even a failure")
    }

    // MARK: Playback settings

    /// A shell that has never written settings gets the core's defaults, not an
    /// empty message. This is the contract that lets a fresh device behave
    /// identically to one that has synced: EQ off, a flat curve, track-mode
    /// normalization, no preamp.
    @Test func playbackSettingsDefaultToTheCoreDefaultsWhenNothingStored() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)

        let response = try await Self.send(dispatcher) {
            $0.getPlaybackSettings = Mozz_V1_GetPlaybackSettingsRequest()
        }

        guard case .getPlaybackSettings(let payload) = response.result else {
            Issue.record("expected getPlaybackSettings, got \(String(describing: response.result))")
            return
        }
        #expect(payload.settings.equalizerEnabled == false)
        #expect(payload.settings.equalizerBandGainsDb == Array(repeating: 0, count: EqualizerSettings.bandCount))
        #expect(payload.settings.equalizerPreampDb == 0)
        #expect(payload.settings.replayGainMode == .track)
        #expect(payload.settings.replayGainPreampDb == 0)
    }

    /// The whole point of moving these into the core: a write from one shell is
    /// stored and readable by the next reader, byte-for-byte, through the same
    /// Facade. Set, then Get on the same core, and confirm every field survives.
    @Test func playbackSettingsRoundTripThroughTheFacade() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)

        let gains: [Double] = [6, 5, 4, 2, 0.5, 0, -1, -2, -3, -4]
        let setResponse = try await Self.send(dispatcher) {
            var settings = Mozz_V1_PlaybackSettings()
            settings.equalizerEnabled = true
            settings.equalizerBandGainsDb = gains
            settings.equalizerPreampDb = -3
            settings.replayGainMode = .album
            settings.replayGainPreampDb = 2.5
            var request = Mozz_V1_SetPlaybackSettingsRequest()
            request.settings = settings
            $0.setPlaybackSettings = request
        }

        guard case .setPlaybackSettings(let stored) = setResponse.result else {
            Issue.record("expected setPlaybackSettings, got \(String(describing: setResponse.result))")
            return
        }
        // The response echoes exactly what was stored, after normalization.
        #expect(stored.settings.equalizerEnabled == true)
        #expect(stored.settings.equalizerBandGainsDb == gains)
        #expect(stored.settings.equalizerPreampDb == -3)
        #expect(stored.settings.replayGainMode == .album)
        #expect(stored.settings.replayGainPreampDb == 2.5)

        // A subsequent read on the same core returns the same values.
        let getResponse = try await Self.send(dispatcher) {
            $0.getPlaybackSettings = Mozz_V1_GetPlaybackSettingsRequest()
        }
        guard case .getPlaybackSettings(let reloaded) = getResponse.result else {
            Issue.record("expected getPlaybackSettings, got \(String(describing: getResponse.result))")
            return
        }
        #expect(reloaded.settings == stored.settings)
    }

    /// A caller cannot smuggle an invalid EQ or an extreme preamp past the core:
    /// out-of-range gains are clamped to ±12 dB and a wrong-length band array is
    /// padded/truncated to exactly 10, and the response reports the clamped form.
    @Test func settingPlaybackSettingsClampsOutOfRangeValues() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)

        let response = try await Self.send(dispatcher) {
            var settings = Mozz_V1_PlaybackSettings()
            settings.equalizerEnabled = true
            // Too many bands, wildly out of range, plus an extreme preamp.
            settings.equalizerBandGainsDb = [99, -99, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
            settings.equalizerPreampDb = 500
            settings.replayGainMode = .track
            settings.replayGainPreampDb = -500
            var request = Mozz_V1_SetPlaybackSettingsRequest()
            request.settings = settings
            $0.setPlaybackSettings = request
        }

        guard case .setPlaybackSettings(let stored) = response.result else {
            Issue.record("expected setPlaybackSettings, got \(String(describing: response.result))")
            return
        }
        #expect(stored.settings.equalizerBandGainsDb.count == EqualizerSettings.bandCount)
        #expect(stored.settings.equalizerBandGainsDb[0] == EqualizerSettings.gainRange.upperBound)   // 99 → +12
        #expect(stored.settings.equalizerBandGainsDb[1] == EqualizerSettings.gainRange.lowerBound)   // -99 → -12
        #expect(stored.settings.equalizerPreampDb == EqualizerSettings.gainRange.upperBound)         // 500 → +12
        #expect(stored.settings.replayGainPreampDb == PlaybackSettings.preampRange.lowerBound)       // -500 → -12
    }

    /// A client that omits the mode (proto3 zero = UNSPECIFIED) gets the core's
    /// default rather than a spurious "off": omission means "I don't care", and
    /// the core answers with its considered default (track).
    @Test func unspecifiedReplayGainModeTakesTheCoreDefault() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)

        let response = try await Self.send(dispatcher) {
            var settings = Mozz_V1_PlaybackSettings()
            settings.replayGainMode = .unspecified
            var request = Mozz_V1_SetPlaybackSettingsRequest()
            request.settings = settings
            $0.setPlaybackSettings = request
        }

        guard case .setPlaybackSettings(let stored) = response.result else {
            Issue.record("expected setPlaybackSettings, got \(String(describing: response.result))")
            return
        }
        #expect(stored.settings.replayGainMode == .track)
    }

    /// Pins the resolved divergence. The C# desktop modelled Off/Track/Album;
    /// the Swift shell had only an on/off bool. The core keeps the richer
    /// superset, so `album` is preserved through a round trip rather than being
    /// collapsed to `track` — even though, with today's single-gain core, the
    /// two currently *sound* the same. This test fails if a later change quietly
    /// drops the distinction.
    @Test func albumReplayGainModeIsPreservedNotCollapsedToTrack() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = try Self.dispatcher(repository)

        _ = try await Self.send(dispatcher) {
            var settings = Mozz_V1_PlaybackSettings()
            settings.replayGainMode = .album
            var request = Mozz_V1_SetPlaybackSettingsRequest()
            request.settings = settings
            $0.setPlaybackSettings = request
        }

        let response = try await Self.send(dispatcher) {
            $0.getPlaybackSettings = Mozz_V1_GetPlaybackSettingsRequest()
        }
        guard case .getPlaybackSettings(let payload) = response.result else {
            Issue.record("expected getPlaybackSettings, got \(String(describing: response.result))")
            return
        }
        #expect(payload.settings.replayGainMode == .album)
    }

    // MARK: Downloads
    //
    // The lifecycle a shell drives over the wire: enqueue, report progress,
    // complete (or fail, or cancel), delete — plus the two pollable reads
    // (status, list) and storage usage. These prove the download *decision* is
    // reachable from a non-Swift shell, which before had no download capability
    // at all because the module was only ever called directly from Apple code.

    /// A database whose repository (reads) and download store (writes) share one
    /// connection, so a write through a command is visible to the next read —
    /// exactly the arrangement a real session has. `Self.dispatcher` deliberately
    /// gives download-untouched catalog tests an isolated store instead.
    private static func downloadFixture(
        tracks: Int = 80
    ) async throws -> (dispatcher: CommandDispatcher, repository: LibraryRepository) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("commands-dl-\(UUID().uuidString).sqlite")
        let db = try MusicDatabase.open(at: url)
        try await SyntheticCatalog(db).generate(
            serverId: SyntheticCatalog.defaultServerID,
            size: .init(artists: tracks / 25, albums: tracks / 8, tracks: tracks)
        )
        let repository = LibraryRepository(db)
        let dispatcher = CommandDispatcher(service: LibraryCommandService(
            repository: repository,
            playbackSettings: PlaybackSettingsStore(try MusicDatabase.inMemory()),
            downloads: DownloadStore(db)))
        return (dispatcher, repository)
    }

    /// The first `n` tracks in the catalog, to drive downloads against real ids.
    private static func someTracks(
        _ repository: LibraryRepository, _ n: Int
    ) async throws -> [TrackRecord] {
        let page = try await repository.tracksPage(
            serverId: SyntheticCatalog.defaultServerID, after: nil, limit: n)
        try #require(page.rows.count >= n)
        return Array(page.rows.prefix(n))
    }

    /// The whole path a shell walks: queue it, report bytes moving, finish. Each
    /// step's response and a following status poll must agree on the state and
    /// the byte counters, because a client renders the poll, not the write.
    @Test func aDownloadRunsItsFullLifecycle() async throws {
        let (dispatcher, repository) = try await Self.downloadFixture()
        let track = try #require(try await Self.someTracks(repository, 1).first)

        // Enqueue → queued, no bytes yet.
        let enqueued = try await Self.send(dispatcher) {
            var request = Mozz_V1_EnqueueDownloadRequest()
            request.serverID = track.serverId
            request.remoteID = track.remoteId
            $0.enqueueDownload = request
        }
        guard case .enqueueDownload(let queued) = enqueued.result else {
            Issue.record("expected enqueueDownload, got \(String(describing: enqueued.result))")
            return
        }
        #expect(queued.download.state == .queued)
        #expect(queued.download.serverID == track.serverId)
        #expect(queued.download.remoteID == track.remoteId)
        #expect(queued.download.trackID == (track.id ?? -1))
        #expect(queued.download.receivedBytes == 0)

        // First progress → downloading, counters set.
        let progressed = try await Self.send(dispatcher) {
            var request = Mozz_V1_ReportDownloadProgressRequest()
            request.serverID = track.serverId
            request.remoteID = track.remoteId
            request.receivedBytes = 512
            request.totalBytes = 4096
            $0.reportDownloadProgress = request
        }
        guard case .reportDownloadProgress(let midway) = progressed.result else {
            Issue.record("expected reportDownloadProgress, got \(String(describing: progressed.result))")
            return
        }
        #expect(midway.download.state == .downloading)
        #expect(midway.download.receivedBytes == 512)
        #expect(midway.download.hasTotalBytes)
        #expect(midway.download.totalBytes == 4096)

        // Complete → downloaded, path + final size recorded, completedAt present.
        let completed = try await Self.send(dispatcher) {
            var request = Mozz_V1_CompleteDownloadRequest()
            request.serverID = track.serverId
            request.remoteID = track.remoteId
            request.localPath = "downloads/\(track.remoteId).flac"
            request.sizeBytes = 4096
            $0.completeDownload = request
        }
        guard case .completeDownload(let done) = completed.result else {
            Issue.record("expected completeDownload, got \(String(describing: completed.result))")
            return
        }
        #expect(done.download.state == .downloaded)
        #expect(done.download.receivedBytes == 4096)
        #expect(done.download.hasLocalPath)
        #expect(done.download.localPath == "downloads/\(track.remoteId).flac")
        #expect(done.download.hasCompletedAt)

        // A status poll sees the same finished download.
        let status = try await Self.send(dispatcher) {
            var request = Mozz_V1_DownloadStatusRequest()
            request.serverID = track.serverId
            request.remoteID = track.remoteId
            $0.downloadStatus = request
        }
        guard case .downloadStatus(let polled) = status.result else {
            Issue.record("expected downloadStatus, got \(String(describing: status.result))")
            return
        }
        #expect(polled.hasDownload)
        #expect(polled.download.state == .downloaded)
        #expect(polled.download.localPath == "downloads/\(track.remoteId).flac")
    }

    /// Enqueuing a track that is already tracked returns its current record
    /// rather than resetting progress — a shell that re-requests a download in
    /// flight must not knock it back to zero.
    @Test func enqueueIsIdempotent() async throws {
        let (dispatcher, repository) = try await Self.downloadFixture()
        let track = try #require(try await Self.someTracks(repository, 1).first)

        func enqueue() async throws -> Mozz_V1_Download {
            let response = try await Self.send(dispatcher) {
                var request = Mozz_V1_EnqueueDownloadRequest()
                request.serverID = track.serverId
                request.remoteID = track.remoteId
                $0.enqueueDownload = request
            }
            guard case .enqueueDownload(let payload) = response.result else {
                Issue.record("expected enqueueDownload, got \(String(describing: response.result))")
                return Mozz_V1_Download()
            }
            return payload.download
        }

        _ = try await enqueue()
        // Move it forward, then re-enqueue: the second enqueue must observe the
        // advanced state, not overwrite it.
        _ = try await Self.send(dispatcher) {
            var request = Mozz_V1_ReportDownloadProgressRequest()
            request.serverID = track.serverId
            request.remoteID = track.remoteId
            request.receivedBytes = 128
            $0.reportDownloadProgress = request
        }
        let again = try await enqueue()
        #expect(again.state == .downloading)
        #expect(again.receivedBytes == 128)
    }

    /// A failure keeps its reason, so a status poll — and a person looking at a
    /// stalled download — can say why it stopped.
    @Test func aFailedDownloadCarriesItsReason() async throws {
        let (dispatcher, repository) = try await Self.downloadFixture()
        let track = try #require(try await Self.someTracks(repository, 1).first)

        _ = try await Self.send(dispatcher) {
            var request = Mozz_V1_EnqueueDownloadRequest()
            request.serverID = track.serverId
            request.remoteID = track.remoteId
            $0.enqueueDownload = request
        }
        let failed = try await Self.send(dispatcher) {
            var request = Mozz_V1_FailDownloadRequest()
            request.serverID = track.serverId
            request.remoteID = track.remoteId
            request.message = "network dropped"
            $0.failDownload = request
        }
        guard case .failDownload(let payload) = failed.result else {
            Issue.record("expected failDownload, got \(String(describing: failed.result))")
            return
        }
        #expect(payload.download.state == .failed)
        #expect(payload.download.hasErrorMessage)
        #expect(payload.download.errorMessage == "network dropped")
    }

    /// Cancelling records a failure whose message is exactly "Cancelled",
    /// identical to DownloadManager.cancel, so the two entry points cannot
    /// disagree about what a cancelled download looks like.
    @Test func cancellingRecordsItAsCancelled() async throws {
        let (dispatcher, repository) = try await Self.downloadFixture()
        let track = try #require(try await Self.someTracks(repository, 1).first)

        _ = try await Self.send(dispatcher) {
            var request = Mozz_V1_EnqueueDownloadRequest()
            request.serverID = track.serverId
            request.remoteID = track.remoteId
            $0.enqueueDownload = request
        }
        let cancelled = try await Self.send(dispatcher) {
            var request = Mozz_V1_CancelDownloadRequest()
            request.serverID = track.serverId
            request.remoteID = track.remoteId
            $0.cancelDownload = request
        }
        guard case .cancelDownload(let payload) = cancelled.result else {
            Issue.record("expected cancelDownload, got \(String(describing: cancelled.result))")
            return
        }
        #expect(payload.download.state == .failed)
        #expect(payload.download.errorMessage == "Cancelled")
    }

    /// Deleting returns the file's former relative path — what the shell removes
    /// from disk — and clears the record, so a following status poll reports the
    /// track as no longer downloaded.
    @Test func deletingReturnsTheFormerPathAndClearsTheRecord() async throws {
        let (dispatcher, repository) = try await Self.downloadFixture()
        let track = try #require(try await Self.someTracks(repository, 1).first)

        _ = try await Self.send(dispatcher) {
            var request = Mozz_V1_EnqueueDownloadRequest()
            request.serverID = track.serverId
            request.remoteID = track.remoteId
            $0.enqueueDownload = request
        }
        _ = try await Self.send(dispatcher) {
            var request = Mozz_V1_CompleteDownloadRequest()
            request.serverID = track.serverId
            request.remoteID = track.remoteId
            request.localPath = "downloads/\(track.remoteId).flac"
            request.sizeBytes = 2048
            $0.completeDownload = request
        }

        let deleted = try await Self.send(dispatcher) {
            var request = Mozz_V1_DeleteDownloadRequest()
            request.serverID = track.serverId
            request.remoteID = track.remoteId
            $0.deleteDownload = request
        }
        guard case .deleteDownload(let payload) = deleted.result else {
            Issue.record("expected deleteDownload, got \(String(describing: deleted.result))")
            return
        }
        #expect(payload.hasRemovedLocalPath)
        #expect(payload.removedLocalPath == "downloads/\(track.remoteId).flac")

        let status = try await Self.send(dispatcher) {
            var request = Mozz_V1_DownloadStatusRequest()
            request.serverID = track.serverId
            request.remoteID = track.remoteId
            $0.downloadStatus = request
        }
        guard case .downloadStatus(let polled) = status.result else {
            Issue.record("expected downloadStatus, got \(String(describing: status.result))")
            return
        }
        #expect(!polled.hasDownload, "a deleted download must no longer report a record")
    }

    /// Deleting a download that never existed is a benign no-op, not a failure:
    /// the response simply carries no removed path.
    @Test func deletingAnUnknownDownloadRemovesNothing() async throws {
        let (dispatcher, repository) = try await Self.downloadFixture()
        let track = try #require(try await Self.someTracks(repository, 1).first)

        // A real track, but no download was ever recorded for it.
        let deleted = try await Self.send(dispatcher) {
            var request = Mozz_V1_DeleteDownloadRequest()
            request.serverID = track.serverId
            request.remoteID = track.remoteId
            $0.deleteDownload = request
        }
        guard case .deleteDownload(let payload) = deleted.result else {
            Issue.record("expected deleteDownload, got \(String(describing: deleted.result))")
            return
        }
        #expect(!payload.hasRemovedLocalPath)
    }

    /// The property the task calls out by name: a status query for a track the
    /// catalog does not know must answer "not downloaded" (an absent record),
    /// never a failure and never a crash. This is what lets a client poll any
    /// track's status without first proving the track exists.
    @Test func statusForAnUnknownTrackIsAbsentNotAFailure() async throws {
        let (dispatcher, _) = try await Self.downloadFixture()

        let status = try await Self.send(dispatcher) {
            var request = Mozz_V1_DownloadStatusRequest()
            request.serverID = SyntheticCatalog.defaultServerID
            request.remoteID = "no-such-track-at-all"
            $0.downloadStatus = request
        }
        guard case .downloadStatus(let payload) = status.result else {
            Issue.record("a status poll for an unknown track must not fail")
            return
        }
        #expect(!payload.hasDownload)
    }

    /// A *mutation* for a track the catalog never saw is a real error, unlike a
    /// status poll — there is nothing to download — and the failure names the
    /// remote id so a caller can see which request was wrong.
    @Test func enqueueingAnUnknownTrackFails() async throws {
        let (dispatcher, _) = try await Self.downloadFixture()

        let response = try await Self.send(dispatcher) {
            var request = Mozz_V1_EnqueueDownloadRequest()
            request.serverID = SyntheticCatalog.defaultServerID
            request.remoteID = "ghost-track"
            $0.enqueueDownload = request
        }
        guard case .failure(let failure) = response.result else {
            Issue.record("enqueuing an unknown track must fail, not silently succeed")
            return
        }
        #expect(failure.message.contains("ghost-track"))
    }

    /// The list a downloads screen renders. Every entry carries its track's
    /// (server, remote) identity so a shell can act on it, and a state filter
    /// narrows it — the completed-only view a "Downloaded" tab shows.
    @Test func downloadsListReflectsStateAndFilters() async throws {
        let (dispatcher, repository) = try await Self.downloadFixture()
        let tracks = try await Self.someTracks(repository, 3)

        // Two completed, one left queued.
        for track in tracks.prefix(2) {
            _ = try await Self.send(dispatcher) {
                var request = Mozz_V1_EnqueueDownloadRequest()
                request.serverID = track.serverId
                request.remoteID = track.remoteId
                $0.enqueueDownload = request
            }
            _ = try await Self.send(dispatcher) {
                var request = Mozz_V1_CompleteDownloadRequest()
                request.serverID = track.serverId
                request.remoteID = track.remoteId
                request.localPath = "downloads/\(track.remoteId).flac"
                request.sizeBytes = 1000
                $0.completeDownload = request
            }
        }
        let queuedTrack = tracks[2]
        _ = try await Self.send(dispatcher) {
            var request = Mozz_V1_EnqueueDownloadRequest()
            request.serverID = queuedTrack.serverId
            request.remoteID = queuedTrack.remoteId
            $0.enqueueDownload = request
        }

        // No filter → all three, each addressable.
        let all = try await Self.send(dispatcher) {
            $0.downloads = Mozz_V1_DownloadsRequest()
        }
        guard case .downloads(let allPayload) = all.result else {
            Issue.record("expected downloads, got \(String(describing: all.result))")
            return
        }
        #expect(allPayload.downloads.count == 3)
        for entry in allPayload.downloads {
            #expect(!entry.serverID.isEmpty)
            #expect(!entry.remoteID.isEmpty)
        }

        // Filter to downloaded → only the two completed ones.
        let downloadedOnly = try await Self.send(dispatcher) {
            var request = Mozz_V1_DownloadsRequest()
            request.states = [.downloaded]
            $0.downloads = request
        }
        guard case .downloads(let filtered) = downloadedOnly.result else {
            Issue.record("expected downloads, got \(String(describing: downloadedOnly.result))")
            return
        }
        #expect(filtered.downloads.count == 2)
        #expect(filtered.downloads.allSatisfy { $0.state == .downloaded })
        let completedRemoteIds = Set(tracks.prefix(2).map(\.remoteId))
        #expect(Set(filtered.downloads.map(\.remoteID)) == completedRemoteIds)
    }

    /// Storage usage counts only completed downloads and sums their sizes — the
    /// number a storage screen shows. A queued or failed download uses no disk
    /// and must not be counted.
    @Test func storageUsageCountsOnlyCompletedDownloads() async throws {
        let (dispatcher, repository) = try await Self.downloadFixture()
        let tracks = try await Self.someTracks(repository, 3)

        // Two completed (1500 + 2500 bytes)…
        let sizes: [Int64] = [1500, 2500]
        for (track, size) in zip(tracks.prefix(2), sizes) {
            _ = try await Self.send(dispatcher) {
                var request = Mozz_V1_EnqueueDownloadRequest()
                request.serverID = track.serverId
                request.remoteID = track.remoteId
                $0.enqueueDownload = request
            }
            _ = try await Self.send(dispatcher) {
                var request = Mozz_V1_CompleteDownloadRequest()
                request.serverID = track.serverId
                request.remoteID = track.remoteId
                request.localPath = "downloads/\(track.remoteId).flac"
                request.sizeBytes = size
                $0.completeDownload = request
            }
        }
        // …and one merely queued, which must not count toward storage.
        _ = try await Self.send(dispatcher) {
            var request = Mozz_V1_EnqueueDownloadRequest()
            request.serverID = tracks[2].serverId
            request.remoteID = tracks[2].remoteId
            $0.enqueueDownload = request
        }

        let usage = try await Self.send(dispatcher) {
            $0.storageUsage = Mozz_V1_StorageUsageRequest()
        }
        guard case .storageUsage(let payload) = usage.result else {
            Issue.record("expected storageUsage, got \(String(describing: usage.result))")
            return
        }
        #expect(payload.downloadedTrackCount == 2)
        #expect(payload.totalBytes == 4000)
    }

    /// The request id is echoed on a download command's response, the same as
    /// every other path, so a caller can pair concurrent requests.
    @Test func theRequestIdComesBackOnDownloadCommands() async throws {
        let (dispatcher, repository) = try await Self.downloadFixture()
        let track = try #require(try await Self.someTracks(repository, 1).first)

        var request = Mozz_V1_Request()
        request.id = 77_042
        request.enqueueDownload = {
            var enqueue = Mozz_V1_EnqueueDownloadRequest()
            enqueue.serverID = track.serverId
            enqueue.remoteID = track.remoteId
            return enqueue
        }()

        let bytes = await dispatcher.handle(try request.serializedData())
        let response = try Mozz_V1_Response(serializedBytes: bytes)
        #expect(response.id == 77_042)
    }

    // MARK: Enrichment
    //
    // Lyrics, canonical recording identity, and similar tracks over the same
    // bytes-in/bytes-out surface — the features that used to reach only the Apple
    // shell. The load-bearing property is the lyrics status: absent, not-fetched,
    // and failed are three different answers, and a shell that can't tell them
    // apart is the exact bug where a panel shows nothing and never retries.

    /// The seed/owned-track MBIDs, deliberately distinct raw vs canonical so a
    /// test can't pass by confusing one for the other.
    private static let rawL  = "aaaaaaa1-0000-4000-8000-0000000000a1"
    private static let canL  = "caaaaaa1-0000-4000-8000-0000000000c1"
    private static let rawB2 = "bbbbbbb2-0000-4000-8000-0000000000b2"
    private static let canB2 = "cbbbbbb2-0000-4000-8000-0000000000c2"
    private static let rawC3 = "ccccccc3-0000-4000-8000-0000000000c3"
    private static let canC3 = "ccccccc3-0000-4000-8000-0000000000d3"
    private static let artistMbid = "a4715555-0000-4000-8000-000000000a55"

    private struct EnrichmentFixture {
        let dispatcher: CommandDispatcher
        let writer: CatalogWriter
        let store: EnrichmentStore
        let memo: LyricsMemoCache
        let disk: LyricsDiskCache
        let offline: LyricsDiskCache
    }

    /// A fixture over one real database, sharing it between the catalog writer,
    /// the enrichment store, and the command service, so a seed is visible to the
    /// next command — the download tests use the same shared-DB shape.
    private static func enrichmentFixture() async throws -> EnrichmentFixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("commands-enrich-\(UUID().uuidString).sqlite")
        let db = try MusicDatabase.open(at: url)
        let writer = CatalogWriter(db)
        try await writer.saveServer(ServerConnection(
            id: "srv1", kind: .plex, name: "T",
            baseURL: URL(string: "https://x.local")!, userID: nil, clientIdentifier: "c1"))
        let repository = LibraryRepository(db)
        let store = EnrichmentStore(db)

        let diskDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let offlineDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: offlineDir, withIntermediateDirectories: true)
        // Fresh caches AND fresh backoffs: the service reads process-wide statics
        // by default, so a test must inject its own to stay isolated and to keep
        // the resolve gate open (a fresh NetworkBackoff attempts).
        let memo = LyricsMemoCache(limit: 32)
        let disk = LyricsDiskCache(directory: diskDir)
        let offline = LyricsDiskCache(directory: offlineDir)
        let lyricsService = LyricsService(
            memo: memo, disk: disk, offline: offline,
            lrclibBackoff: NetworkBackoff(), serverBackoff: NetworkBackoff())

        let service = LibraryCommandService(
            repository: repository,
            playbackSettings: PlaybackSettingsStore(try MusicDatabase.inMemory()),
            downloads: DownloadStore(try MusicDatabase.inMemory()),
            lyricsService: lyricsService, enrichmentStore: store)
        return EnrichmentFixture(
            dispatcher: CommandDispatcher(service: service),
            writer: writer, store: store, memo: memo, disk: disk, offline: offline)
    }

    /// The lyrics cache key for an owned track with no backend — just the remote
    /// id, since `Track.id` is the remote id and there is no connection id.
    private static func lyricsKey(_ remoteId: String) -> String {
        LyricsCacheKey.make(trackID: remoteId, connectionID: nil)
    }

    private static func lyricsResponse(
        _ fx: EnrichmentFixture, remoteId: String,
        resolve: Bool = false, useOnlineLookup: Bool = false
    ) async throws -> Mozz_V1_Response {
        try await send(fx.dispatcher) {
            var request = Mozz_V1_LyricsRequest()
            request.serverID = "srv1"
            request.remoteID = remoteId
            request.resolve = resolve
            request.useOnlineLookup = useOnlineLookup
            $0.lyrics = request
        }
    }

    // MARK: Lyrics

    @Test func lyricsUnknownTrackIsAFailure() async throws {
        let fx = try await Self.enrichmentFixture()
        let response = try await Self.lyricsResponse(fx, remoteId: "ghost")
        guard case .failure(let failure) = response.result else {
            Issue.record("lyrics for a track the catalog never saw must fail, not answer emptily")
            return
        }
        #expect(failure.message.contains("ghost"))
    }

    /// A cache-only read of a track nobody has resolved is NOT_FETCHED — the one
    /// answer resolve can never give, and the whole reason cache-only mode exists.
    @Test func lyricsCacheOnlyMissIsNotFetched() async throws {
        let fx = try await Self.enrichmentFixture()
        try await fx.writer.upsertTracks(
            [Track(id: "tL", title: "Ordinary Song", artistName: "An Artist")], serverId: "srv1")
        let response = try await Self.lyricsResponse(fx, remoteId: "tL")
        guard case .lyrics(let payload) = response.result else {
            Issue.record("expected lyrics, got \(String(describing: response.result))")
            return
        }
        #expect(payload.status == .notFetched)
        #expect(!payload.hasLyrics)
    }

    @Test func lyricsCacheOnlyPositiveIsPresent() async throws {
        let fx = try await Self.enrichmentFixture()
        try await fx.writer.upsertTracks(
            [Track(id: "tL", title: "Ordinary Song", artistName: "An Artist")], serverId: "srv1")
        let lyrics = Lyrics(lines: [LyricLine(text: "first line", start: 0.5),
                                    LyricLine(text: "second line", start: 1.0)])
        await fx.memo.set(lyrics, for: Self.lyricsKey("tL"))

        let response = try await Self.lyricsResponse(fx, remoteId: "tL")
        guard case .lyrics(let payload) = response.result else {
            Issue.record("expected lyrics, got \(String(describing: response.result))")
            return
        }
        #expect(payload.status == .present)
        #expect(payload.lyrics.lines.count == 2)
        #expect(payload.lyrics.lines.first?.text == "first line")
        #expect(payload.lyrics.isSynced)
    }

    /// A persisted negative reads back as ABSENT ("we asked, there are none"),
    /// distinct from the NOT_FETCHED of an untouched track above.
    @Test func lyricsCacheOnlyPersistedNegativeIsAbsent() async throws {
        let fx = try await Self.enrichmentFixture()
        try await fx.writer.upsertTracks(
            [Track(id: "tL", title: "Ordinary Song", artistName: "An Artist")], serverId: "srv1")
        await fx.disk.store(nil, for: Self.lyricsKey("tL"))

        let response = try await Self.lyricsResponse(fx, remoteId: "tL")
        guard case .lyrics(let payload) = response.result else {
            Issue.record("expected lyrics, got \(String(describing: response.result))")
            return
        }
        #expect(payload.status == .absent)
        #expect(!payload.hasLyrics)
    }

    /// resolve mode returns a cached positive without any network — proving the
    /// caches are consulted first.
    @Test func lyricsResolveReturnsCachedPositive() async throws {
        let fx = try await Self.enrichmentFixture()
        try await fx.writer.upsertTracks(
            [Track(id: "tL", title: "Ordinary Song", artistName: "An Artist")], serverId: "srv1")
        let lyrics = Lyrics(lines: [LyricLine(text: "cached words", start: 2.0)])
        await fx.disk.store(lyrics, for: Self.lyricsKey("tL"))

        let response = try await Self.lyricsResponse(fx, remoteId: "tL", resolve: true)
        guard case .lyrics(let payload) = response.result else {
            Issue.record("expected lyrics, got \(String(describing: response.result))")
            return
        }
        #expect(payload.status == .present)
        #expect(payload.lyrics.lines.first?.text == "cached words")
    }

    /// resolve over a persisted authoritative negative is ABSENT, recovered via
    /// the follow-up cache read (resolve alone stays silent for both absent and
    /// failed).
    @Test func lyricsResolveAuthoritativeNegativeIsAbsent() async throws {
        let fx = try await Self.enrichmentFixture()
        try await fx.writer.upsertTracks(
            [Track(id: "tL", title: "Ordinary Song", artistName: "An Artist")], serverId: "srv1")
        await fx.disk.store(nil, for: Self.lyricsKey("tL"))

        let response = try await Self.lyricsResponse(fx, remoteId: "tL", resolve: true)
        guard case .lyrics(let payload) = response.result else {
            Issue.record("expected lyrics, got \(String(describing: response.result))")
            return
        }
        #expect(payload.status == .absent)
    }

    /// resolve with nothing cached, online lookup off, and no reachable backend:
    /// the negative is not authoritative, so it is FAILED (retry), NOT absent. The
    /// follow-up cache read is a miss because resolve refused to persist an
    /// untrusted negative.
    @Test func lyricsResolveTransientIsFailed() async throws {
        let fx = try await Self.enrichmentFixture()
        try await fx.writer.upsertTracks(
            [Track(id: "tL", title: "Ordinary Song", artistName: "An Artist")], serverId: "srv1")

        let response = try await Self.lyricsResponse(
            fx, remoteId: "tL", resolve: true, useOnlineLookup: false)
        guard case .lyrics(let payload) = response.result else {
            Issue.record("expected lyrics, got \(String(describing: response.result))")
            return
        }
        #expect(payload.status == .failed)
        #expect(!payload.hasLyrics)
    }

    // MARK: Recording identity

    @Test func recordingIdentityResolvedCarriesRawCanonicalAndArtist() async throws {
        let fx = try await Self.enrichmentFixture()
        try await fx.writer.upsertTracks(
            [Track(id: "tL", title: "Song", artistName: "AA",
                   mbid: Self.rawL, artistMbid: Self.artistMbid)], serverId: "srv1")
        try await fx.store.setCanonical(mbid: Self.rawL, canonical: Self.canL, at: 100)

        let response = try await Self.send(fx.dispatcher) {
            var request = Mozz_V1_RecordingIdentityRequest()
            request.serverID = "srv1"
            request.remoteID = "tL"
            $0.recordingIdentity = request
        }
        guard case .recordingIdentity(let payload) = response.result else {
            Issue.record("expected recordingIdentity, got \(String(describing: response.result))")
            return
        }
        #expect(payload.status == .resolved)
        #expect(payload.recordingMbid == Self.rawL)
        #expect(payload.canonicalRecordingMbid == Self.canL)
        #expect(payload.artistMbid == Self.artistMbid)
    }

    @Test func recordingIdentityUnmatchedAfterNotFoundLookup() async throws {
        let fx = try await Self.enrichmentFixture()
        try await fx.writer.upsertTracks(
            [Track(id: "tU", title: "Obscure", artistName: "Nobody")], serverId: "srv1")
        // A name-search that found nothing writes the authoritative notfound.
        try await fx.store.recordTrackResolution(
            trackRef: PlayEventStore.trackRef(serverId: "srv1", remoteId: "tU"),
            mbid: nil, artistMbid: nil, at: 100)

        let response = try await Self.send(fx.dispatcher) {
            var request = Mozz_V1_RecordingIdentityRequest()
            request.serverID = "srv1"
            request.remoteID = "tU"
            $0.recordingIdentity = request
        }
        guard case .recordingIdentity(let payload) = response.result else {
            Issue.record("expected recordingIdentity, got \(String(describing: response.result))")
            return
        }
        #expect(payload.status == .unmatched)
        #expect(!payload.hasRecordingMbid)
    }

    /// Both an un-looked-up track and a track the catalog never saw read as
    /// NOT_RESOLVED — a pollable "not yet", never an error.
    @Test func recordingIdentityNotResolvedForUnlookedAndUnknown() async throws {
        let fx = try await Self.enrichmentFixture()
        try await fx.writer.upsertTracks(
            [Track(id: "tN", title: "Fresh", artistName: "AA")], serverId: "srv1")

        for remoteId in ["tN", "ghost"] {
            let response = try await Self.send(fx.dispatcher) {
                var request = Mozz_V1_RecordingIdentityRequest()
                request.serverID = "srv1"
                request.remoteID = remoteId
                $0.recordingIdentity = request
            }
            guard case .recordingIdentity(let payload) = response.result else {
                Issue.record("expected recordingIdentity for \(remoteId), got \(String(describing: response.result))")
                return
            }
            #expect(payload.status == .notResolved)
        }
    }

    // MARK: Similar tracks

    @Test func similarTracksRankedHydratedAndScored() async throws {
        let fx = try await Self.enrichmentFixture()
        try await fx.writer.upsertTracks([
            Track(id: "tL", title: "Seed", artistName: "AA", mbid: Self.rawL),
            Track(id: "tB", title: "Near", artistName: "BB", mbid: Self.rawB2),
            Track(id: "tC", title: "Far", artistName: "CC", mbid: Self.rawC3),
        ], serverId: "srv1")
        try await fx.store.setCanonical(mbid: Self.rawL, canonical: Self.canL, at: 100)
        try await fx.store.setCanonical(mbid: Self.rawB2, canonical: Self.canB2, at: 100)
        try await fx.store.setCanonical(mbid: Self.rawC3, canonical: Self.canC3, at: 100)
        // Similar rows are keyed by the SEED's canonical MBID; the default
        // algorithm is what the FFI wires, so seed under it.
        try await fx.store.replaceSimilarRecordings(
            sourceMbid: Self.canL, algorithm: EnrichmentConfig.defaultListenBrainzAlgorithm,
            pairs: [(Self.canB2, 0.9), (Self.canC3, 0.5)], at: 500)

        let response = try await Self.send(fx.dispatcher) {
            var request = Mozz_V1_SimilarTracksRequest()
            request.serverID = "srv1"
            request.remoteID = "tL"
            request.limit = 10
            $0.similarTracks = request
        }
        guard case .similarTracks(let payload) = response.result else {
            Issue.record("expected similarTracks, got \(String(describing: response.result))")
            return
        }
        #expect(payload.tracks.count == 2)
        #expect(payload.tracks.map(\.track.remoteID) == ["tB", "tC"])   // ranked by score
        #expect(payload.tracks.first?.track.title == "Near")            // full metadata hydrated
        #expect(payload.tracks.first?.score == 0.9)
        #expect(payload.tracks.last?.score == 0.5)
    }

    /// No canonical MBID yet → an empty set, not an error: similarity is keyed by
    /// the canonical, which canonicalization has not produced. Mirrors the app.
    @Test func similarTracksEmptyWithoutCanonical() async throws {
        let fx = try await Self.enrichmentFixture()
        try await fx.writer.upsertTracks(
            [Track(id: "tL", title: "Seed", artistName: "AA", mbid: Self.rawL)], serverId: "srv1")
        // Embedded MBID present, but setCanonical never ran.

        let response = try await Self.send(fx.dispatcher) {
            var request = Mozz_V1_SimilarTracksRequest()
            request.serverID = "srv1"
            request.remoteID = "tL"
            request.limit = 10
            $0.similarTracks = request
        }
        guard case .similarTracks(let payload) = response.result else {
            Issue.record("expected similarTracks, got \(String(describing: response.result))")
            return
        }
        #expect(payload.tracks.isEmpty)
    }
}
