import Foundation
import MozzCore
import MozzDatabase

/// The knobs of one analysis pass.
public struct SonicAnalysisConfig: Sendable {
    /// How many candidates to pull from the database at a time.
    public var batchSize: Int
    /// A ceiling on tracks attempted in a single pass, so a pass ends.
    public var maxPerPass: Int
    /// Seconds to wait between tracks. Not politeness for its own sake: each
    /// track is a transcode, and a self-hosted server is usually one machine
    /// that is also serving playback to the person who is waiting on it.
    public var pauseBetweenTracks: TimeInterval
    /// Inactivity allowance per fetch.
    public var timeout: TimeInterval
    /// How many tracks the wide first pass takes from any one artist before it
    /// moves on. See ``RecommendationStore/sonicSampleCandidates``.
    public var perArtistInSpread: Int
    /// How much of a library must be analyzed before the spread gives way to
    /// working through the rest. A share, not a count, because "enough to have
    /// neighbours" scales with the library.
    public var spreadFraction: Double

    public init(batchSize: Int = 20, maxPerPass: Int = 400,
                pauseBetweenTracks: TimeInterval = 0.35, timeout: TimeInterval = 60,
                perArtistInSpread: Int = 2, spreadFraction: Double = 0.15) {
        self.batchSize = batchSize
        self.maxPerPass = maxPerPass
        self.pauseBetweenTracks = pauseBetweenTracks
        self.timeout = timeout
        self.perArtistInSpread = perArtistInSpread
        self.spreadFraction = spreadFraction
    }
}

/// How far one server's library has got.
public struct SonicAnalysisProgress: Sendable, Hashable {
    public let analyzed: Int
    public let total: Int
    /// Whether a pass is walking this library right now. A host that keeps its
    /// process alive for the job needs this to know when it may stop.
    public let running: Bool
    /// Why the last track that failed, failed.
    ///
    /// Surfaced rather than only logged because the failure mode this guards
    /// against is silent: a server that will not transcode leaves a count that
    /// sits at zero with nothing to explain it, on a device with no console
    /// anyone is watching.
    public let lastError: String?
    public var remaining: Int { max(total - analyzed, 0) }
    public var fraction: Double { total > 0 ? Double(analyzed) / Double(total) : 0 }

    public init(analyzed: Int, total: Int, running: Bool = false, lastError: String? = nil) {
        self.analyzed = analyzed
        self.total = total
        self.running = running
        self.lastError = lastError
    }
}

/// Analyzes a library's audio on the device, one track at a time, in the
/// background.
///
/// This is the part that makes acoustic radio exist at all. The tiers above it
/// — a server's own `sonicSimilarity`, then collaborative similarity, then
/// genre — are all somebody else's opinion about what a track sounds like, and
/// most self-hosted servers have no opinion to give. This one listens.
///
/// Shaped like ``EnrichmentService``, and for the same reasons: single-flight
/// per server, cancellable as a unit, resumable across launches because the
/// only progress marker is the rows already written. Nothing is queued in
/// memory; the queue IS `tracksNeedingSonicAnalysis`, which shrinks as vectors
/// land, so an interrupted pass costs at most one track's work.
///
/// `isEnabled` is where the platform's own conditions live — on wifi, charging,
/// user hasn't turned it off. The core cannot see any of that, and re-checking
/// the closure before every track means the pass parks itself the moment the
/// phone is unplugged rather than finishing a library on someone's battery.
public actor SonicAnalysisService {
    private let store: RecommendationStore
    private let analyzer: SonicAnalyzer
    /// The learned engine, when its weights were available. When present it
    /// describes the audio and the DSP analyzer is kept only for tempo, which
    /// the network has no opinion about.
    private let learned: VGGishAnalyzer?
    private let load: AnalysisAudioLoader
    private let config: SonicAnalysisConfig
    private let isEnabled: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void

    private var pass: Task<Void, Never>?
    /// The server the in-flight pass is walking, so a raced server switch
    /// replaces it rather than no-opping behind it.
    private var currentPassServerId: ServerID?
    /// Bumped on every start and cancel so a stale task's cleanup can't clear a
    /// newer pass's registration.
    private var generation = 0
    /// The most recent track failure, kept for ``progress(serverId:)``. Cleared
    /// by the next success, so it describes a problem that is still happening
    /// rather than one that has been left behind.
    private var lastError: String?

    /// Load the learned engine's weights from a file the host has placed
    /// somewhere it can name.
    ///
    /// A path rather than the bytes themselves because the bytes are nine
    /// megabytes and the FFI boundary is JSON; a path rather than a bundle
    /// lookup because the core does not know what a bundle, an asset manager or
    /// an application directory is. Returns nil when the file is missing or is
    /// not weights, and the caller falls back to the DSP engine rather than
    /// failing — analysis with the older engine beats no analysis.
    public static func loadTrunk(at path: String) -> VGGishTrunk? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? VGGishTrunk(weights: data)
    }

    public init(store: RecommendationStore,
                analyzer: SonicAnalyzer = SonicAnalyzer(),
                trunk: VGGishTrunk? = nil,
                load: @escaping AnalysisAudioLoader = AnalysisAudioFetcher.live(),
                config: SonicAnalysisConfig = SonicAnalysisConfig(),
                isEnabled: @escaping @Sendable () -> Bool = { true },
                now: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store
        self.analyzer = analyzer
        self.learned = trunk.map { VGGishAnalyzer(trunk: $0) }
        self.load = load
        self.config = config
        self.isEnabled = isEnabled
        self.now = now
        self.log = log
    }

    /// The engine every read and write in this service is keyed on.
    ///
    /// Two engines are two unrelated coordinate spaces, so this is what keeps
    /// them apart: rows carrying the other one count as unanalyzed and are
    /// redone in the background.
    public nonisolated var engine: String { engineName }
    private nonisolated var engineName: String {
        learned == nil ? SonicAnalyzer.engine : VGGishAnalyzer.engine
    }

    // MARK: - Passes

    /// Kick a bounded background pass. No-op when disabled or already walking
    /// THIS server; a call for a different server replaces the pass. Never
    /// awaited by the caller.
    public func analyze(serverId: ServerID, backend: any MusicBackend) {
        guard isEnabled() else { return }
        if pass != nil {
            if currentPassServerId == serverId { return }
            generation += 1
            pass?.cancel()
            pass = nil
            currentPassServerId = nil
        }
        generation += 1
        let gen = generation
        currentPassServerId = serverId
        pass = Task { [weak self] in
            await self?.run(serverId: serverId, backend: backend)
            await self?.finishPass(gen)
        }
    }

    /// Stop the in-flight pass (server switch, sign-out, conditions lost).
    public func cancel() {
        generation += 1
        pass?.cancel()
        pass = nil
        currentPassServerId = nil
    }

    /// How much of this server's library this engine has done, and whether a
    /// pass is walking it right now.
    public func progress(serverId: ServerID) async -> SonicAnalysisProgress {
        let counts = (try? await store.sonicAnalysisProgress(serverId: serverId, engine: engineName))
            ?? (analyzed: 0, total: 0)
        return SonicAnalysisProgress(analyzed: counts.analyzed, total: counts.total,
                                     running: pass != nil && currentPassServerId == serverId,
                                     lastError: lastError)
    }

    /// Test hook: await the in-flight pass, if any.
    func waitForPass() async { await pass?.value }

    private func finishPass(_ gen: Int) {
        guard gen == generation else { return }
        pass = nil
        currentPassServerId = nil
    }

    // MARK: - The walk

    private func run(serverId: ServerID, backend: any MusicBackend) async {
        // Tracks tried in THIS pass, whether they produced a vector or not.
        //
        // A failure writes nothing — there is no column for "this one can't be
        // analyzed" — so a track the server refuses to transcode comes straight
        // back at the head of the next batch. Without this set the pass would
        // spend its whole budget on the same broken track; with it, the batch
        // that returns nothing new is the signal that the queue is drained.
        var attempted = Set<String>()
        var analyzed = 0
        var failed = 0

        while attempted.count < config.maxPerPass {
            guard checkpoint() else { break }
            let candidates: [TrackCandidate]
            do {
                candidates = try await queue(serverId: serverId, limit: config.batchSize + attempted.count)
            } catch {
                log("sonic: cannot read the queue: \(error)")
                break
            }
            let fresh = candidates.filter { !attempted.contains($0.trackRef) }
            if fresh.isEmpty { break }

            for candidate in fresh {
                guard attempted.count < config.maxPerPass else { break }
                guard checkpoint() else { break }
                attempted.insert(candidate.trackRef)
                do {
                    if try await analyzeTrack(candidate, serverId: serverId, backend: backend) {
                        analyzed += 1
                        lastError = nil
                    } else {
                        failed += 1
                        note("nothing analyzable for \u{201C}\(candidate.title)\u{201D}")
                    }
                } catch is CancellationError {
                    return
                } catch let error as MozzError where error == .cancelled {
                    return
                } catch {
                    failed += 1
                    note("\u{201C}\(candidate.title)\u{201D}: \(message(for: error))")
                }
                if config.pauseBetweenTracks > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(config.pauseBetweenTracks * 1_000_000_000))
                }
            }
        }

        if analyzed > 0 || failed > 0 {
            log("sonic: analyzed \(analyzed), skipped \(failed)")
        }
    }

    /// What to analyze next.
    ///
    /// Early on that is a spread — a couple of tracks from every artist — so
    /// that the first few hundred vectors have each other for company. Radio
    /// finds nothing acoustically when three hundred analyzed tracks are forty
    /// artists deep and the seed is none of them. Once enough of the library is
    /// done for neighbours to exist, the queue reverts to working through the
    /// rest in priority order, and the spread's own leftovers are simply part
    /// of what remains.
    private func queue(serverId: ServerID, limit: Int) async throws -> [TrackCandidate] {
        let counts = try await store.sonicAnalysisProgress(serverId: serverId, engine: engineName)
        let spreadTarget = Int(Double(counts.total) * config.spreadFraction)
        if counts.total > 0, counts.analyzed < spreadTarget {
            let spread = try await store.sonicSampleCandidates(
                serverId: serverId, engine: engineName,
                perArtist: config.perArtistInSpread, limit: limit)
            // The spread runs out once every artist has had its couple of
            // tracks, which happens well before the target on a library with few
            // artists. Falling through keeps the pass working rather than
            // ending it early.
            if !spread.isEmpty { return spread }
        }
        return try await store.tracksNeedingSonicAnalysis(
            serverId: serverId, engine: engineName, limit: limit)
    }

    /// One track, end to end. Returns false when there was nothing usable to
    /// analyze — no analyzable URL, undecodable bytes, or silence — which is a
    /// skip, not an error.
    private func analyzeTrack(_ candidate: TrackCandidate, serverId: ServerID,
                              backend: any MusicBackend) async throws -> Bool {
        guard let source = try backend.analysisAudioSource(forTrackID: candidate.remoteId) else { return false }
        let data = try await load(source.url, Self.byteBudget(startsAtLeadIn: source.startsAtLeadIn))
        let rate = VGGishFrontEnd.sampleRate
        // Scoped so the decoded stereo PCM — tens of megabytes for a 90-second
        // window — is gone before the DSP starts. What survives is the mono
        // 16 kHz window, which is a few megabytes.
        let window: [Float] = {
            guard let decoded = MP3Decoder.decode(data) else { return [] }
            let prepared = AudioPreparation.prepare(decoded, sampleRate: rate)
            return Self.window(prepared, sampleRate: rate, trimLeadIn: !source.startsAtLeadIn)
        }()
        guard !window.isEmpty else { return false }
        let features: SonicFeatures?
        var bpm: Double?
        if let learned {
            features = learned.analyze(window)
            // The network has no opinion about tempo, so the cheap half of the
            // DSP engine still runs: an onset envelope and an autocorrelation,
            // a fraction of the cost of the convolutions, and the difference
            // between a library with BPM and one without.
            bpm = analyzer.tempo(of: window)
        } else {
            let described = analyzer.analyze(window)
            features = described
            bpm = described?.tempoBPM
        }
        guard let features else { return false }

        try await store.saveSonicEmbedding(features.values,
                                           engine: features.engine,
                                           bpm: bpm,
                                           trackRef: candidate.trackRef,
                                           at: now().timeIntervalSince1970)
        return true
    }

    /// Record a failure for the progress readout, and log it.
    private func note(_ reason: String) {
        lastError = reason
        log("sonic: \(reason)")
    }

    /// The short, human form of an error — this ends up on a Settings row, not
    /// in a console.
    private func message(for error: any Error) -> String {
        guard let error = error as? MozzError else { return "\(error)" }
        switch error {
        case .unauthorized: return "the server refused the request"
        case .notFound: return "the server has no such track"
        case .badStatus(let code): return "the server answered \(code)"
        case .serverUnreachable: return "could not reach the server"
        case .unsupported(let detail): return detail
        default: return error.localizedDescription
        }
    }

    /// Returns false when the pass should stop; throws nothing so the caller
    /// can `break` cleanly.
    private func checkpoint() -> Bool {
        !Task.isCancelled && isEnabled()
    }

    // MARK: - Shaping the input

    /// The slice of decoded audio the analyzer actually sees.
    ///
    /// Takes ``AnalysisAudio/windowSeconds`` from the lead-in, and keeps
    /// whatever it can when a track is too short to give that — a 40-second
    /// interlude is still worth describing, and describing it from zero is
    /// better than not describing it at all.
    static func window(_ samples: [Float], sampleRate: Int, trimLeadIn: Bool) -> [Float] {
        let start = trimLeadIn ? AnalysisAudio.leadInSeconds * sampleRate : 0
        let length = AnalysisAudio.windowSeconds * sampleRate
        guard samples.count > start else {
            // Shorter than the lead-in: analyze the whole thing rather than
            // nothing.
            return samples.count > length ? Array(samples[0..<length]) : samples
        }
        let end = min(start + length, samples.count)
        return Array(samples[start..<end])
    }

    /// How many bytes are worth pulling for one track.
    ///
    /// The window at the requested bitrate, plus the lead-in when the server
    /// isn't skipping it, plus half again — servers treat a bitrate ceiling as
    /// a suggestion, and a stream that came back at 128 kbps should still yield
    /// a usable window rather than half of one.
    static func byteBudget(startsAtLeadIn: Bool) -> Int {
        let seconds = AnalysisAudio.windowSeconds + (startsAtLeadIn ? 0 : AnalysisAudio.leadInSeconds)
        let bytesPerSecond = AnalysisAudio.bitrateKbps * 1_000 / 8
        return Int(Double(seconds * bytesPerSecond) * 1.5)
    }
}
