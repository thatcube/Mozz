import XCTest
@testable import MozzCore

final class LyricsTests: XCTestCase {

    // MARK: Plain text

    func testPlainTextSplitsLinesAndIsUnsynced() {
        let lyrics = Lyrics(plainText: "First line\nSecond line\r\nThird")
        XCTAssertEqual(lyrics.lines.map(\.text), ["First line", "Second line", "Third"])
        XCTAssertFalse(lyrics.isSynced)
    }

    func testWhitespaceOnlyLyricsAreEmpty() {
        XCTAssertTrue(Lyrics(plainText: "  \n\t\n ").isEmpty)
        XCTAssertFalse(Lyrics(plainText: "words").isEmpty)
    }

    // MARK: LRC parsing

    func testLRCParsesTimestampsIntoSeconds() throws {
        let lrc = """
        [ar:Some Artist]
        [ti:A Song]
        [00:00.00]Intro
        [00:12.50]First line
        [01:05.00]Second line
        [01:10]No centis
        """
        let lyrics = try XCTUnwrap(Lyrics(lrc: lrc))
        XCTAssertTrue(lyrics.isSynced)
        // ID tags are skipped, not rendered as lyric text.
        XCTAssertEqual(lyrics.lines.count, 4)
        XCTAssertEqual(try XCTUnwrap(lyrics.lines[0].start), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(lyrics.lines[1].start), 12.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(lyrics.lines[2].start), 65, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(lyrics.lines[3].start), 70, accuracy: 0.001)
    }

    func testLRCExpandsMultipleTimestampsOnOneLine() throws {
        let lyrics = try XCTUnwrap(Lyrics(lrc: "[00:10.00][00:47.00]Chorus"))
        XCTAssertEqual(lyrics.lines.map(\.text), ["Chorus", "Chorus"])
        XCTAssertEqual(try XCTUnwrap(lyrics.lines[0].start), 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(lyrics.lines[1].start), 47, accuracy: 0.001)
    }

    func testLRCSortsByTimestamp() throws {
        let lyrics = try XCTUnwrap(Lyrics(lrc: "[00:30.00]Later\n[00:05.00]Earlier"))
        XCTAssertEqual(lyrics.lines.map(\.text), ["Earlier", "Later"])
    }

    func testLRCParsesHoursTimestamp() throws {
        let lyrics = try XCTUnwrap(Lyrics(lrc: "[01:02:03.00]Deep cut"))
        XCTAssertEqual(try XCTUnwrap(lyrics.lines.first?.start), 3723, accuracy: 0.001)
    }

    func testLRCAcceptsCommaAsDecimalSeparator() throws {
        let lyrics = try XCTUnwrap(Lyrics(lrc: "[00:12,50]Comma"))
        XCTAssertEqual(try XCTUnwrap(lyrics.lines.first?.start), 12.5, accuracy: 0.001)
    }

    func testLRCWithoutTimestampsFallsBackToPlainText() throws {
        let lyrics = try XCTUnwrap(Lyrics(lrc: "Just\nplain\nwords"))
        XCTAssertFalse(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["Just", "plain", "words"])
    }

    /// Some `.lrc` sidecars carry a UTF-8 BOM. It isn't whitespace, so without
    /// stripping it the first line fails the `[` check and silently degrades into
    /// an untimed plain line.
    func testLRCWithLeadingBOMParsesFirstLine() throws {
        let lyrics = try XCTUnwrap(Lyrics(lrc: "\u{FEFF}[00:01.00]First\n[00:02.00]Second"))
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["First", "Second"])
        XCTAssertEqual(try XCTUnwrap(lyrics.lines[0].start), 1, accuracy: 0.001)
    }

    func testLRCReturnsNilForEmptyInput() {
        XCTAssertNil(Lyrics(lrc: "   \n  "))
    }

    // MARK: Plex payload routing

    /// Regression: a `.lrc` whose first line is a metadata tag still starts with
    /// `[`. Sniffing on `[` sent it to the JSON parser, which failed, and the
    /// lyrics vanished.
    func testPlexTextParsesLRCSidecarWithMetadataTag() throws {
        let lrc = "[ar:Some Artist]\n[00:01.00]First\n[00:02.00]Second"
        let lyrics = try XCTUnwrap(Lyrics(plexLyricsText: lrc))
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["First", "Second"])
    }

    func testPlexTextParsesTimedJSON() throws {
        let json = """
        [{"startOffset":1000,"endOffset":2000,"Span":[{"text":"Hello"}]},
         {"startOffset":2000,"endOffset":3000,"Span":[{"text":"World"}]}]
        """
        let lyrics = try XCTUnwrap(Lyrics(plexLyricsText: json))
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["Hello", "World"])
        XCTAssertEqual(try XCTUnwrap(lyrics.lines[0].start), 1, accuracy: 0.001)
    }

    func testPlexTimedJSONFindsLinesInsideWrapperObject() throws {
        let json = """
        {"Lyrics":{"Line":[{"startOffset":500,"Span":[{"text":"Wrapped"}]}]}}
        """
        let lyrics = try XCTUnwrap(Lyrics(plexLyricsText: json))
        XCTAssertEqual(lyrics.lines.map(\.text), ["Wrapped"])
        XCTAssertEqual(try XCTUnwrap(lyrics.lines[0].start), 0.5, accuracy: 0.001)
    }

    /// A `{`-prefixed body can only be JSON. If it doesn't parse it is malformed
    /// JSON, not lyrics — rendering the raw braces would be worse than nothing.
    func testPlexTextRejectsMalformedJSON() {
        XCTAssertNil(Lyrics(plexLyricsText: "{ not valid json"))
    }

    func testPlexTextFallsBackToPlainText() throws {
        let lyrics = try XCTUnwrap(Lyrics(plexLyricsText: "Just some words\nAcross lines"))
        XCTAssertFalse(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.count, 2)
    }

    // MARK: Active line

    func testActiveLineIndexTracksPlayback() {
        let lyrics = Lyrics(lines: [
            LyricLine(text: "one", start: 0),
            LyricLine(text: "two", start: 10),
            LyricLine(text: "three", start: 20),
        ])
        XCTAssertEqual(lyrics.activeLineIndex(at: 0), 0)
        XCTAssertEqual(lyrics.activeLineIndex(at: 9.9), 0)
        XCTAssertEqual(lyrics.activeLineIndex(at: 10), 1)
        XCTAssertEqual(lyrics.activeLineIndex(at: 999), 2)
    }

    /// Before the first timestamp there is no active line, so the panel can centre
    /// on the *upcoming* one rather than highlighting something not yet sung.
    func testActiveLineIndexIsNilBeforeFirstTimestamp() {
        let lyrics = Lyrics(lines: [LyricLine(text: "late", start: 30)])
        XCTAssertNil(lyrics.activeLineIndex(at: 5))
    }

    func testActiveLineIndexAppliesLead() {
        let lyrics = Lyrics(lines: [
            LyricLine(text: "one", start: 0),
            LyricLine(text: "two", start: 10),
        ])
        // 0.3s of anticipation pulls the next line in just before it is sung.
        XCTAssertEqual(lyrics.activeLineIndex(at: 9.8, lead: 0.3), 1)
        XCTAssertEqual(lyrics.activeLineIndex(at: 9.8, lead: 0), 0)
    }

    func testActiveLineIndexIsNilForUnsyncedLyrics() {
        XCTAssertNil(Lyrics(plainText: "a\nb").activeLineIndex(at: 42))
    }

    // MARK: Instrumental heuristic

    func testExplicitInstrumentalTitlesAreDetected() {
        XCTAssertTrue(isExplicitlyInstrumental(title: "Theme (Instrumental)"))
        XCTAssertTrue(isExplicitlyInstrumental(title: "Song [Karaoke]"))
        XCTAssertTrue(isExplicitlyInstrumental(title: "Anthem - Backing Track"))
        XCTAssertTrue(isExplicitlyInstrumental(title: "Piece (Instrumental Version)"))
    }

    /// Deliberately narrow: a song that merely *mentions* the word still has words.
    func testSongsMentioningInstrumentalWordsAreNotFlagged() {
        XCTAssertFalse(isExplicitlyInstrumental(title: "Karaoke"))
        XCTAssertFalse(isExplicitlyInstrumental(title: "Instrumental Break Dancing"))
        XCTAssertFalse(isExplicitlyInstrumental(title: "Palladio"))
    }
}
