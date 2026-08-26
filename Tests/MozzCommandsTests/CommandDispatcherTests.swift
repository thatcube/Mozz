import Foundation
import Testing
import MozzCore
import MozzDatabase
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
        // Catalog tests never touch playback settings; an isolated in-memory
        // store keeps them independent. The playback-settings tests below build
        // their own dispatcher over a shared store so a write is visible to the
        // next read.
        let store = PlaybackSettingsStore(try MusicDatabase.inMemory())
        return CommandDispatcher(service: LibraryCommandService(repository: repository, playbackSettings: store))
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
}
