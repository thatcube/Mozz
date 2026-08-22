import Foundation
import MozzCore
import MozzNetworking

/// Why lyrics are being resolved, which tunes how hard the LRCLIB fallback tries.
public enum LyricsResolveContext: Sendable {
    /// The track the user is looking at right now — full effort.
    case visible
    /// Warming the cache for a track further down the queue. Skips the expensive
    /// title-only fallback so the shared rate limiter stays clear for the visible
    /// track; the full fallback still runs the moment that track becomes visible.
    case prefetch
}

/// The outcome of a lyrics resolution.
public struct LyricsResolution: Sendable, Equatable {
    public var lyrics: Lyrics?
    /// When `lyrics` is `nil`, whether the UI should stay *silent* rather than say
    /// "No lyrics found".
    ///
    /// True for a negative we can't fully trust — the device was offline, LRCLIB
    /// was throttled, or a needed source was never asked. Showing a definitive
    /// "no lyrics" then would be a lie, so the panel stays quiet and we re-check
    /// later.
    public var staySilent: Bool

    public init(lyrics: Lyrics?, staySilent: Bool = false) {
        self.lyrics = lyrics
        self.staySilent = staySilent
    }
}

/// Pure decision for whether a *negative* resolve may be trusted — i.e. cached,
/// and allowed to surface a definitive "No lyrics found".
///
/// Extracted as a dependency-free function because this matrix is the single
/// easiest thing to get wrong in the whole feature: one mistake burns a permanent
/// "no lyrics" onto disk for songs that actually have them, and the user has no
/// way to clear it.
///
/// A negative is authoritative only when every source we needed actually answered
/// **and** we used full effort:
///   - the server must have been reachable (it is always consulted);
///   - LRCLIB must not have been skipped merely because the track arrived without
///     an artist — we never asked our best source, so the verdict is incomplete;
///   - LRCLIB must not have been skipped because the user has lyrics turned OFF:
///     that skip is a temporary setting, not a verdict, and baking it in would
///     mean flipping lyrics back on kept reading a poisoned negative;
///   - if LRCLIB was consulted it must have been reachable (not throttled,
///     offline, or cancelled mid-skip);
///   - and if LRCLIB ran with its title-only fallback disabled (a background
///     prefetch) while a usable duration was available, the resolve was
///     reduced-effort: the fallback that finds tracks filed under a *different*
///     artist never ran. Trusting that would both cache "no lyrics" and reset the
///     refresh clock, suppressing the visible play's full fallback for a week on
///     every queue-advanced track.
public enum LyricsNegativeAuthority {
    public static func isAuthoritative(
        serverReachable: Bool,
        lrclibSkippedForMissingArtist: Bool,
        lrclibSkippedForDisabled: Bool,
        lrclibConsulted: Bool,
        lrclibReachable: Bool,
        allowedTitleOnlyFallback: Bool,
        hasUsableDuration: Bool
    ) -> Bool {
        guard serverReachable else { return false }
        if lrclibSkippedForMissingArtist { return false }
        if lrclibSkippedForDisabled { return false }
        if lrclibConsulted && !lrclibReachable { return false }
        if lrclibConsulted && !allowedTitleOnlyFallback && hasUsableDuration { return false }
        return true
    }
}

/// Resolves a track's lyrics from the user's own server and — when the server has
/// none — the keyless LRCLIB fallback, with three layers of caching in front so a
/// repeat play is effectively instant:
///
///  1. ``LyricsMemoCache`` (in-memory, this session) — covers track↔track
///     hand-offs and the next-track prefetch.
///  2. ``LyricsDiskCache`` (persistent) — covers replaying anything ever played,
///     including remembering that an instrumental has no lyrics so we don't search
///     for it again. A debounced background re-check still catches a later upload.
///  3. ``isExplicitlyInstrumental(title:)`` — short-circuits titles that say
///     they're instrumental/karaoke without touching the network at all.
public struct LyricsService: Sendable {
    /// How long a *still-empty* re-check suppresses the next one. Long enough that
    /// an instrumental on heavy rotation costs effectively zero traffic, short
    /// enough that a newly-uploaded LRCLIB record surfaces within a week.
    public static let refreshDebounce: TimeInterval = 60 * 60 * 24 * 7

    /// Once LRCLIB holds a synced copy, the longest we wait for a still-pending
    /// server before showing what we have. The server's result carries the user's
    /// own library attribution so it wins ties, but the visible panel must never
    /// block on a slow server beyond this.
    public static let serverHeadStart: TimeInterval = 0.3

    /// Backs off the online lookup when the network is genuinely bad, so a dead
    /// spot costs one failed attempt rather than a burst of them per song. Shared
    /// app-wide because the service is constructed per player.
    public static let lrclibBackoff = NetworkBackoff()
    /// The same for the user's own server. Matters most when playing downloaded
    /// tracks somewhere the server can't be reached at all — audio is coming off
    /// disk, and there's no reason to ask an unreachable server for words on every
    /// single track.
    public static let serverBackoff = NetworkBackoff()

    private let lrclib: LRCLIBLyricsProvider
    private let memo: LyricsMemoCache
    private let disk: LyricsDiskCache
    private let offline: LyricsDiskCache
    private let lrclibBackoff: NetworkBackoff
    private let serverBackoff: NetworkBackoff

    public init(
        lrclib: LRCLIBLyricsProvider = LRCLIBLyricsProvider(),
        memo: LyricsMemoCache = .shared,
        disk: LyricsDiskCache = .shared,
        offline: LyricsDiskCache = .offline,
        lrclibBackoff: NetworkBackoff = LyricsService.lrclibBackoff,
        serverBackoff: NetworkBackoff = LyricsService.serverBackoff
    ) {
        self.lrclib = lrclib
        self.memo = memo
        self.disk = disk
        self.offline = offline
        self.lrclibBackoff = lrclibBackoff
        self.serverBackoff = serverBackoff
    }

    /// Resolves and durably stores a track's lyrics because the user downloaded
    /// it for offline listening.
    ///
    /// Saved to the offline store rather than the ordinary cache: that one lives
    /// in Caches and the OS may reclaim it at any point, which would quietly
    /// break the one situation downloading exists for. Only a real result is kept
    /// — a track we couldn't reach a source for is left alone so it can be picked
    /// up next time rather than remembered as having none.
    @discardableResult
    public func captureForOffline(
        track: Track,
        backend: (any MusicBackend)?,
        useLRCLIB: Bool
    ) async -> Lyrics? {
        let key = LyricsCacheKey.make(
            trackID: track.id, connectionID: backend?.connection.id
        )
        // Already saved for offline — downloading an album twice costs nothing.
        if let existing = await offline.cached(key) { return existing }
        // A track whose own title says it is instrumental needs no network.
        if isExplicitlyInstrumental(title: track.title) {
            await offline.store(nil, for: key)
            return nil
        }
        // Reuse whatever the ordinary cache already knows before going out.
        if let cached = await disk.cached(key), let lyrics = cached {
            await offline.store(lyrics, for: key)
            return lyrics
        }
        // A download is a deliberate request to have this track work offline, so
        // it earns the full lookup and ignores the bad-network backoff.
        let outcome = await lookUp(
            track: track,
            backend: backend,
            useLRCLIB: useLRCLIB,
            allowTitleOnlyFallback: true,
            ignoresBackoff: true
        )
        guard outcome.lyrics != nil || outcome.isAuthoritative else { return nil }
        await offline.store(outcome.lyrics, for: key)
        await memo.set(outcome.lyrics, for: key)
        return outcome.lyrics
    }

    // MARK: Resolution

    /// Resolves lyrics for `track`, consulting the caches first.
    ///
    /// - Parameters:
    ///   - backend: the backend that owns the track. Its `fetchLyrics` must throw
    ///     for transport failures and return `nil` only for an authoritative
    ///     "none" — the negative-authority rules depend on that distinction.
    ///   - useLRCLIB: the user's "look up lyrics online" preference.
    ///   - userInitiated: the user explicitly asked for lyrics right now (opened
    ///     the panel, turned the setting on). Such a request ignores the bad-network
    ///     backoff entirely — a deliberate tap should always try, however poor the
    ///     signal.
    public func resolve(
        track: Track,
        backend: (any MusicBackend)?,
        context: LyricsResolveContext,
        useLRCLIB: Bool,
        userInitiated: Bool = false
    ) async -> LyricsResolution {
        let key = LyricsCacheKey.make(
            trackID: track.id, connectionID: backend?.connection.id
        )

        // L1: in-memory memo for this session.
        if let cached = await memo.value(for: key) {
            return LyricsResolution(lyrics: cached, staySilent: cached == nil)
        }
        // L2: lyrics saved because the track was downloaded. Consulted before the
        // ordinary cache because it is the durable one — and because a downloaded
        // track is exactly the case where there may be no network to fall back on.
        if let saved = await offline.cached(key) {
            await memo.set(saved, for: key)
            return LyricsResolution(lyrics: saved, staySilent: saved == nil)
        }
        // L3: on-disk cache. A negative hit here is the big saving for
        // instrumentals — once we've asked and found nothing we skip the network
        // and stay quiet, while a debounced background re-check still catches a
        // later upload.
        if let cached = await disk.cached(key) {
            await memo.set(cached, for: key)
            return LyricsResolution(lyrics: cached, staySilent: cached == nil)
        }
        // L4: title heuristic. Persisted through the cache layers so it isn't
        // re-evaluated on every play.
        if isExplicitlyInstrumental(title: track.title) {
            await memo.set(nil, for: key)
            await disk.store(nil, for: key)
            return LyricsResolution(lyrics: nil, staySilent: true)
        }

        let outcome = await lookUp(
            track: track,
            backend: backend,
            useLRCLIB: useLRCLIB,
            allowTitleOnlyFallback: context == .visible,
            ignoresBackoff: userInitiated
        )
        // Only persist a result we actually trust. A positive is always
        // trustworthy; a negative only when it was authoritative. An offline
        // negative is cached in NEITHER layer — otherwise one wifi blip poisons
        // the session and a longer outage burns "no lyrics" onto disk for every
        // song played during it.
        if outcome.lyrics != nil || outcome.isAuthoritative {
            await memo.set(outcome.lyrics, for: key)
            await disk.store(outcome.lyrics, for: key)
        }
        return LyricsResolution(
            lyrics: outcome.lyrics,
            staySilent: outcome.lyrics == nil && !outcome.isAuthoritative
        )
    }

    /// Background re-check for a track whose visible state went silent. Honours a
    /// per-track debounce and returns lyrics **only** when the fresh lookup found
    /// something the cache didn't have, so it can never re-flash "No lyrics found".
    public func refresh(
        track: Track,
        backend: (any MusicBackend)?,
        useLRCLIB: Bool
    ) async -> Lyrics? {
        let key = LyricsCacheKey.make(
            trackID: track.id, connectionID: backend?.connection.id
        )
        if let age = await disk.entryAge(key), age < Self.refreshDebounce { return nil }

        // This re-checks the track the user is looking at, so it earns full effort.
        let outcome = await lookUp(
            track: track, backend: backend, useLRCLIB: useLRCLIB,
            allowTitleOnlyFallback: true, ignoresBackoff: false
        )
        // Offline: leave the existing entry alone and let a future play try again.
        // We only consume the debounce window on an authoritative response.
        guard outcome.isAuthoritative else { return nil }
        if let lyrics = outcome.lyrics, !lyrics.isEmpty {
            await memo.set(lyrics, for: key)
            await disk.store(lyrics, for: key)
            return lyrics
        }
        // Still nothing — reset the clock without changing the stored answer.
        await disk.touch(key)
        return nil
    }

    // MARK: Fan-out

    struct Outcome: Sendable {
        var lyrics: Lyrics?
        var isAuthoritative: Bool
    }

    /// Races the server and LRCLIB concurrently and returns the first usable
    /// result, preferring **synced** lyrics from either source and preferring the
    /// server on ties.
    ///
    /// Running these in parallel (rather than awaiting the server first) is what
    /// keeps a slow home server from pinning the visible wait when LRCLIB would
    /// have answered in 200ms.
    func lookUp(
        track: Track,
        backend: (any MusicBackend)?,
        useLRCLIB: Bool,
        allowTitleOnlyFallback: Bool,
        ignoresBackoff: Bool
    ) async -> Outcome {
        let artist = track.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasArtist = !artist.isEmpty
        let hasUsableDuration = track.duration > 0
        // A closed gate is "we couldn't ask", never "the answer is no" — so a
        // negative formed while backed off is not authoritative and is never
        // cached. The moment the network returns, the next lookup resolves normally.
        let mayAskServer: Bool
        if ignoresBackoff {
            mayAskServer = true
        } else {
            mayAskServer = await serverBackoff.shouldAttempt()
        }
        let mayAskLRCLIB: Bool
        if !useLRCLIB || !hasArtist {
            mayAskLRCLIB = false
        } else if ignoresBackoff {
            mayAskLRCLIB = true
        } else {
            mayAskLRCLIB = await lrclibBackoff.shouldAttempt()
        }
        let lrclibConsulted = useLRCLIB && hasArtist

        enum Source { case server, lrclib, deadline }
        struct Probe: Sendable {
            let source: Source
            let lyrics: Lyrics?
            let reachable: Bool
        }

        return await withTaskGroup(of: Probe.self) { group in
            let serverBackoff = self.serverBackoff
            let lrclibBackoff = self.lrclibBackoff
            group.addTask {
                guard mayAskServer else {
                    // Backed off — we didn't ask, so we know nothing.
                    return Probe(source: .server, lyrics: nil, reachable: false)
                }
                guard let backend else {
                    // No backend at all (offline demo): an authoritative "the
                    // server has nothing", so LRCLIB alone decides.
                    return Probe(source: .server, lyrics: nil, reachable: true)
                }
                // The backend pre-classifies its own failures: a real "no lyrics"
                // from a reachable server returns nil, a transport failure throws.
                // So any throw means we could NOT get an authoritative verdict.
                do {
                    let lyrics = try await backend.fetchLyrics(for: track)
                    // Reaching the server at all — even to be told there are no
                    // lyrics — proves the connection works, so the gate reopens.
                    await serverBackoff.recordSuccess()
                    return Probe(source: .server, lyrics: lyrics, reachable: true)
                } catch is CancellationError {
                    // Skipping tracks quickly cancels these; that says nothing
                    // about the network and must not count against it.
                    return Probe(source: .server, lyrics: nil, reachable: false)
                } catch {
                    await serverBackoff.recordFailure()
                    return Probe(source: .server, lyrics: nil, reachable: false)
                }
            }
            if mayAskLRCLIB {
                group.addTask {
                    let result = await lrclib.lyrics(
                        title: track.title,
                        artist: artist,
                        duration: track.duration,
                        allowTitleOnlyFallback: allowTitleOnlyFallback
                    )
                    if Task.isCancelled {
                        return Probe(source: .lrclib, lyrics: nil, reachable: false)
                    }
                    if result.reachable {
                        await lrclibBackoff.recordSuccess()
                    } else {
                        await lrclibBackoff.recordFailure()
                    }
                    return Probe(source: .lrclib, lyrics: result.lyrics, reachable: result.reachable)
                }
            }

            var heldLRCLIB: Lyrics?
            var plainFallback: Lyrics?
            var sawServer = false
            var serverReachable = false
            var lrclibReachable = false
            var armedDeadline = false

            func negativeIsAuthoritative() -> Bool {
                LyricsNegativeAuthority.isAuthoritative(
                    serverReachable: serverReachable,
                    lrclibSkippedForMissingArtist: useLRCLIB && !hasArtist,
                    lrclibSkippedForDisabled: !useLRCLIB,
                    lrclibConsulted: lrclibConsulted,
                    lrclibReachable: lrclibReachable,
                    allowedTitleOnlyFallback: allowTitleOnlyFallback,
                    hasUsableDuration: hasUsableDuration
                )
            }

            for await probe in group {
                if probe.reachable {
                    switch probe.source {
                    case .server: serverReachable = true
                    case .lrclib: lrclibReachable = true
                    case .deadline: break
                    }
                }
                // Synced wins outright; a plain result is held as a fallback in
                // case nothing synced ever turns up.
                let synced = (probe.lyrics?.isSynced == true && probe.lyrics?.isEmpty == false)
                    ? probe.lyrics : nil
                if synced == nil, let plain = probe.lyrics, !plain.isEmpty, plainFallback == nil {
                    plainFallback = plain
                }

                switch probe.source {
                case .server:
                    sawServer = true
                    if let synced {
                        group.cancelAll()
                        return Outcome(lyrics: synced, isAuthoritative: true)
                    }
                    // The server has no synced lyrics. If LRCLIB already produced
                    // a synced copy, take it now; otherwise keep waiting on it.
                    if let heldLRCLIB {
                        group.cancelAll()
                        return Outcome(lyrics: heldLRCLIB, isAuthoritative: true)
                    }
                case .lrclib:
                    if let synced {
                        // Give the server (preferred attribution) a chance to land
                        // first, but only if it's still pending.
                        if sawServer {
                            group.cancelAll()
                            return Outcome(lyrics: synced, isAuthoritative: true)
                        }
                        heldLRCLIB = synced
                        if !armedDeadline {
                            armedDeadline = true
                            group.addTask {
                                try? await Task.sleep(
                                    nanoseconds: UInt64(Self.serverHeadStart * 1_000_000_000)
                                )
                                return Probe(source: .deadline, lyrics: nil, reachable: false)
                            }
                        }
                    } else if sawServer {
                        // Both sources reported with nothing synced. Any plain copy
                        // is still worth showing on iOS (unlike a TV, the user can
                        // scroll it).
                        group.cancelAll()
                        return Outcome(
                            lyrics: plainFallback,
                            isAuthoritative: plainFallback != nil || negativeIsAuthoritative()
                        )
                    }
                case .deadline:
                    // The head-start window elapsed with the server still not
                    // producing synced lyrics — commit the copy we've been holding.
                    if let heldLRCLIB {
                        group.cancelAll()
                        return Outcome(lyrics: heldLRCLIB, isAuthoritative: true)
                    }
                }
            }

            if let heldLRCLIB { return Outcome(lyrics: heldLRCLIB, isAuthoritative: true) }
            if let plainFallback { return Outcome(lyrics: plainFallback, isAuthoritative: true) }
            return Outcome(lyrics: nil, isAuthoritative: negativeIsAuthoritative())
        }
    }
}
