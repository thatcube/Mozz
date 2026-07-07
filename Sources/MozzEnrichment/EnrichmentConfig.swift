import Foundation

/// Tunables for open metadata enrichment (ADR-0007). Constructed once at the
/// composition root and shared across the enrichment machinery.
public struct EnrichmentConfig: Sendable {
    /// Descriptive `User-Agent` — REQUIRED by MusicBrainz, must identify the app
    /// and a contact (e.g. `"Mozz/2026.7.6.2 ( https://github.com/thatcube/Mozz )"`).
    public var userAgent: String
    /// Minimum spacing between outbound MusicBrainz requests. MusicBrainz asks for
    /// ≤ 1 req/s per client.
    public var minRequestInterval: TimeInterval
    /// How long a lookup outcome (hit or miss) is trusted before it's eligible for
    /// a re-attempt — the negative cache's TTL.
    public var lookupTTL: TimeInterval
    /// Maximum tracks a single background pass will resolve (bounds outbound
    /// calls per sync; coverage widens across subsequent syncs).
    public var perRunBudget: Int
    /// Minimum MusicBrainz match score (0–100) to accept a name-search result.
    public var minScore: Int
    /// Max allowed |recording.length − track.duration| for a match, in
    /// milliseconds — rejects high-score wrong hits (live/remix/cover) when both
    /// durations are known. Skipped when either duration is unavailable.
    public var durationToleranceMs: Double

    public init(
        userAgent: String,
        minRequestInterval: TimeInterval = 1.0,
        lookupTTL: TimeInterval = 30 * 24 * 3600,
        perRunBudget: Int = 200,
        minScore: Int = 90,
        durationToleranceMs: Double = 10_000
    ) {
        self.userAgent = userAgent
        self.minRequestInterval = minRequestInterval
        self.lookupTTL = lookupTTL
        self.perRunBudget = perRunBudget
        self.minScore = minScore
        self.durationToleranceMs = durationToleranceMs
    }
}
