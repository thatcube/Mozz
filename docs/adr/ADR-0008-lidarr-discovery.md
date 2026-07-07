# ADR-0008 — Discovery + acquisition via Lidarr (Phase C)

Status: **Proposed** (design only; depends on ADR-0007 B1–B3 shipping first).

## Context

ADR-0007 (B1–B3) builds a taste-similarity graph from MusicBrainz IDs and
ListenBrainz "similar recordings", but every read is deliberately scoped to tracks
the user **already owns** (`EnrichmentStore.similarOwnedTracks`). ListenBrainz also
returns, for each seed, similar recordings the user does **not** own — right now
those rows are simply filtered out.

Those not-owned similar recordings are the raw material for the feature people
actually want from a music app: **a "Discover Weekly" of songs you've never heard
but that fit your taste** — and, because they carry MBIDs, they can be handed to a
downloader the user already runs so they arrive *in the library* rather than
linking out to a store or a service Mozz doesn't control.

Mozz is a **client**: it plays a Plex/Jellyfin library, it does not (and should
not) download music itself. The open-source, user-controlled way to turn a
"recommended but not-owned" MBID into an owned track is
[Lidarr](https://lidarr.audio) — a MusicBrainz-native library manager many
self-hosters already run alongside Plex/Jellyfin. Because Lidarr tags everything
via MusicBrainz, anything it acquires arrives with the exact MBIDs our similarity
graph is keyed on, so it slots straight back in and starts appearing in radio.

## Decision

Add an **optional, opt-in** discovery layer on top of B1–B3:

1. Surface not-owned ListenBrainz-similar recordings as a **"Mozz Discover"** set
   (never-heard songs that fit the listener's taste).
2. Let the user hand a discovery pick's MBIDs to **their own Lidarr** to acquire,
   monitor, and search — then, once Lidarr grabs it and the next catalog sync runs,
   the track appears in the library and the similarity graph, closing the loop.

Nothing here downloads music inside Mozz. Mozz only (a) reads open similarity data
it already has and (b) POSTs an "add + search" request to a Lidarr instance the
user configured. Acquisition is always an explicit user action (or an explicit
opt-in automation), never silent.

## Design

### C1 — Mozz Discover (surface, no acquisition)
- **Candidate query:** drive from `similar_recording` (the small side) like
  `similarOwnedTracks`, but **invert** the ownership test. A recording is a
  discovery candidate when its `similar_mbid` is **not owned on the active
  server**. Ownership must be a **server-scoped `NOT EXISTS` anti-join** (never
  `NOT IN`, which breaks on NULLs):

  ```sql
  ... FROM similar_recording sr
  WHERE sr.algorithm = ? AND sr.source_mbid IN (seeds…)
    AND NOT EXISTS (
      SELECT 1 FROM track_features tf
      JOIN track ON track.serverId = ?
                AND track.remoteId = substr(tf.track_ref, length(?) + 2)
      WHERE tf.track_ref = (? || ':' || track.remoteId)   -- refExpr guard
        AND (tf.canonical_mbid = sr.similar_mbid OR tf.mbid = sr.similar_mbid))
  ```

  Two correctness rules the mirror of `similarOwnedTracks` must honor:
  - **Server scope.** `idx_track_features_canonical_mbid` is global, so the
    existence probe MUST also match the track to the active `serverId` — otherwise
    a recording owned only on server A is wrongly hidden as "owned" on server B.
  - **Canonical *and* raw fallback.** Match ownership on `canonical_mbid` **or**
    raw `mbid`. Checking only `canonical_mbid` would misclassify an owned-but-not-
    yet-canonicalized track as "not owned" and surface a song the user already has.
  Seeds are the bounded top-taste canonical MBIDs (reuse `maxSeeds`); results are
  `LIMIT`-capped. Driving from the seed set keeps this off any full-table scan.

- **Identity + display metadata (needs schema — the item table can NOT represent
  a not-owned pick as-is).** `recommendation_item` is `PRIMARY KEY(set_id,
  track_ref)` with `track_ref NOT NULL`, and the render path
  (`RecommendationStore.tracks(forSet:)`) hard-filters `in_library = 1` and joins
  `track` via `refExpr = serverId||':'||remoteId = track_ref`. A discovery pick
  has **no** `track` row and **no** real `track_ref`, so it cannot be stored or
  rendered today. C1 therefore adds, as a deliberate (small) schema change — NOT
  "zero churn":
  - a **`recording_mbid` column on `recommendation_item`** (nullable; the durable
    identity for a not-owned pick, since `track_ref` cannot be), and
  - a **`similar_recording_meta`** table keyed by `mbid` holding
    `recording_name` / `artist_credit_name` / `artist_credit_mbids`, so Discover
    renders title/artist without a per-item network call. A dedicated meta table
    (vs. widening `similar_recording`) avoids denormalizing display text across
    every pair row that shares a popular `similar_mbid`.
  - a **discovery read path** (`items(forSet:)` already returns raw items without
    the `track` join; add a variant that left-joins `similar_recording_meta` on
    `recording_mbid`). Discovery-only sets also need an artwork fallback — the
    existing `representativeArtworkKeys` only samples rows that join `track`, so an
    all-discovery set has no cover until items land in-library.

- **B2 re-plumb (the display fields are currently discarded, not just unstored).**
  `replaceSimilarRecordings(...)` takes `pairs: [(similarMbid, score)]`, dropping
  `recording_name`/`artist_credit_name`/`artist_credit_mbids` at the fetch
  boundary. C1 must widen that path to retain and persist them into
  `similar_recording_meta`. No new network — the B2 response already carries them.

- **Surface:** a `recommendation_set` of kind `discover` (the `kind` enum already
  lists `discover`) with `recommendation_item.in_library = 0`.
- **Trigger/cadence (must run AFTER similarity, not with the other sets).** Today
  `AppEnvironment.syncNow` regenerates recommendation sets *before* the enrichment
  pass runs, so a Discover set generated at that point would be a pass stale.
  C1 regeneration must be triggered **after the B2 similarity stage completes**
  (or on the next sync using the prior pass's data), not inline with Mozz Weekly.

### C2 — Lidarr acquisition (opt-in)
- **New `MozzLidarr` module** (deps MozzCore, MozzNetworking) — a thin Lidarr v1
  API client, mirroring the MozzPlex/MozzJellyfin one-client-per-service precedent.
  Reuses `HTTPClient` + the same rate-limiting/transport machinery.
- **Module boundary (invariant):** the Lidarr network calls live in `MozzLidarr`,
  and the "add + search + track" orchestration lives in the app/enrichment
  orchestration layer (`AppEnvironment`), exactly like the enrichment pipeline
  owns MusicBrainz/ListenBrainz. `MozzRecommend` stays network-free and never
  learns about Lidarr — it only reads the Discover set from the store.
- **Config:** Settings gets a "Lidarr" section — base URL + API key (stored in the
  Keychain via the existing `CredentialStore`), a "Test Connection", and a quality
  profile / root folder picker (fetched from Lidarr). Entirely user-supplied; no
  Mozz-hosted anything. LAN Lidarr is typically plaintext HTTP, so the API key
  crosses the local network in cleartext (same ATS/local-network posture as a
  plaintext Plex/Jellyfin server) — call this out in the Settings copy.
- **Acquisition granularity — a DECISION, not an open question.** ListenBrainz
  gives a *recording* MBID, but Lidarr acquires **artists** and monitors
  **albums/release-groups** — it cannot add a lone recording. Adding an *artist*
  with `monitored: true` + search can pull the artist's **entire discography**
  under the quality profile from a single "Add to Library" tap — surprising and
  huge. So the default is **release-group-level**: resolve the recording →
  release-group via a MusicBrainz lookup (the stored `artist_credit_mbids` give
  the *artist* only, not the RG, so this needs one extra MB call), add the RG
  monitored + search. Artist-level add is offered only as an explicit "follow this
  artist" affordance, never the default per-song action.
- **Action:** on a Discover item's "Add to Library", run the resolve-then-POST in
  the orchestration layer and record the request locally (see `discovery_acquisition`
  below) so the UI can show "Requested / Searching / Downloading / In Library /
  Not found".
- **State + idempotency (`discovery_acquisition` table).** Model real failure
  modes, not just a free-text state. Columns: `server_id`, `recording_mbid`,
  `target_kind` (artist|release_group), `target_mbid`, `lidarr_entity_id`,
  `state`, `attempt_count`, `last_error`, `requested_at`, `updated_at`, with a
  **unique key on (server_id, target_kind, target_mbid)** so multiple Discover
  picks that map to the same artist/RG de-dupe into one request. Lidarr returns
  400/409 when an artist already exists/is monitored — treat that as success
  (adopt the existing entity), not an error. State machine:
  `requested → searching → grabbed → imported → reconciled`, with terminal
  `not_found` / `failed` / `expired`.
- **Optional automation:** a user toggle "Auto-add my weekly discoveries to Lidarr"
  — off by default; when on, C1's top-N are submitted on regeneration (subject to
  the same de-dupe).

### C3 — Close the loop
- Acquired tracks are tagged by Lidarr via MusicBrainz, so the next normal catalog
  sync ingests them; B1 captures their embedded MBIDs, B2 canonicalizes + fetches
  their similarity, and they immediately become eligible for radio and Mozz Weekly.
- **Reconciliation is granularity-aware, not exact-recording.** The requested
  identity is a *release-group / artist*, and the acquired file's embedded/
  canonicalized *recording* MBID is frequently **not** the same recording that
  ListenBrainz suggested. So a `discovery_acquisition` reconciles when **any newly
  owned track on that server falls under the requested `target_mbid`** (its
  artist/RG MBID matches), not when a specific recording MBID appears. On
  reconciliation, flip the matching Discover `recommendation_item` to
  `in_library = 1` and, because a not-owned item has no `track_ref`, **remap its
  identity to the now-owned track's real `track_ref`** so the standard render path
  picks it up.
- **Timeout.** If nothing reconciles within a bounded window (indexer miss, no
  release available), the acquisition moves to terminal `expired`/`not_found` so
  the UI stops showing "Downloading…" forever and the user can retry.

## Consequences
- **Requires the user to run Lidarr** (C2/C3). C1 (Discover, surface-only) works
  for everyone with no extra infrastructure and is valuable on its own — so C1 can
  ship independently of C2.
- Coverage is bounded by what Lidarr can actually find (indexers/quality profile);
  the `not_found`/`expired` terminal states exist precisely because a lot of picks
  won't be acquirable.
- **Not the first third-party write, but the first to a service the user isn't
  actively browsing.** Mozz already writes favorites/ratings/progress back to the
  Plex/Jellyfin server it's connected to (`PlexBackend`/`JellyfinBackend` + the
  outbox). Lidarr is different in that it's a *separate* service the user must
  configure. Mitigated the same way: opt-in, user-supplied URL/key in the Keychain,
  explicit per-item action, and only MBIDs + the user's own Lidarr credentials are
  involved; nothing goes to a Mozz-operated service.
- **Privacy doc update required.** `docs/PRIVACY.md` currently frames MetaBrainz as
  "the one exception" to "talks to your server and nothing else." C2 adds a second
  optional outbound integration (the user's own Lidarr), so that section needs
  rewording to describe it as an opt-in, self-hosted destination.
- Keeps Mozz a client: it never downloads or transcodes music itself — Lidarr does
  the acquisition. `MozzDownloads` remains offline caching of the user's *own*
  library files, unrelated to this path.

## Alternatives considered
- **Manual "search on MusicBrainz/your server" links** — zero infra but no
  acquisition; fine as a fallback when Lidarr isn't configured (and the natural C1
  behavior).
- **Direct downloaders (deemix, etc.)** — legally/ethically off-limits and against
  the app's open, self-hosted spirit; rejected.
- **Spotify/Apple "add to playlist" export** — links out to a paid service Mozz
  doesn't control; contradicts the offline/self-hosted premise. Possible minor
  share affordance later, never the core path.
- **Build acquisition into Mozz** — turns a client into a downloader; large scope,
  legal exposure, and duplicates what Lidarr already does well. Rejected.

## Phasing
- **C1** — Discover set from not-owned similarity + display metadata (no Lidarr).
  Includes the schema additions (`recommendation_item.recording_mbid`,
  `similar_recording_meta`), the B2 fetch re-plumb to retain display fields, the
  server-scoped `NOT EXISTS` candidate query, and the post-similarity trigger.
- **C2** — MozzLidarr client + Settings config + release-group-level "Add to
  Library" action + `discovery_acquisition` state machine with de-dupe.
- **C3** — granularity-aware round-trip reconciliation + timeout, remapping a
  reconciled Discover item onto the now-owned `track_ref`.

## Open questions
- Rank discovery by a single top-taste seed set vs. per-seed "because you like X"
  rows (the latter is nicer UX, more queries).
- Whether C1 needs its own similarity fetch budget or can piggyback B2's pass, and
  the concrete seed cap / `LIMIT` / refresh cadence for `discoveryCandidates`
  (bound it explicitly rather than "mirror `similarOwnedTracks`").
- The exact bounded window before an acquisition is marked `expired`, and whether
  to auto-retry once before giving up.
- Whether a "follow this artist" (artist-level, whole-discography) add is worth
  offering at all, given how much it can pull.
