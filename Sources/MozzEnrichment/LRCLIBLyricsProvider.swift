import Foundation
import MozzCore
import MozzNetworking
#if canImport(FoundationNetworking)
// Off Apple, URLSession and its configuration live in a separate module. Without
// this import `URLSessionConfiguration` resolves to a bare `AnyObject` and every
// member access fails with a message that names neither the module nor the
// platform.
import FoundationNetworking
#endif

/// Keyless public fallback for song lyrics, backed by lrclib.net.
///
/// Consulted alongside the user's own server and used when that server has no
/// lyrics for the track. Like the rest of the enrichment layer it is best-effort:
/// every failure (network, 404, decode, instrumental) collapses to `nil` so the
/// player simply shows its empty state. No API key is required.
///
/// Every outbound call passes through one shared ``TokenBucketLimiter`` so the
/// visible lookup, the next-track prefetch and the bulk queue sweep together stay
/// polite on a keyless public endpoint.
public struct LRCLIBLyricsProvider: Sendable {
    /// The outcome of a lookup. `reachable` reports whether *any* sub-request
    /// actually got an answer out of lrclib.net (a decoded 2xx or a definitive
    /// 404). The resolver uses it to avoid burning a permanent "no lyrics" into
    /// the cache when the device is simply offline or LRCLIB throttled us — a
    /// missing answer then is transport noise, not a verdict.
    public struct Result: Sendable {
        public var lyrics: Lyrics?
        public var reachable: Bool

        public init(lyrics: Lyrics?, reachable: Bool) {
            self.lyrics = lyrics
            self.reachable = reachable
        }
    }

    /// Shared app-wide limiter. `burst` lets a single visible lookup's fan-out go
    /// out immediately; sustained background traffic throttles toward the rate.
    public static let sharedLimiter = TokenBucketLimiter(requestsPerSecond: 2, burst: 8)

    /// How close (seconds) a candidate record's own duration must be to the
    /// playing track's for it to be treated as *the same recording*.
    ///
    /// Many songs exist on LRCLIB as several same-title versions of very different
    /// length — a radio edit, the album cut, a 12" extended mix, a live take — and
    /// a version's synced timestamps only line up with audio of matching length. A
    /// couple of seconds absorbs encoding/gapless differences between the same
    /// master without bleeding into a different cut.
    public static let durationMatchTolerance: TimeInterval = 2.5

    /// Upper bound on how far a *held* synced version's length may differ from the
    /// playing track before the artist-qualified path rejects it rather than show
    /// drifting lyrics. A touch more lenient than ``durationMatchTolerance``
    /// because the artist already matched — the risk here is a wrong *mix*, not a
    /// wrong *song* — but still tight enough to reject radio-edit-vs-extended-mix
    /// mismatches, whose timestamps visibly drift as the track plays.
    public static let durationVersionCeiling: TimeInterval = 6

    /// Without an artist to match on, duration is the only guard against unrelated
    /// songs that merely share a title, so the title-only path is stricter.
    public static let titleOnlyDurationTolerance: TimeInterval = 3

    private let client: HTTPClient
    private let limiter: TokenBucketLimiter

    /// One session for the whole app.
    ///
    /// Shared because the provider is constructed more often than it looks —
    /// SwiftUI re-initialises the views that own it on every parent update — and a
    /// fresh `URLSession` each time is pure waste. It also declines
    /// **constrained** networks: Low Data Mode is the user asking not to spend
    /// data on things they didn't ask for, and lyrics are exactly that. Requests
    /// then fail instantly and locally rather than going out at all.
    public static let sharedTransport: any HTTPTransport = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.allowsConstrainedNetworkAccess = false
        config.httpAdditionalHeaders = ["Accept-Encoding": "gzip, deflate"]
        return URLSessionTransport(session: URLSession(configuration: config))
    }()

    public init(
        transport: any HTTPTransport = LRCLIBLyricsProvider.sharedTransport,
        limiter: TokenBucketLimiter = LRCLIBLyricsProvider.sharedLimiter,
        baseURL: URL = URL(string: "https://lrclib.net/api")!
    ) {
        self.limiter = limiter
        self.client = HTTPClient(
            baseURL: baseURL,
            transport: transport,
            defaultHeaders: [
                "Accept": "application/json",
                // A polite, attributable User-Agent, as LRCLIB asks for.
                "User-Agent": "Mozz (+https://github.com/thatcube/Mozz)",
            ],
            // Best-effort metadata: a retry only adds latency to a panel the user
            // is staring at, and the resolver already treats a transient failure
            // as "ask again next play".
            retryPolicy: .none
        )
    }

    // MARK: Lookup

    /// Looks up lyrics for a track, **preferring a synced version**.
    ///
    /// Tries the title as-is and a cleaned variant (parentheticals and `feat.`
    /// segments stripped), since LRCLIB uploads are usually filed under the plain
    /// song title. Each candidate is tried against both `/get` and `/search`
    /// concurrently, and — when the duration is known — the *right version* is
    /// chosen among same-title results of differing length rather than whichever
    /// request happens to return first.
    ///
    /// - Parameter allowTitleOnlyFallback: whether the last-resort title-only
    ///   query may run. `false` for background prefetch: those extra round-trips
    ///   aren't worth the shared-limiter contention when warming a queue, and the
    ///   track still gets the full treatment the moment it becomes visible.
    public func lyrics(
        title: String,
        artist: String,
        duration: TimeInterval?,
        allowTitleOnlyFallback: Bool = true
    ) async -> Result {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty else { return Result(lyrics: nil, reachable: false) }
        let candidates = titleCandidates(from: title)
        guard !candidates.isEmpty else { return Result(lyrics: nil, reachable: false) }

        // Treat a zero/absent duration as "unknown" so we never duration-match
        // against it.
        let knownDuration: TimeInterval? = (duration ?? 0) > 0 ? duration : nil
        let artistQualified = await artistQualifiedLookup(
            candidates: candidates, artist: trimmedArtist, knownDuration: knownDuration
        )

        // A synced hit from the artist-qualified pass wins outright.
        if let lyrics = artistQualified.lyrics, lyrics.isSynced {
            return Result(lyrics: lyrics, reachable: true)
        }

        // Fallback: some catalogues file a track under a *different* artist name
        // than the player shows — a collaboration credited to the duo's name, a
        // soundtrack under "Various Artists", classical filed by composer rather
        // than performer. When the artist-qualified search finds nothing, retry by
        // title alone and accept a record solely on a tight duration match. Gated
        // on a known duration and run only on the miss path, so it can never
        // override an artist match.
        var bestPlain = artistQualified.lyrics
        var reachable = artistQualified.reachable
        if allowTitleOnlyFallback, artistQualified.lyrics == nil, let knownDuration {
            for candidate in candidates {
                let probe = await searchByTitleOnly(title: candidate, duration: knownDuration)
                if probe.reachable { reachable = true }
                guard let lyrics = probe.record?.lyrics() else { continue }
                if lyrics.isSynced { return Result(lyrics: lyrics, reachable: true) }
                if bestPlain == nil { bestPlain = lyrics }
            }
        }
        return Result(lyrics: bestPlain, reachable: reachable)
    }

    /// Fans every (candidate title × {`/get`, `/search`}) probe out concurrently
    /// and resolves the best record among the answers.
    private func artistQualifiedLookup(
        candidates: [String],
        artist: String,
        knownDuration: TimeInterval?
    ) async -> Result {
        struct Probe: Sendable {
            let record: LRCLIBRecord?
            let reachable: Bool
        }

        return await withTaskGroup(of: Probe.self) { group in
            for candidate in candidates {
                group.addTask {
                    let probe = await self.exactMatch(
                        title: candidate, artist: artist, duration: knownDuration
                    )
                    return Probe(record: probe.record, reachable: probe.reachable)
                }
                group.addTask {
                    let probe = await self.search(
                        title: candidate, artist: artist, duration: knownDuration
                    )
                    return Probe(record: probe.record, reachable: probe.reachable)
                }
            }

            var plainFallback: Lyrics?
            var syncedRecords: [LRCLIBRecord] = []
            var anyReachable = false
            for await probe in group {
                if probe.reachable { anyReachable = true }
                guard let record = probe.record, let lyrics = record.lyrics() else { continue }
                guard lyrics.isSynced else {
                    if plainFallback == nil { plainFallback = lyrics }
                    continue
                }
                guard let knownDuration else {
                    // Nothing to disambiguate versions with — first synced wins.
                    group.cancelAll()
                    return Result(lyrics: lyrics, reachable: true)
                }
                // A synced record within a couple of seconds is certainly the same
                // recording: take it now and cancel the rest, so the common
                // single-version case stays fast.
                if let recordDuration = record.duration,
                   abs(recordDuration - knownDuration) <= Self.durationMatchTolerance {
                    group.cancelAll()
                    return Result(lyrics: lyrics, reachable: true)
                }
                // Otherwise hold it: another probe may yet return a closer-length
                // version, and we pick the nearest below.
                syncedRecords.append(record)
            }

            // No tight match arrived. Among the held synced versions prefer the
            // closest length — but only accept it inside a sane ceiling. Every held
            // record is by definition further off than the match tolerance; if the
            // closest is *wildly* off (a radio edit against a 12" mix) its
            // timestamps drift the panel progressively out of sync as the song
            // plays, which is worse than showing nothing.
            let nearEnough: [LRCLIBRecord]
            if let knownDuration {
                nearEnough = syncedRecords.filter {
                    Self.versionDurationAcceptable(
                        recordDuration: $0.duration, trackDuration: knownDuration
                    )
                }
            } else {
                nearEnough = syncedRecords
            }
            if let best = Self.bestMatch(in: nearEnough, duration: knownDuration),
               let lyrics = best.lyrics() {
                return Result(lyrics: lyrics, reachable: true)
            }
            return Result(lyrics: plainFallback, reachable: anyReachable)
        }
    }

    // MARK: Endpoints

    /// Exact-ish lookup via `/get`, matched on **title + artist + duration** only.
    ///
    /// `album_name` is deliberately omitted: `/get` requires every supplied field
    /// to match, and a player's album (a compilation, a "Remastered 20xx" reissue,
    /// a soundtrack) frequently differs from how LRCLIB filed the track, which
    /// turned otherwise-findable songs into 404s. Duration is the stronger,
    /// version-aware signal anyway — `/get` returns the closest-length record for
    /// the title+artist, which is exactly the right recording when several
    /// versions share a title.
    private func exactMatch(
        title: String,
        artist: String,
        duration: TimeInterval?
    ) async -> (record: LRCLIBRecord?, reachable: Bool) {
        var query = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if let duration, duration > 0 {
            query.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        await limiter.acquire()
        let probe = await fetch(LRCLIBRecord.self, path: "get", query: query)
        return (probe.value, probe.reachable)
    }

    private func search(
        title: String,
        artist: String,
        duration: TimeInterval?
    ) async -> (record: LRCLIBRecord?, reachable: Bool) {
        let query = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        await limiter.acquire()
        let probe = await fetch([LRCLIBRecord].self, path: "search", query: query)
        guard let records = probe.value, !records.isEmpty else { return (nil, probe.reachable) }
        return (Self.bestMatch(in: records, duration: duration), probe.reachable)
    }

    /// Last-resort lookup used only when the artist-qualified search finds
    /// nothing: query by title alone and accept a record only when its duration is
    /// within a tight window of the playing track.
    private func searchByTitleOnly(
        title: String,
        duration: TimeInterval
    ) async -> (record: LRCLIBRecord?, reachable: Bool) {
        await limiter.acquire()
        let probe = await fetch(
            [LRCLIBRecord].self,
            path: "search",
            query: [URLQueryItem(name: "track_name", value: title)]
        )
        guard let records = probe.value, !records.isEmpty else { return (nil, probe.reachable) }
        let inWindow = records.filter { record in
            guard let recordDuration = record.duration else { return false }
            return abs(recordDuration - duration) <= Self.titleOnlyDurationTolerance
        }
        return (Self.bestMatch(in: inWindow, duration: duration), probe.reachable)
    }

    /// GET + decode, never throwing, classifying the failure into a `reachable`
    /// flag. See ``reachability(for:)`` for which statuses count as an answer.
    private func fetch<T: Decodable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem]
    ) async -> (value: T?, reachable: Bool) {
        do {
            let value = try await client.send(Endpoint(path: path, query: query), as: T.self)
            return (value, true)
        } catch let error as MozzError {
            return (nil, Self.reachability(for: error))
        } catch {
            return (nil, false)
        }
    }

    /// Whether a failed lookup still constitutes an *authoritative* answer the
    /// lyrics layer may trust as a real negative.
    ///
    /// Only a definitive `404` qualifies: it means the record genuinely isn't
    /// there. Everything else — `429` (which our own prefetch fan-out provokes),
    /// any `5xx` (LRCLIB/Cloudflare 500/502/503/520/522…), timeouts, and other
    /// `4xx` such as the `400` LRCLIB returns for a track longer than its `/get`
    /// duration cap — is transient or a non-verdict, so the resolver retries on a
    /// later play instead of poisoning the cache with a permanent miss.
    static func reachability(for error: MozzError) -> Bool {
        error == .notFound
    }

    // MARK: Matching

    /// The ordered, de-duplicated title queries to try: the original first, then a
    /// cleaned variant with parentheticals / `feat.` segments removed.
    private func titleCandidates(from rawTitle: String) -> [String] {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var candidates = [trimmed]
        let cleaned = Self.cleanedTitle(trimmed)
        if !cleaned.isEmpty, cleaned.caseInsensitiveCompare(trimmed) != .orderedSame {
            candidates.append(cleaned)
        }
        return candidates
    }

    /// Strips `(...)` / `[...]` groups and `feat.`/`ft.` segments so a verbose
    /// store title collapses to the core song name.
    ///
    /// The `\b` word boundary before `feat`/`ft` is load-bearing: without it the
    /// pattern matches *inside* ordinary words that merely end in those letters
    /// ("Soft Rock" → "So", "Lift Me Up" → "Li", "Defeat the Villain" → "De"),
    /// spawning a garbage second query that wastes rate-limited requests and can
    /// even match a different song by the same artist.
    static func cleanedTitle(_ title: String) -> String {
        var result = title
        result = result.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?i)\\s*[-–—]?\\s*\\bfeat\\.?\\s.*$", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?i)\\s*[-–—]?\\s*\\bft\\.?\\s.*$", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a held synced version of length `recordDuration` is close enough to
    /// the playing track to display without visibly drifting. A record with no
    /// duration of its own can't be safely matched, so it fails.
    static func versionDurationAcceptable(
        recordDuration: TimeInterval?,
        trackDuration: TimeInterval,
        ceiling: TimeInterval = durationVersionCeiling
    ) -> Bool {
        guard let recordDuration else { return false }
        return abs(recordDuration - trackDuration) <= ceiling
    }

    /// Picks the best record: prefer ones with **synced** lyrics, then — when a
    /// duration is known — the one whose own duration is closest.
    static func bestMatch(in records: [LRCLIBRecord], duration: TimeInterval?) -> LRCLIBRecord? {
        let usable = records.filter { $0.lyrics() != nil }
        guard !usable.isEmpty else { return nil }
        let synced = usable.filter { $0.hasSyncedLyrics }
        let pool = synced.isEmpty ? usable : synced
        guard let duration, duration > 0 else { return pool.first }
        return pool.min { lhs, rhs in
            abs((lhs.duration ?? .greatestFiniteMagnitude) - duration)
                < abs((rhs.duration ?? .greatestFiniteMagnitude) - duration)
        }
    }
}

/// A lrclib.net record. `/get` returns one; `/search` an array.
struct LRCLIBRecord: Decodable, Sendable {
    let duration: TimeInterval?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    /// Whether this record carries usable synced (timestamped) lyrics.
    var hasSyncedLyrics: Bool {
        guard let synced = syncedLyrics, let parsed = Lyrics(lrc: synced) else { return false }
        return parsed.isSynced && !parsed.isEmpty
    }

    /// Converts the record into a tagged ``Lyrics``, preferring synced over plain
    /// and returning `nil` for instrumentals or empty payloads.
    func lyrics() -> Lyrics? {
        if instrumental == true { return nil }
        if let synced = syncedLyrics, let parsed = Lyrics(lrc: synced), !parsed.isEmpty {
            return parsed.taggingSource(.lrclib)
        }
        if let plain = plainLyrics {
            let parsed = Lyrics(plainText: plain)
            if !parsed.isEmpty { return parsed.taggingSource(.lrclib) }
        }
        return nil
    }
}
