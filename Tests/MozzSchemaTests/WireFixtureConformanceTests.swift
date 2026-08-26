import Foundation
import Testing
import SwiftProtobuf
@testable import MozzSchema

/// Conformance against `spec/schema/wire-fixtures.json` — the same bytes every
/// other client checks itself against.
///
/// The point is not that SwiftProtobuf works; it is that *this* schema, as
/// committed, produces and accepts the bytes the C# and future Kotlin and
/// TypeScript clients also produce and accept. A field renumbered in the schema,
/// or generated output that drifted from the schema without being regenerated,
/// fails here rather than in production on whichever platform nobody ran.
///
/// The fixtures were produced by `protoc --encode`, so no client is the
/// definition of the wire format — each is measured against a neutral third
/// party.
@Suite struct WireFixtureConformanceTests {

    // MARK: Fixture model

    private struct Fixtures: Decodable {
        var cases: [Case]
    }

    private struct Case: Decodable {
        var name: String
        var type: String
        var base64: String
    }

    /// Walk up from this source file to the repository root. The fixtures are
    /// deliberately NOT a test-bundle resource: they belong to `spec/`, shared
    /// with every other implementation, and copying them into the bundle would
    /// create a second copy that could drift from the one other languages read.
    private static func specURL() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("spec/schema/wire-fixtures.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: "spec/schema/wire-fixtures.json")
    }

    private static func load() throws -> Fixtures {
        let data = try Data(contentsOf: specURL())
        return try JSONDecoder().decode(Fixtures.self, from: data)
    }

    private static func bytes(_ name: String) throws -> Data {
        let fixtures = try load()
        guard let match = fixtures.cases.first(where: { $0.name == name }) else {
            Issue.record("no fixture named \(name)")
            return Data()
        }
        guard let decoded = Data(base64Encoded: match.base64) else {
            Issue.record("fixture \(name) is not valid base64")
            return Data()
        }
        return decoded
    }

    // MARK: Decoding

    @Test func decodesArtistRequest() throws {
        let request = try Mozz_V1_Request(serializedBytes: Self.bytes("artist-request"))

        #expect(request.id == 42)
        guard case .artist(let artist) = request.command else {
            Issue.record("expected the artist command, got \(String(describing: request.command))")
            return
        }
        #expect(artist.serverID == "plex-a1b2c3")
        #expect(artist.remoteID == "/library/metadata/9987")
    }

    @Test func decodesPagedAlbumsRequestAndPreservesTheCursor() throws {
        let request = try Mozz_V1_Request(serializedBytes: Self.bytes("albums-request-paged"))

        #expect(request.id == 7)
        guard case .albums(let albums) = request.command else {
            Issue.record("expected the albums command, got \(String(describing: request.command))")
            return
        }
        #expect(albums.serverID == "jellyfin-77")
        #expect(albums.limit == 200)
        #expect(albums.hasAfter)
        // The cursor is opaque: it must come back exactly as it went out, not
        // normalised, re-encoded or trimmed.
        #expect(albums.after.token == "eyJvIjoyMDB9")
    }

    @Test func decodesFailureAsAResultRatherThanASideChannel() throws {
        let response = try Mozz_V1_Response(serializedBytes: Self.bytes("failure-response"))

        #expect(response.id == 42)
        guard case .failure(let failure) = response.result else {
            Issue.record("expected a failure result, got \(String(describing: response.result))")
            return
        }
        #expect(failure.message == "artist not found: /library/metadata/9987")
    }

    @Test func decodesAnUnpromptedSubscriptionEvent() throws {
        let event = try Mozz_V1_Event(serializedBytes: Self.bytes("library-changed-event"))

        #expect(event.token.id == 3)
        guard case .libraryChanged(let changed) = event.payload else {
            Issue.record("expected libraryChanged, got \(String(describing: event.payload))")
            return
        }
        #expect(changed.changedEntities == ["album", "track"])
    }

    // MARK: Encoding

    /// Decoding a fixture and re-encoding it must reproduce the original bytes.
    ///
    /// This is the half that catches a renumbered field. Decoding alone would
    /// still pass if two fields swapped numbers in a compatible way; only
    /// comparing the bytes back out pins the wire format itself.
    @Test func reEncodingReproducesTheFixtureBytesExactly() throws {
        for name in ["artist-request", "albums-request-paged"] {
            let original = try Self.bytes(name)
            let round = try Mozz_V1_Request(serializedBytes: original).serializedData()
            #expect(round == original, "\(name) did not survive a round trip byte-for-byte")
        }

        let failure = try Self.bytes("failure-response")
        #expect(try Mozz_V1_Response(serializedBytes: failure).serializedData() == failure)

        let event = try Self.bytes("library-changed-event")
        #expect(try Mozz_V1_Event(serializedBytes: event).serializedData() == event)
    }

    // MARK: Dispatch

    /// The property the whole schema exists for: a command that the core has not
    /// implemented cannot silently do nothing.
    ///
    /// This switch has no `default`. Adding a command to `library.proto` and
    /// regenerating makes this file stop compiling until the new case is
    /// handled — which is the compile-time version of the bug that put four
    /// parity defects into one week, where a capability existed in the core and
    /// only Apple platforms could see it.
    @Test func everyDeclaredCommandIsAccountedFor() throws {
        let request = try Mozz_V1_Request(serializedBytes: Self.bytes("artist-request"))

        let name: String
        switch request.command {
        case .libraries: name = "libraries"
        case .albums: name = "albums"
        case .artists: name = "artists"
        case .tracks: name = "tracks"
        case .artist: name = "artist"
        case .albumTracks: name = "albumTracks"
        case .artistAlbums: name = "artistAlbums"
        case .counts: name = "counts"
        case .watchLibrary: name = "watchLibrary"
        case .cancel: name = "cancel"
        case .none: name = "none"
        }

        #expect(name == "artist")
    }
}
