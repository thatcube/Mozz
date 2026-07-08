# Subsonic backend — architecture notes

*This file lives on `thatcube-subsonic-backend-opus47` only — do NOT merge to
`main`. Kept per the competition brief so a human reviewer can compare the
three implementations' design choices side-by-side.*

## What was built

A new `MusicBackend` conformer under `Sources/MozzSubsonic/` that speaks the
Subsonic / OpenSubsonic API, wired end-to-end into the app (onboarding →
capability detection → sync → playback → downloads). v1 is QA-focused on
Navidrome; classic Subsonic and other OpenSubsonic servers (Gonic, Ampache,
LMS) are best-effort and fall back gracefully to a classic-Subsonic profile.

## Key design decisions

### 1. Generic `BackendKind.subsonic` — not per-server enums

One case, one conformer. Server-product-specific behavior (Navidrome vs Gonic
vs LMS) is discovered at runtime via `ping.type` and
`getOpenSubsonicExtensions`, then surfaced through `ServerCapabilities`
(`serverProductType`, `isOpenSubsonic`) so UI and sync can adapt without
branching on identity.

### 2. Album-walk sync (`enumerateAllTracks`) — prune-safe by construction

Adds `MusicBackend.enumerateAllTracks(pageSize:) -> AsyncThrowingStream<CatalogPage<Track>>`
to the protocol (with a default impl that bridges `fetchTracks(offset:limit:)`
so Plex/Jellyfin are unaffected). `LibrarySyncEngine` prefers the stream via a
new `syncTracksStream` phase (drops in for `syncPages`).

The Subsonic implementation:

1. Pages `getAlbumList2(type=alphabeticalByArtist, size=500, offset=…)`. That
   ordering is deterministic across sync runs; `search3(query="")` is
   documented as unstable and would silently drop pages under mutation.
2. **Sums `songCount` for every album in a listing page BEFORE fetching any
   album details.** This means `expectedTotal` reported on each yielded page
   is a strict upper bound on `seen` for the entire duration of that listing
   page's walk — a network drop mid-album can never leave the engine with
   `seen >= total` (which would authorise the destructive prune).
3. Buffers songs from `getAlbum(id)` per album and yields `CatalogPage`s of
   `pageSize`. Dedup is by-id in the sync engine (`syncTracksStream` set), so
   a song appearing on multiple albums (compilations / "Best of"s) doesn't
   inflate seen counts.

`search3` remains as the flat `fetchTracks` implementation for completeness,
but never authorises a prune (its `CatalogPage.totalCount` is always `nil`).

### 3. Tri-mode auth with a stable-salt MD5 that discards the plaintext

`SubsonicCredentials` is a JSON envelope stored in the existing keychain
`token` slot (no `StoredSession` schema change):

- **`apiKey`** — OpenSubsonic API key. Preferred when advertised. Signing
  MUST omit the `u=` param; the spec is explicit that mixing `apiKey` + `u`
  is rejected.
- **`md5`** — Derive a fresh salt once, compute `t = MD5(password + salt)`,
  **discard the plaintext**. Only `(username, salt, t)` lives in the
  keychain. Two properties fall out of this:
  1. An attacker with keychain access can talk to *that server* but cannot
     replay the password anywhere else.
  2. Every subsequent Subsonic URL is byte-deterministic — the artwork cache
     doesn't thrash across launches.
- **`legacy`** — plaintext `p=`. Kept in the enum only; not implemented in
  v1 (adding it later is purely additive).

### 4. `SubsonicClient` — single signing / decoding / validation choke point

Every JSON call goes through `send<T:>` (typed payload) or `sendVoid`
(metadata-only). The envelope decoder validates `subsonic-response.status`
first, so a `failed` response with `error.code=40` is guaranteed to surface
as `MozzError.unauthorized`, not as a decode error further downstream.
`mapError` handles codes 40/41/42/43/44 → unauthorized, 50/60/20/30 →
unsupported, 70 → notFound, others → transport.

`SubsonicClient.validateBinaryResponse(statusCode:contentType:data:)` is the
single most important safety guard in the whole conformer. Subsonic serves
errors over HTTP 200 with a JSON / XML `subsonic-response` body. Without a
content-type gate a `.mp3` on disk can silently be an XML "Wrong username
or password" body, permanently corrupting the offline library. Callers
(streaming, downloads, artwork) MUST invoke it before writing to disk.

### 5. Selective transcoding (preserves gapless + quality)

`streamSource(for:options:)` inspects `track.format.container`/`codec`:
iOS-friendly formats (mp3, aac/m4a, mp4, alac, flac, wav, aiff) pass through
via `format=raw` for direct play. Everything else (opus, ogg, wma) transcodes
to `format=aac`, as does any explicit bitrate cap. Offline originals go via
`/download` (validated by content type on receipt).

### 6. Best-effort capability detection

`detectCapabilities`:
- `ping` is authoritative for "the chosen auth works". A `failed` envelope
  maps to a specific `MozzError`.
- `getOpenSubsonicExtensions` is best-effort — a `notFound` or
  `unsupported` from a classic Subsonic server flips `isOpenSubsonic=false`
  and does NOT surface as a detection failure. Lyrics and
  normalization-gain support are gated on the corresponding advertised
  extensions.

### 7. Multi-user server id

Two accounts on the same Navidrome instance have distinct favorites,
ratings, and play state, so Mozz must treat them as distinct catalogs.
`AppEnvironment.serverId(kind:baseURL:username:)` includes the normalized
username for `.subsonic` sessions (`"subsonic-<u>-<url>"`) while leaving the
Plex/Jellyfin id format unchanged.

### 8. Ergonomic signing on `HTTPClient`

Added `defaultQueryItems` to `HTTPClient`. `SubsonicClient` builds the
`(v, c, f, apiKey|u+t+s|u+p)` signing set once at init and hands it to the
client — every subsequent request auto-appends them, with endpoint items
winning on name collision. Also added `p`, `t`, `s`, `u` to
`SecretRedactor` so signed URLs never leak to logs / test fixtures.

## Test coverage (`swift test --filter MozzSubsonicTests`)

32 tests, all passing. Cover the required cases from the brief plus follow-up polish:

- **Signing (5)** — MD5 sends u+t+s + protocol trio; apiKey mode OMITS `u`;
  legacy mode sends `p`; MD5 derivation deterministic given the same salt;
  envelope JSON round-trips.
- **Mapper vs. fixtures (3)** — album+songs decode rich fields including
  numeric ids (via `SSAnyID`), musicBrainzId → mbid, replayGain trackGain
  → normalizationGain, userRating → rating, isFavorite from `starred`;
  artists index + favorite + MBID; MIME-to-codec covers common servers.
- **Envelope errors (3)** — `failed` envelope maps 40 → unauthorized;
  missing extensions endpoint gives `isOpenSubsonic=false` WITHOUT
  throwing; advertised extensions flip lyrics + normalization capabilities.
- **Binary validation (4)** — XML body rejected; JSON `failed` envelope
  mapped to `.unauthorized`; audio content types accepted; HTTP ≥400
  rejected.
- **Album walk (2)** — walk over 2 albums yields 5 tracks with
  expectedTotal=5; `search3` returns items but does NOT advertise a total.
- **Artwork determinism (2)** — two `SubsonicClient`s with the same creds
  produce byte-identical `getCoverArt` URLs; apiKey URLs omit `u=`.
- **Prune safety (1)** — a partial walk with a mid-walk transport error
  throws AND every page it yielded reports total strictly greater than
  seen-at-that-point (the derivable-total invariant).
- **Stream source decisions (6)** — FLAC / MP3 direct-play via `format=raw`;
  opus transcodes to aac; a bitrate cap forces transcode even for
  iOS-playable containers; `forceTranscode` always wins; unknown container
  transcodes conservatively.
- **Classic-server fallback (1)** — an HTTP 400 on
  `getOpenSubsonicExtensions` (a common classic-Subsonic failure mode) is
  ALSO absorbed and produces `isOpenSubsonic=false` without throwing.
- **Artists route (1)** — `getArtists` index gets flattened; second page
  returns empty so the sync engine stops.
- **URL normalization (4)** — bare host gets `http://`, trailing `/rest`
  stripped, whitespace trimmed, empty input returns nil.

## Deviations from the spec

None substantive. Two small refinements:

1. **`expectedTotal` is summed per LISTING PAGE, not per-album, AND becomes
   `nil` if any album's `songCount` is missing.** Summing per-listing-page
   makes it a strict upper bound on `seen` throughout that page's walk;
   dropping to `nil` when any album lacks a count makes the total
   unprovable rather than a floor, which propagates to
   `LibrarySyncEngine.phaseCompleted` (see next item) so a "songCount
   missing" server can never authorise prune.

2. **`LibrarySyncEngine.phaseCompleted` tightened to
   `guard let total = enumeration.reportedTotal else { return false }`.**
   The pre-existing fallback `!seen.isEmpty` treated a nil reported total
   as "complete", which was safe in practice for Plex/Jellyfin (both
   always populate `totalCount`) but would authorise an unsafe prune for
   a Subsonic backend that legitimately can't derive a total. All existing
   Plex/Jellyfin tests still pass; the tracks-prune resync test still
   fires exactly as before.

3. **`ServerCapabilities.serverProductType` is a `String?` (raw server
   type like `"navidrome"`)** rather than an enum, because new
   OpenSubsonic implementations appear regularly and enums here would
   require app updates for each one. Consumers can `contains` /
   `caseInsensitiveCompare` as needed.

## What I'd refine with more time

- **Playlist write-back.** `MusicBackend` has no mutation API today; adding
  `createPlaylist` / `updatePlaylist` / `deletePlaylist` would let the
  Subsonic backend drive real playlist edits (Subsonic API is happy to; the
  Mozz protocol just doesn't have the hooks yet).
- **Synced-lyrics UI.** `supportsSyncedLyrics` is gated correctly, but no
  lyric-fetch domain surface exists yet. `getLyricsBySongId` would slot in
  cleanly behind an optional `fetchLyrics(track:) -> LyricsDoc?` on
  `MusicBackend`.
- **Per-server transcode preferences.** Some Navidrome deployments serve
  DSD or high-bitrate FLAC that AVFoundation *can* play natively — the
  current allow-list is conservative. A user-toggleable "always request
  original" would help audiophiles.
- **Custom reverse-proxy headers.** A number of Navidrome deployments live
  behind Authelia / Cloudflare Access; adding `HTTPClient.defaultHeaders`
  passthrough from the login view would land that in a couple of lines.
- **Music-folder picker.** `musicFolderId` is threaded end-to-end but the
  login view doesn't yet prompt for it (defaults to "all folders" which is
  what most home users want). A `getMusicFolders` call + picker after
  successful `ping` would mirror Plex library selection.

## File map

New:
- `Sources/MozzSubsonic/SubsonicAuth.swift`
- `Sources/MozzSubsonic/SubsonicAuthenticator.swift`
- `Sources/MozzSubsonic/SubsonicClient.swift`
- `Sources/MozzSubsonic/SubsonicDTOs.swift`
- `Sources/MozzSubsonic/SubsonicMapper.swift`
- `Sources/MozzSubsonic/SubsonicBackend.swift`
- `Sources/MozzApp/Onboarding/SubsonicLoginView.swift`
- `Tests/MozzSubsonicTests/**` (test file + 7 recorded JSON fixtures)

Edited:
- `Package.swift` (product, target, MozzApp dep, test target)
- `Sources/MozzCore/BackendKind.swift` (`.subsonic`)
- `Sources/MozzCore/ServerCapabilities.swift` (product type + openSubsonic)
- `Sources/MozzCore/MusicBackend.swift` (bulk enumerator + default impl)
- `Sources/MozzDatabase/Records.swift` + `Migrations.swift` (v14)
- `Sources/MozzNetworking/HTTPClient.swift` (defaultQueryItems)
- `Sources/MozzNetworking/SecretRedactor.swift` (`p`, `t`, `s`, `u`)
- `Sources/MozzSync/LibrarySyncEngine.swift` (`syncTracksStream`)
- `Sources/MozzApp/AppEnvironment.swift` (buildBackend + serverId +
  makeBulkSyncBackend)
- `Sources/MozzApp/Onboarding/OnboardingView.swift` (third connect link)
- `Sources/MozzApp/Onboarding/SetupView.swift` (subtitle case)
