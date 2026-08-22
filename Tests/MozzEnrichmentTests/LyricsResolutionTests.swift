import XCTest
import MozzCore
@testable import MozzEnrichment

final class LyricsResolutionTests: XCTestCase {

    // MARK: Title cleaning

    /// Regression: without a `\b` word boundary the `feat`/`ft` patterns matched
    /// *inside* ordinary words, truncating titles to a couple of letters and
    /// spawning a garbage second query.
    func testCleanedTitlePreservesWordsEndingInFtOrFeat() {
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Soft Rock"), "Soft Rock")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Lift Me Up"), "Lift Me Up")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Drift Away"), "Drift Away")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Defeat the Villain"), "Defeat the Villain")
    }

    func testCleanedTitleStripsFeatureCredits() {
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Lose Yourself (feat. Dido)"), "Lose Yourself")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Stan - feat. Dido"), "Stan")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Forever ft. Drake"), "Forever")
    }

    func testCleanedTitleStripsParentheticalsAndBrackets() {
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Tarzan Boy (Summer Version)"), "Tarzan Boy")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Song [2010 Remaster]"), "Song")
    }

    // MARK: Reachability

    /// Only a definitive 404 is a real "not there". Everything else is transient
    /// or a non-verdict and must never be cached as "no lyrics".
    func testOnlyNotFoundIsAnAuthoritativeAnswer() {
        XCTAssertTrue(LRCLIBLyricsProvider.reachability(for: .notFound))
        for error: MozzError in [
            .serverUnreachable, .unauthorized, .conflict, .invalidResponse,
            .cancelled, .transport("boom"), .decodingFailed("bad"),
            .badStatus(429), .badStatus(500), .badStatus(502), .badStatus(503), .badStatus(400),
        ] {
            XCTAssertFalse(
                LRCLIBLyricsProvider.reachability(for: error),
                "\(error) must not be treated as an authoritative negative"
            )
        }
    }

    // MARK: Version selection

    /// A version whose length is wildly different is a different cut; its
    /// timestamps would drift the panel progressively out of sync, which is worse
    /// than showing nothing.
    func testVersionDurationCeilingRejectsWrongLengthVersions() {
        let track: TimeInterval = 240
        XCTAssertTrue(LRCLIBLyricsProvider.versionDurationAcceptable(recordDuration: 242, trackDuration: track))
        XCTAssertTrue(LRCLIBLyricsProvider.versionDurationAcceptable(recordDuration: 234, trackDuration: track))
        XCTAssertTrue(LRCLIBLyricsProvider.versionDurationAcceptable(
            recordDuration: track + LRCLIBLyricsProvider.durationVersionCeiling, trackDuration: track
        ))
        // A radio edit against an extended mix — reject.
        XCTAssertFalse(LRCLIBLyricsProvider.versionDurationAcceptable(recordDuration: 210, trackDuration: track))
        XCTAssertFalse(LRCLIBLyricsProvider.versionDurationAcceptable(recordDuration: 360, trackDuration: track))
        // A record with no length of its own can't be matched safely.
        XCTAssertFalse(LRCLIBLyricsProvider.versionDurationAcceptable(recordDuration: nil, trackDuration: track))
    }

    func testBestMatchPrefersSyncedThenClosestDuration() throws {
        let plainClose = LRCLIBRecord(
            duration: 240, instrumental: false, plainLyrics: "words", syncedLyrics: nil
        )
        let syncedFar = LRCLIBRecord(
            duration: 400, instrumental: false, plainLyrics: nil, syncedLyrics: "[00:01.00]a"
        )
        let syncedNear = LRCLIBRecord(
            duration: 243, instrumental: false, plainLyrics: nil, syncedLyrics: "[00:02.00]b"
        )
        // Synced beats a closer-length plain record...
        let syncedPick = try XCTUnwrap(
            LRCLIBLyricsProvider.bestMatch(in: [plainClose, syncedFar], duration: 240)
        )
        XCTAssertEqual(syncedPick.duration, 400)
        // ...and among synced records, the closest length wins.
        let nearestPick = try XCTUnwrap(
            LRCLIBLyricsProvider.bestMatch(in: [syncedFar, syncedNear], duration: 240)
        )
        XCTAssertEqual(nearestPick.duration, 243)
    }

    func testInstrumentalRecordsYieldNoLyrics() {
        let record = LRCLIBRecord(
            duration: 200, instrumental: true, plainLyrics: "should be ignored", syncedLyrics: nil
        )
        XCTAssertNil(record.lyrics())
        XCTAssertNil(LRCLIBLyricsProvider.bestMatch(in: [record], duration: 200))
    }

    func testRecordPrefersSyncedOverPlainAndTagsSource() throws {
        let record = LRCLIBRecord(
            duration: 200, instrumental: false,
            plainLyrics: "plain", syncedLyrics: "[00:01.00]timed"
        )
        let lyrics = try XCTUnwrap(record.lyrics())
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.source, .lrclib)
    }

    // MARK: Negative authority

    /// The happy path: every source we needed answered, at full effort.
    func testNegativeIsAuthoritativeWhenAllSourcesAnswered() {
        XCTAssertTrue(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibConsulted: true,
            lrclibReachable: true,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    func testNegativeIsNotAuthoritativeWhenServerUnreachable() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: false,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibConsulted: true,
            lrclibReachable: true,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// We never asked our best source, so the verdict is incomplete — caching it
    /// would burn "no lyrics" onto tracks LRCLIB actually has.
    func testNegativeIsNotAuthoritativeWhenLRCLIBSkippedForMissingArtist() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: true,
            lrclibSkippedForDisabled: false,
            lrclibConsulted: false,
            lrclibReachable: false,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// A temporary setting is not a verdict: turning lyrics lookups back on must
    /// re-ask rather than read a poisoned negative.
    func testNegativeIsNotAuthoritativeWhenLookupDisabled() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: true,
            lrclibConsulted: false,
            lrclibReachable: false,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    func testNegativeIsNotAuthoritativeWhenLRCLIBUnreachable() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibConsulted: true,
            lrclibReachable: false,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// A background prefetch skips the title-only fallback, so its negative is
    /// reduced-effort. Trusting it would suppress the visible play's full lookup.
    func testReducedEffortPrefetchNegativeIsNotAuthoritative() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibConsulted: true,
            lrclibReachable: true,
            allowedTitleOnlyFallback: false,
            hasUsableDuration: true
        ))
    }

    /// Without a duration the visible resolve couldn't have run the fallback
    /// either, so that negative is as complete as it will ever get.
    func testPrefetchNegativeIsAuthoritativeWithoutUsableDuration() {
        XCTAssertTrue(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibConsulted: true,
            lrclibReachable: true,
            allowedTitleOnlyFallback: false,
            hasUsableDuration: false
        ))
    }

    // MARK: Cache

    /// Server track IDs are only locally unique, so two servers can collide on the
    /// raw id and leak one library's lyrics — or its remembered negatives — into
    /// another.
    func testCacheKeyIsScopedByConnection() {
        let a = LyricsCacheKey.make(trackID: "42", connectionID: "server-a")
        let b = LyricsCacheKey.make(trackID: "42", connectionID: "server-b")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(LyricsCacheKey.make(trackID: "42", connectionID: nil), "42")
        XCTAssertEqual(LyricsCacheKey.make(trackID: "42", connectionID: ""), "42")
    }

    func testMemoCacheDistinguishesMissFromRememberedNegative() async {
        let cache = LyricsMemoCache(limit: 4)
        var hit = await cache.value(for: "k")
        XCTAssertNil(hit, "no entry should read as a miss")

        await cache.set(nil, for: "k")
        hit = await cache.value(for: "k")
        XCTAssertNotNil(hit, "a remembered negative is an entry, not a miss")
        XCTAssertNil(hit ?? Lyrics(lines: []), "and it carries no lyrics")
    }

    func testMemoCacheEvictsOldestBeyondLimit() async {
        let cache = LyricsMemoCache(limit: 2)
        await cache.set(Lyrics(lines: [LyricLine(text: "a")]), for: "a")
        await cache.set(Lyrics(lines: [LyricLine(text: "b")]), for: "b")
        await cache.set(Lyrics(lines: [LyricLine(text: "c")]), for: "c")
        let evicted = await cache.value(for: "a")
        XCTAssertNil(evicted)
        let kept = await cache.value(for: "c")
        XCTAssertNotNil(kept)
    }

    func testDiskCacheRoundTripsAndAges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = LyricsDiskCache(directory: directory)
        let missing = await cache.cached("k")
        XCTAssertNil(missing)
        let missingAge = await cache.entryAge("k")
        XCTAssertNil(missingAge)

        await cache.store(Lyrics(lines: [LyricLine(text: "hello", start: 1)]), for: "k")
        let stored = await cache.cached("k")
        XCTAssertEqual((stored ?? nil)?.lines.first?.text, "hello")
        let storedAge = await cache.entryAge("k")
        XCTAssertLessThan(try XCTUnwrap(storedAge), 5)

        // A remembered negative must survive as an entry, not read back as a miss.
        await cache.store(nil, for: "none")
        let negative = await cache.cached("none")
        XCTAssertNotNil(negative)
        XCTAssertNil(negative ?? Lyrics(lines: []))
    }
}
