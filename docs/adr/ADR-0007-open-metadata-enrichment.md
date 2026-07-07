# ADR-0007 — Open metadata enrichment (MusicBrainz + ListenBrainz)

Status: Accepted (design), implementation phased and not yet started.

## Context

Recommendations and radio rank tracks by genre-tag similarity (TF-IDF cosine +
an IDF-weighted Jaccard floor; see `MozzRecommend`). That is as good as
tag-based matching gets, and it is not good enough: real libraries — Plex in
particular — carry coarse genre tags. A dream-pop track and a hard-rock track are
both filed under "rock," so a station seeded from one leaks the other. The
distinguishing signal simply isn't in the tags.

The app is free and open source, and deliberately offline-first. Two non-goals
follow from that: we won't build core quality on a paid dependency (e.g. Plex
Pass Sonic Analysis), and we won't add tracking/telemetry.

## Decision

Add an **open** similarity signal from [MetaBrainz](https://metabrainz.org)
(non-profit, open data), keyed by MusicBrainz IDs (MBIDs):

- **MusicBrainz** — resolve each track/artist to an MBID.
- **ListenBrainz** — `similar-recordings` / `similar-artists`, i.e. crowd
  listening-similarity ("people who play X also play Y"). This is taste
  similarity, not tags, so it separates songs that share a broad genre bucket.

Both are free, need no account or API key, and require nothing from the user.
Enrichment is **on by default** with a Settings switch to disable it (see
`docs/PRIVACY.md` for exactly what leaves the device and why).

### Module boundary

Enrichment lives in a **new `MozzEnrichment` module** (depends on `MozzCore`,
`MozzNetworking`, `MozzDatabase`) — not folded into `MozzRecommend`. This keeps
`MozzRecommend` a pure, network-free ranking layer (its stated contract), mirrors
the existing `MozzPlex`/`MozzJellyfin` precedent (each backend HTTP client is its
own module), and keeps `MozzRecommend` tests offline/deterministic.
`MozzRecommend` consumes enrichment results **from the database only** — it never
makes a network call. `MozzApp` triggers enrichment (after sync / on demand),
the same way it already orchestrates sync and recommendation regeneration.

### MBID resolution (cheap → expensive)

1. **Embedded MBIDs** already in the Plex/Jellyfin catalog metadata, extracted
   during the existing sync (Plex GUIDs, Jellyfin `ProviderIds`). No network.
2. **MusicBrainz name search** (artist + title) only for tracks lacking one.
   Rate-limited to 1 request/second with a descriptive `User-Agent`. Both hits
   and misses are cached (a negative result is stored so we don't re-query).

### Storage

Reuses the existing `track_features` table (`mbid`, `artist_mbid`, `tags`,
`feature_source`, `updated_at`). Adds one `similar_recording` table
(`source_mbid`, `similar_mbid`, `score`, `fetched_at`) plus lookup indexes. The
`mbid → track_ref` reverse map (needed to turn "similar MBIDs" back into tracks
the user owns) is a JOIN on `track_features`, not a new table. Everything keys on
the durable `track_ref`, never `remoteId` alone, so enrichment survives a catalog
prune (consistent with the v6 migration's contract).

### When it runs (lazy, seed-first)

Not a big upfront crawl. On "Start Station," resolve the **seed** first (1–2
calls) so radio seeds immediately and improves as resolution completes. In the
background, enrich recently-played and top-taste artists first, widening over
time. Artist-level resolution is preferred where possible (far fewer artists than
tracks). Everything is cached permanently, so the cost is one-time.

### Radio ranking precedence (each step falls back to the next)

1. Seed MBID known + ListenBrainz similar recordings that map to **owned**
   tracks → rank by similarity score.
2. Else artist-radio via `similar-artists` → owned tracks by those artists.
3. Else the existing genre engine (weighted-Jaccard floor + cosine).

Never worse than today: if enrichment is absent, stale, or disabled,
recommendations fall back to the genre engine immediately.

## Consequences

- First core feature that makes an outbound request to a third party. Mitigated
  by: MetaBrainz is a non-profit with open data; only song metadata (no identity)
  is sent; on-by-default with an off switch; documented in `docs/PRIVACY.md`.
- Quality improves *over time* as enrichment completes, rather than being perfect
  on first launch. Acceptable given the lazy/cached design.
- Coverage isn't 100% — obscure or local tracks may have no MBID or no similarity
  data. Those fall back to the genre engine.

## Pitfalls to honor in implementation

1. Key enrichment on the durable `track_ref`, not `remoteId`.
2. Index the MBID lookup/join paths (`track_features.mbid`, `artist_mbid`,
   `similar_recording.source_mbid`) or radio queries degrade.
3. The 1 req/sec limiter must govern *actual outbound attempts*, so
   `HTTPClient`'s retries can't exceed the API's rate policy.
4. Enrichment absence/staleness must never block `RecommendationService`; the
   genre fallback stays immediate.

## Alternatives considered

- **Plex Sonic Analysis** — genuinely good, but Plex Pass only. Building core
  quality on a paywall contradicts the app's free/open premise. May be an
  optional bonus later, never a requirement.
- **Last.fm tags** — richer than Plex's, but Last.fm is free-of-charge, not open
  (proprietary, corporate-owned). Fits later as opt-in scrobbling, not as the
  core signal.
- **On-device audio embeddings** (the `SonicRecommender` stub) — the eventual
  gold standard: fully offline, no coverage gaps, no network. Much larger build
  (audio decode + a Core ML model + vector k-NN). This ADR is the pragmatic
  free/open step now; embeddings remain the endgame.

## Phasing

- **B1** — MBID resolution: extract-on-sync + MusicBrainz search client + store +
  negative cache.
- **B2** — ListenBrainz client + `similar_recording` store + `mbid → track_ref`
  reverse map.
- **B3** — wire radio ranking precedence (ListenBrainz → artist → genre fallback).
- **B4** (optional) — MusicBrainz genre/tag enrichment into `track_features.tags`,
  feeding the existing genre engine so Smart Shuffle and Mozz Weekly improve too.

## Future: Discovery + acquisition (Phase C, separate)

ListenBrainz also returns similar tracks the user *doesn't* own. Those are the
seed of a "Discover Weekly" of never-heard songs — but Mozz is a client and won't
download music itself. The open-source path is to hand those MBIDs to
[Lidarr](https://lidarr.audio) (which the user already runs and configures), let
it acquire and MusicBrainz-tag them into the library, and surface the results
once they sync in. Because Lidarr tags via MusicBrainz, acquired tracks arrive
with MBIDs and slot straight into the similarity graph. Distinct, optional, and
built on top of B1–B3.
