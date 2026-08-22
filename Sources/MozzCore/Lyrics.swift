import Foundation

// MARK: - Lyrics
//
// A backend-agnostic representation of a track's lyrics, so the player never has
// to know whether the words arrived as Jellyfin's tick-stamped JSON, an
// OpenSubsonic structured line list, a Plex `.lrc` sidecar, or an LRCLIB record.
//
// `start == nil` on every line means "unsynced" (plain text); any line carrying a
// timestamp marks the whole set as synced, which is what enables the karaoke-style
// highlight-and-scroll in the player.

/// A single line of a song's lyrics, optionally timestamped.
public struct LyricLine: Codable, Hashable, Sendable {
    /// The text of the line. May be empty for an intentional blank/spacer line.
    public var text: String
    /// When this line begins, in seconds from the start of the track. `nil` for
    /// unsynced (plain-text) lyrics.
    public var start: TimeInterval?

    public init(text: String, start: TimeInterval? = nil) {
        self.text = text
        self.start = start
    }
}

/// Where a track's lyrics came from. The user's own server is always preferred;
/// `lrclib` is the keyless public fallback consulted when the server has none.
public enum LyricsSource: String, Codable, Hashable, Sendable {
    case jellyfin
    case plex
    case subsonic
    case lrclib

    /// Human-facing name, shown as a small attribution in the lyrics panel.
    public var displayName: String {
        switch self {
        case .jellyfin: return "Jellyfin"
        case .plex: return "Plex"
        case .subsonic: return "Subsonic"
        case .lrclib: return "LRCLIB"
        }
    }
}

/// A track's lyrics: an ordered list of lines, synced or plain.
public struct Lyrics: Codable, Hashable, Sendable {
    public var lines: [LyricLine]
    /// Where these lyrics were sourced from, for the attribution label. `nil`
    /// when unknown.
    public var source: LyricsSource?

    public init(lines: [LyricLine], source: LyricsSource? = nil) {
        self.lines = lines
        self.source = source
    }

    /// Whether any line carries a timestamp (karaoke-capable).
    public var isSynced: Bool { lines.contains { $0.start != nil } }

    /// Whether there is no meaningful content to show.
    public var isEmpty: Bool {
        lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Returns a copy stamped with `source`.
    public func taggingSource(_ source: LyricsSource) -> Lyrics {
        var copy = self
        copy.source = source
        return copy
    }

    /// The index of the line being sung at `time`, for synced lyrics.
    ///
    /// `lead` nudges the highlight slightly early so a line lights up *as* it is
    /// sung rather than a beat after — it absorbs the residual latency between the
    /// player's position sampling and the screen. Returns `nil` before the first
    /// timestamp, and for unsynced lyrics (there is nothing to track).
    ///
    /// Lines are stored in ascending time order by every parser here, so this
    /// walks forward and keeps the last line that has already started.
    public func activeLineIndex(at time: TimeInterval, lead: TimeInterval = 0) -> Int? {
        guard isSynced else { return nil }
        let cue = time + lead
        var match: Int?
        for (index, line) in lines.enumerated() {
            guard let start = line.start else { continue }
            if start <= cue { match = index } else { break }
        }
        return match
    }

    /// Convenience: plain-text lyrics from a single string, split on newlines.
    public init(plainText: String) {
        let lines = plainText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { LyricLine(text: $0.trimmingCharacters(in: .whitespaces)) }
        self.init(lines: lines)
    }

    /// Parses a Plex lyrics payload, which arrives either as Plex's own timed-JSON
    /// or as an `.lrc`/plain-text sidecar.
    ///
    /// It deliberately does **not** treat a leading `[` as "this is JSON": *every*
    /// valid `.lrc` file also begins with `[` — a timestamp (`[00:12.50]`) or a
    /// metadata tag (`[ar:…]`) — so sniffing on `[` sends real LRC sidecars to the
    /// JSON parser, which fails, and the lyrics vanish silently. Routing:
    ///
    /// - A `{`-prefixed body is object-shaped, so it can only be Plex timed-JSON
    ///   (possibly an `{"Lyrics":…}` wrapper). If it doesn't parse it is malformed
    ///   JSON rather than lyrics, so return `nil` instead of letting the lenient
    ///   LRC/plain parsers echo raw braces onto the screen.
    /// - Anything else — including a `[`-prefixed body, which may be a timed-JSON
    ///   *array* or (far more often) an `.lrc` sidecar — tries timed-JSON, then LRC,
    ///   then plain text, taking the first that yields lines.
    public init?(plexLyricsText text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: Lyrics?
        if trimmed.hasPrefix("{") {
            parsed = Lyrics(plexTimedJSON: text)
        } else {
            parsed = Lyrics(plexTimedJSON: text) ?? Lyrics(lrc: text) ?? Lyrics(plainText: text)
        }
        guard let parsed, !parsed.isEmpty else { return nil }
        self = parsed
    }

    /// Parses Plex's timed-lyrics JSON (returned by a `streamType == 4` lyric stream
    /// when the words came from Plex's own provider rather than an `.lrc` sidecar).
    /// The payload is an array of line objects — possibly wrapped in a container
    /// object — each shaped like:
    ///
    /// ```json
    /// {"startOffset":18990,"endOffset":21200,
    ///  "Span":[{"text":"I said to you","startOffset":18990,"endOffset":21200}]}
    /// ```
    ///
    /// Offsets are milliseconds. Returns `nil` when the input isn't this format or
    /// carries no usable lines, so callers can fall back to LRC/plain text.
    public init?(plexTimedJSON json: String) {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let rawLines = Self.findLyricLineArray(in: root),
              !rawLines.isEmpty else {
            return nil
        }

        var parsed: [LyricLine] = []
        var sawTimestamp = false
        for object in rawLines {
            let text = Self.plexLineText(from: object)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            var start: TimeInterval?
            if let milliseconds = Self.number(object["startOffset"]) {
                start = milliseconds / 1000
                sawTimestamp = true
            }
            parsed.append(LyricLine(text: text, start: start))
        }

        guard !parsed.isEmpty else { return nil }
        if sawTimestamp { parsed.sort { ($0.start ?? 0) < ($1.start ?? 0) } }
        self.init(lines: parsed)
    }

    /// Recursively locates the array of line objects inside a parsed Plex payload,
    /// tolerating an outer wrapper object (e.g. `{"Lyrics":{"Line":[…]}}`) as well
    /// as a bare top-level array.
    private static func findLyricLineArray(in node: Any) -> [[String: Any]]? {
        if let array = node as? [[String: Any]],
           array.contains(where: { $0["Span"] != nil || ($0["startOffset"] != nil && $0["text"] != nil) }) {
            return array
        }
        if let dict = node as? [String: Any] {
            for value in dict.values {
                if let found = findLyricLineArray(in: value) { return found }
            }
        }
        if let array = node as? [Any] {
            for value in array {
                if let found = findLyricLineArray(in: value) { return found }
            }
        }
        return nil
    }

    /// Joins the text of a Plex line: each `Span`'s `text`, or the line's own
    /// `text` when there are no spans.
    private static func plexLineText(from object: [String: Any]) -> String {
        if let spans = object["Span"] as? [[String: Any]] {
            return spans.compactMap { $0["text"] as? String }.joined()
        }
        return (object["text"] as? String) ?? ""
    }

    /// Reads a JSON number (NSNumber/Int/Double/String) as a `Double`.
    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: return double
        case let int as Int: return Double(int)
        case let string as String: return Double(string)
        default: return nil
        }
    }

    /// Parses an LRC file into timestamped lines, falling back to plain text when
    /// the input carries no `[mm:ss.xx]` timestamps. Returns `nil` when there is
    /// nothing usable.
    ///
    /// Supports multiple timestamps on one line (`[00:12.00][00:47.00]Chorus`) and
    /// ignores ID-tag lines like `[ar:Artist]` / `[ti:Title]`.
    public init?(lrc: String) {
        // Strip a leading UTF-8/UTF-16 BOM (U+FEFF) that some `.lrc` sidecars carry
        // — it isn't whitespace, so without this the first line fails the `[`
        // timestamp check and degrades into an untimed plain line.
        let trimmed = lrc
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var parsed: [LyricLine] = []
        var sawTimestamp = false

        for raw in trimmed
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let (stamps, text) = Self.parseLRCLine(line)
            if stamps.isEmpty {
                // A non-timestamped, non-tag line — keep as plain text.
                if !Self.isMetadataTag(line) { parsed.append(LyricLine(text: line)) }
            } else {
                sawTimestamp = true
                for stamp in stamps { parsed.append(LyricLine(text: text, start: stamp)) }
            }
        }

        guard !parsed.isEmpty else { return nil }
        if sawTimestamp { parsed.sort { ($0.start ?? 0) < ($1.start ?? 0) } }
        self.init(lines: parsed)
    }

    /// Returns the timestamps found at the head of an LRC line plus the remaining
    /// text. `[01:02.50][01:30]Hello` → `([62.5, 90], "Hello")`.
    private static func parseLRCLine(_ line: String) -> (stamps: [TimeInterval], text: String) {
        var stamps: [TimeInterval] = []
        var rest = Substring(line)
        while rest.first == "[" {
            guard let close = rest.firstIndex(of: "]") else { break }
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            if let seconds = parseLRCTimestamp(String(inner)) {
                stamps.append(seconds)
            } else {
                // A `[tag:value]` rather than a timestamp — stop scanning.
                break
            }
            rest = rest[rest.index(after: close)...]
        }
        return (stamps, String(rest).trimmingCharacters(in: .whitespaces))
    }

    /// Parses `mm:ss`, `mm:ss.xx`, or `hh:mm:ss.xx` into seconds. Returns `nil` for
    /// non-timestamp brackets (e.g. `ar:Artist`).
    private static func parseLRCTimestamp(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let normalized = parts.map { $0.replacingOccurrences(of: ",", with: ".") }
        guard normalized.allSatisfy({ Double($0) != nil }) else { return nil }
        let values = normalized.map { Double($0) ?? 0 }
        switch values.count {
        case 2: return values[0] * 60 + values[1]
        case 3: return values[0] * 3600 + values[1] * 60 + values[2]
        default: return nil
        }
    }

    /// Whether a bracketed line is an LRC ID tag (`[ar:...]`, `[ti:...]`) rather
    /// than lyric content.
    private static func isMetadataTag(_ line: String) -> Bool {
        guard line.first == "[", line.last == "]" else { return false }
        let inner = line.dropFirst().dropLast()
        guard let colon = inner.firstIndex(of: ":") else { return false }
        let key = inner[inner.startIndex..<colon]
        return !key.isEmpty && key.allSatisfy { $0.isLetter }
    }
}

/// Whether a track title carries an explicit marker that it has no sung lyrics —
/// `(Instrumental)`, `[Karaoke]`, `Backing Track`, and friends. These effectively
/// never have lyrics anywhere, so the resolver can answer "none" without a network
/// round-trip.
///
/// Deliberately narrow so it can't false-positive on songs that merely *mention*
/// these words (Drake's "Karaoke" has lyrics). Untitled instrumentals — a classical
/// piece named "Palladio" — aren't caught here; those rely on the disk cache
/// remembering the negative instead.
public func isExplicitlyInstrumental(title: String) -> Bool {
    let pattern = "(?i)[\\(\\[\\-–—]\\s*(instrumental|karaoke|backing\\s+track|score\\s+version|instrumental\\s+version|karaoke\\s+version)\\s*[\\)\\]]?\\s*$"
    return title.range(of: pattern, options: .regularExpression) != nil
}
