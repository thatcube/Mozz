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

    private static func dispatcher(_ repository: LibraryRepository) -> CommandDispatcher {
        CommandDispatcher(service: LibraryCommandService(repository: repository))
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
        let dispatcher = Self.dispatcher(repository)

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
    }

    /// Walking the pages must visit each album once — the property the cursor
    /// exists for, now checked through the wire rather than only in the
    /// repository's own tests.
    @Test func walkingTheCursorVisitsEveryAlbumExactlyOnce() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = Self.dispatcher(repository)

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
        let dispatcher = Self.dispatcher(repository)

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
        #expect(payload.artist.remoteID == known.remoteId)
        #expect(payload.artist.name == known.name)
    }

    // MARK: Failing usefully

    @Test func anAbsentArtistIsAFailureRatherThanAnEmptyArtist() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = Self.dispatcher(repository)

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
        let dispatcher = Self.dispatcher(repository)

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

    /// Bytes that are not a request at all must not take the process down.
    ///
    /// This crosses a C ABI in production, where a thrown Swift error is a
    /// crash rather than an exception the caller can catch.
    @Test func garbageBytesProduceAFailureRatherThanACrash() async throws {
        let repository = try await Self.makeLibrary()
        let dispatcher = Self.dispatcher(repository)

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
        let dispatcher = Self.dispatcher(repository)

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
        let dispatcher = Self.dispatcher(repository)

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
}
