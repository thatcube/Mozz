# Subsonic/OpenSubsonic Backend — Architecture Notes

> Branch-only document. Do NOT merge to `main` — this is a working note for
> the design-review competition, not user-facing or maintainer documentation.

## Summary

Adds `BackendKind.subsonic`, a generic Subsonic/OpenSubsonic `MusicBackend`
conformer (v1 scoped/QA'd against Navidrome; best-effort for Gonic, Ampache,
LMS). Mirrors `MozzJellyfin`'s module shape: DTOs → Auth → Client → Mapper →
Authenticator → Backend, all wired through the same `AppEnvironment`,
`LibrarySyncEngine`, and `MozzDatabase` seams Plex/Jellyfin already use.

## Key design decisions

### 1. Album-walk sync, not `search3`
`search3(query: "")` is an OpenSubsonic convenience some servers don't even
support with an empty query (Subsonic classic servers may 400/error on it).
It's used ONLY as a quick-start fast path (`fetchTracks`) and explicitly
**never** feeds prune decisions — `phaseCompleted` never uses a
`search3`-backed phase's totalCount to authorize deletion, because that phase
doesn't opt into `requiresKnownTotal` bulk semantics at all; it's just the
ordinary flat pager.

The authoritative walk is `getAlbumList2(type=alphabeticalByArtist) →
getAlbum(id)`, deduped by song id, with `expectedTotal` computed as
`Σ songCount` across the album index — but **only if every album reports a
`songCount`**. If even one album omits it, `expectedTotal` becomes `nil` and
the bulk enumerator flows through the same "unknown total ⇒ never prune"
gate used everywhere else. This was verified with a dedicated fixture pair
(`sub_walk_album_1/2.json`) where a song is deliberately cross-listed across
two albums: dedup collapses it to one row, but `expectedTotal` still sums the
album-reported counts (2+2=4) rather than the deduped count (3) — proving the
two numbers are independently computed and compared, not silently reconciled.

### 2. Prune-safety is enforced in TWO places
- **`SubsonicBackend.enumerateAllTracks`**: only produces a total when
  provably complete (every album's `songCount` present).
- **`LibrarySyncEngine.PagedEnumeration.requiresKnownTotal`**: a NEW field,
  set only by the new `syncTracksBulk` path. `phaseCompleted` now has three
  branches: known total → compare; `requiresKnownTotal && total == nil` →
  **always incomplete, no matter how many items were seen**; otherwise
  (existing Plex/Jellyfin flat-pager behavior) → "non-empty ⇒ complete".

  This is deliberately NOT a Subsonic-only special case bolted onto the
  Subsonic backend — it's a generic strengthening of the sync engine's
  completeness contract that any future bulk-enumerator backend inherits for
  free, while Plex/Jellyfin (which never set the flag) see zero behavior
  change. Five dedicated `MozzSyncTests` cases cover: bulk preferred over
  flat pager, unknown-total never prunes, known-total-and-complete does
  prune, mid-walk failure doesn't prune, and quick-start never touches the
  bulk path even when the backend advertises one.

### 3. Bulk enumerator is a protocol *requirement* with a default, not an extension-only add-on
`hasBulkEnumerator`/`enumerateAllTracks` are declared in the `MusicBackend`
protocol body (not just a `where Self: ...` extension), with a default
implementation (`hasBulkEnumerator = false`, `enumerateAllTracks` yields
nothing) supplied in a protocol extension. This matters because
`LibrarySyncEngine` calls these through `any MusicBackend` — extension-only
"default-implemented-and-that's-it" methods on a protocol that a conformer
overrides don't dynamically dispatch correctly through an existential unless
the method is *also* a protocol requirement. Making it a requirement was the
deliberate, correct choice to keep this "additive, doesn't affect Plex/
Jellyfin" while still being genuinely polymorphic.

### 4. Credential envelope, not a schema change
`{mode: apiKey|md5|legacy, username, secret, salt?}` is JSON-encoded into the
existing keychain "token" string slot — no `StoredSession` schema touched.
For password sign-in, a **stable, randomly-generated salt is generated once
at sign-in time and persisted**; the plaintext password is discarded
immediately after computing `secret = md5(password + salt)`. This means:
  - Two authentication attempts against the same account, sessions apart,
    reuse the *same* salt (needed for the auth to keep working — the salt IS
    part of the persisted envelope, not re-rolled per request).
  - Every signed request within a session reuses `t=secret, s=salt` — this is
    what makes artwork URLs deterministic (point 8), since the URL's query
    string is fully determined by `(id, size, mode, secret, salt)`.
  - The plaintext password is never written to disk or logged — verified by
    a direct test (`testAuthenticateWithPasswordDiscardsPlaintextAndPersistsStableSalt`)
    asserting the persisted token string never contains the original password.
`legacy` (cleartext `p=password`) is modeled in the enum for forward
compatibility but has no authenticator entry point in v1 (deferred per spec).

### 5. `SubsonicClient` as the single choke point
Every Subsonic request — JSON API calls and binary (stream/download/artwork)
— funnels through `SubsonicClient`. Two request shapes:
  - `call(_:query:)` — decodes the `subsonic-response` envelope, throws a
    mapped `MozzError` on `status == "failed"` (errors arrive over HTTP 200,
    per the Subsonic spec — this is NOT an HTTP-status-code problem, it's a
    body-shape problem, and is unit-tested directly against the full
    documented Subsonic error code table).
  - `fetchBinary(action:query:)` — validates Content-Type before treating the
    body as media. An OpenSubsonic server returning an XML/JSON error body
    with HTTP 200 on a stream/download endpoint is a known real-world
    failure mode (auth expired mid-download, wrong id, etc.) — if Content-
    Type isn't audio/image/video/octet-stream, the client attempts a
    `subsonic-response` JSON decode to surface the *precise* mapped error,
    falling back to `.invalidResponse` for genuinely unrecognized bodies
    (e.g. XML). This is directly tested with three cases: XML error body
    rejected, JSON error body mapped to its precise code, genuine binary
    passes through untouched.

  `signedURL(action:query:)` (used for stream/download/artwork *URLs* handed
  to `AVPlayer`/`URLSession` background downloads, not routed through
  `fetchBinary`) intentionally does NOT get this validation — that's the
  player/`DownloadManager`'s job once the URL is dereferenced outside the
  client's own request lifecycle (see Known Limitations below).

### 6. Selective transcoding
Direct-play (`format=raw`, no re-encode) for `mp3, aac, m4a, alac, flac, wav`
containers — these are natively iOS-playable and preserve gapless metadata
and true quality. Transcode to AAC only when: the container isn't in that
allow-list (opus/ogg/wma), a bitrate cap was explicitly requested via
`StreamOptions.maxBitrateKbps`, or `forceTranscode` is set. Downloads always
use `/download` (the true original, content-type validated) regardless of
streaming preferences — offline copies should never be a lossy transcode of
a lossless source.

### 7. Multi-user server ID
`AppEnvironment.serverId(kind:baseURL:username:)` gained an **optional**
`username` parameter (default `nil`, so Jellyfin/Plex call sites are
byte-for-byte unaffected). Only the new `.subsonic` `buildBackend` case
passes `username: stored.userID`, folding a lowercased, non-empty username
into the id (`subsonic-https://host-brandon`). This lets two accounts on one
shared Navidrome instance coexist as independent "servers" in the local
catalog/download cache without id collisions — something Plex/Jellyfin don't
need today since those flows are effectively single-account-per-server in
this app.

### 8. Best-effort capability detection
`ping` (with the actual chosen auth mode) is the sole authority for "this
server/credential combination works." `getOpenSubsonicExtensions` is called
separately and wrapped in `try?` — a 404 (classic Subsonic servers don't
implement this endpoint at all) degrades to "assume classic profile"
(`isOpenSubsonic = false`, extension-gated features off), never treated as an
auth/connectivity failure. This is directly tested
(`testDetectsCapabilitiesClassicServerFallback`) with a fixture-less/`ping`-
only route set to prove the classic-server path doesn't throw.

## Deviations from the literal spec / known gaps

1. **No music-folder picker UI.** `connection.musicSectionID` is threaded
   through as Subsonic's `musicFolderId` end-to-end (query param on
   artist/album fetches and the album-walk — verified by
   `testMusicFolderScopingAddsQueryParam`), but there's no Settings screen to
   let a user actually choose a folder yet — `nil` means "all folders" today.
   Plex has an equivalent picker (`PlexLibraryPickerView`); a
   `SubsonicMusicFolderPickerView` following that exact pattern is the
   natural v1.1 addition and was deliberately left as a clean seam rather
   than rushed in.

2. **`DownloadManager` is not wired to `SubsonicClient`'s binary validation.**
   `DownloadManager` already bypasses `HTTPClient` entirely for ALL backends
   (it drives a raw background `URLSession` for resumable downloads), so this
   is a pre-existing architectural boundary, not something introduced here.
   Content-Type validation for *downloads* specifically (as opposed to
   in-client `fetchBinary` calls, which are fully validated and tested) is a
   gap shared by Plex/Jellyfin today; closing it for all three backends
   uniformly is out of scope for a single-backend addition and better done
   as its own cross-cutting change.

3. **Serial (not concurrent) album-walk fetching.** `enumerateAllTracks`
   walks `getAlbum(id:)` one album at a time. This is simpler, keeps memory
   bounded, and avoids hammering smaller self-hosted servers (Navidrome/Gonic
   are frequently run on modest hardware) with a burst of concurrent
   requests, but is slower than it could be for very large libraries. A
   bounded-concurrency (`withThrowingTaskGroup`, N=4-ish) variant would be
   the first performance follow-up if a real library shows this is slow in
   practice.

4. **No test for `getAlbumList2` walk continuation across a real page
   boundary (500-item page).** The 500-item internal album-walk page size
   (`SubsonicBackend.albumWalkPageSize`) is exercised by every other
   album-walk test at small scale (2-3 albums), but a fixture simulating a
   true multi-page walk (501+ albums) was judged impractical to author by
   hand and wasn't in the spec's explicit required-test list. The
   pagination *logic* itself (offset/size loop, terminate on short/empty
   page) is structurally identical to the already-tested `fetchAlbums`
   pager, so the risk is judged low, but this is the one honest test gap
   worth flagging.

5. **`fetchTracks` (search3-backed quick-start) swallows ALL errors to an
   empty page**, not just "empty query unsupported." This was a deliberate
   simplification — quick-start is advisory/best-effort by design (never
   prune-authorizing, per spec), so a broad catch keeps the quick-start path
   maximally resilient across the long tail of OpenSubsonic server quirks,
   at the cost of masking genuinely-actionable errors (e.g. real auth
   failures) behind an empty page during quick-start specifically. Full sync
   (the album-walk) does NOT swallow errors this way — a real auth failure
   there surfaces normally.

6. **`legacy` (cleartext password) auth mode** is modeled in
   `SubsonicCredential`/`SubsonicAuth` for forward compatibility but has no
   UI/authenticator entry point — matches the spec's explicit "deferred past
   v1" instruction.

## What I'd refine with more time

- Bounded-concurrency album-walk fetching (see #3 above).
- A `SubsonicMusicFolderPickerView` mirroring `PlexLibraryPickerView`.
- A real multi-page album-walk fixture/test (#4 above) rather than relying on
  structural similarity to the already-tested flat pager.
- Tightening `fetchTracks`'s error handling to distinguish "server doesn't
  support empty-query search3" (swallow) from "genuine auth/network failure"
  (surface) — currently both look the same to quick-start.
- Wiring `DownloadManager`'s background-session downloads through the same
  Content-Type validation `fetchBinary` already has, for all three backends
  uniformly (not a Subsonic-specific fix).
