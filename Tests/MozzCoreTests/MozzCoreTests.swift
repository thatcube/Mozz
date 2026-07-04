import XCTest
@testable import MozzCore

final class DomainModelTests: XCTestCase {
    func testTrackCodableRoundTrip() throws {
        let track = Track(
            id: "42",
            title: "Paranoid Android",
            sortTitle: "Paranoid Android",
            albumTitle: "OK Computer",
            albumID: "7",
            artistName: "Radiohead",
            artistID: "3",
            albumArtistName: "Radiohead",
            trackNumber: 2,
            discNumber: 1,
            duration: 383.0,
            format: AudioFormat(container: "flac", codec: "flac", bitrateKbps: 900, sampleRateHz: 44100, channels: 2, bitDepth: 16),
            fileSizeBytes: 40_000_000,
            mediaKey: "/library/parts/99/file.flac",
            artwork: ArtworkRef(key: "/library/metadata/7/thumb/123"),
            genres: ["Alternative", "Rock"],
            isFavorite: true,
            normalizationGainDB: -6.5,
            addedAt: Date(timeIntervalSince1970: 1_600_000_000)
        )

        let data = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(Track.self, from: data)
        XCTAssertEqual(track, decoded)
    }

    func testAlbumAndArtistCodableRoundTrip() throws {
        let artist = Artist(id: "1", name: "Boards of Canada", albumCount: 4, genres: ["Electronic"], isFavorite: true)
        let album = Album(id: "9", title: "Music Has the Right to Children", artistName: "Boards of Canada", artistID: "1", year: 1998, trackCount: 17)

        let a = try JSONDecoder().decode(Artist.self, from: JSONEncoder().encode(artist))
        let b = try JSONDecoder().decode(Album.self, from: JSONEncoder().encode(album))
        XCTAssertEqual(artist, a)
        XCTAssertEqual(album, b)
    }

    func testDefaultsAreSane() {
        let track = Track(id: "x", title: "t", artistName: "a")
        XCTAssertEqual(track.duration, 0)
        XCTAssertFalse(track.isFavorite)
        XCTAssertTrue(track.genres.isEmpty)
        XCTAssertNil(track.artwork)
    }
}

final class PlaybackModeTests: XCTestCase {
    func testRepeatModeCycles() {
        XCTAssertEqual(RepeatMode.off.next, .all)
        XCTAssertEqual(RepeatMode.all.next, .one)
        XCTAssertEqual(RepeatMode.one.next, .off)
    }

    func testShuffleToggle() {
        var mode = ShuffleMode.off
        mode.toggle()
        XCTAssertEqual(mode, .on)
        mode.toggle()
        XCTAssertEqual(mode, .off)
    }
}

final class MozzErrorTests: XCTestCase {
    func testRetryability() {
        XCTAssertTrue(MozzError.serverUnreachable.isRetryable)
        XCTAssertTrue(MozzError.transport("x").isRetryable)
        XCTAssertTrue(MozzError.badStatus(503).isRetryable)
        XCTAssertTrue(MozzError.badStatus(429).isRetryable)
        XCTAssertFalse(MozzError.badStatus(404).isRetryable)
        XCTAssertFalse(MozzError.unauthorized.isRetryable)
        XCTAssertFalse(MozzError.notFound.isRetryable)
        XCTAssertFalse(MozzError.decodingFailed("x").isRetryable)
    }

    func testReachabilityClassification() {
        XCTAssertTrue(MozzError.serverUnreachable.isReachabilityFailure)
        XCTAssertTrue(MozzError.transport("x").isReachabilityFailure)
        XCTAssertFalse(MozzError.unauthorized.isReachabilityFailure)
        XCTAssertFalse(MozzError.badStatus(500).isReachabilityFailure)
    }
}

final class CredentialStoreTests: XCTestCase {
    func testTokenLifecycle() throws {
        let store = InMemoryCredentialStore()
        XCTAssertNil(try store.token(for: "srv1"))

        try store.setToken("abc123", for: "srv1")
        XCTAssertEqual(try store.token(for: "srv1"), "abc123")

        try store.setToken(nil, for: "srv1")
        XCTAssertNil(try store.token(for: "srv1"))
    }

    func testClientIdentifierIsStable() throws {
        let store = InMemoryCredentialStore()
        let first = try store.clientIdentifier()
        let second = try store.clientIdentifier()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second, "client identifier must never be regenerated")
    }

    func testClientIdentifierNotGeneratedWhenSuppressed() throws {
        let store = InMemoryCredentialStore()
        XCTAssertEqual(try store.clientIdentifier(generatingIfMissing: false), "")
        // And it should not have been persisted.
        XCTAssertNil(try store.string(forKey: "clientIdentifier"))
    }
}

final class PlexAuthURLTests: XCTestCase {
    func testAuthAppURLContainsCodeAndClientID() throws {
        let session = PlexPinSession(id: 1, code: "WXYZ", clientIdentifier: "client-uuid-123")
        let info = ClientInfo(product: "Mozz", version: "1.0", deviceName: "iPhone", platform: "iOS", platformVersion: "17.0")
        let url = try XCTUnwrap(session.authAppURL(clientInfo: info))
        let string = url.absoluteString
        XCTAssertTrue(string.hasPrefix("https://app.plex.tv/auth#?"))
        XCTAssertTrue(string.contains("code=WXYZ"))
        XCTAssertTrue(string.contains("clientID=client-uuid-123"))
        XCTAssertTrue(string.contains("Mozz"))
    }
}
