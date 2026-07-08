# Subsonic backend — architecture notes

Branch-only. Not for `main`. Summarizes the design of the generic
`BackendKind.subsonic` `MusicBackend` (OpenSubsonic/Subsonic, QA'd to Navidrome;
Gonic/Ampache/LMS best-effort). Mirrors the `MozzJellyfin` module's shape.

## Module layout (`Sources/MozzSubsonic`)

| File | Responsibility |
|------|----------------|
| `SubsonicDTOs.swift` | Decodable mirrors of the JSON + the `subsonic-response` envelope + a string-or-number `SubsonicID`. |
| `SubsonicAuth.swift` | `SubsonicCredential` envelope (tri-mode), MD5/salt via CryptoKit, `SubsonicURLNormalizer`. |
| `SubsonicClient.swift` | The single choke point: signs every request, decodes the envelope, maps error codes, validates binary responses. |
| `SubsonicMapper.swift` | Pure DTO → domain mapping (no I/O; exhaustively unit-testable). |
| `SubsonicBackend.swift` | The `MusicBackend` conformer: catalog enumeration, playback/download URLs, writes, capabilities. |
| `SubsonicAuthenticator.swift` | Verifies a credential with `ping` and produces an `AuthenticatedSession`. |

## Key design choices

1. **Generic enum, runtime product display.** One `BackendKind.subsonic`, not
   `navidrome`. `ping` carries the concrete product (`type`) and version, which
   flow into `ServerCapabilities.serverProduct` / `serverVersion` (mirrored in a
   new DB `CapabilitiesRecord` column via migration `v14`) and the login/setup
   copy. The protocol is one thing; the server behind it is detected.

2. **Album-walk is the authoritative, prune-safe enumeration (items 2–4).**
   `enumerateAllTracks(pageSize:)` walks `getAlbumList2(type=alphabeticalByArtist,
   size=500, offset)` to exhaustion for a stable, ordered album set, then
   `getAlbum(id)` per album, deduplicating songs by id. The **expected total** is
   `Σ album.songCount` — but *only when every album reports a count*; a single
   missing count makes it `nil`. That total is the completeness proof the sync
   engine requires before pruning. `search3(query="")` is a **quick-start
   fast-path only**: `fetchTracks` always returns `totalCount == nil`, so it can
   never authorize a prune (a prune deletes unseen tracks *and their downloaded
   files*). **Pagination is driven off the RAW server window length, never the
   post-filter id count.** `albumListPage` filters malformed empty-id albums, but
   the Phase-1 loop advances `offset` and decides termination using the raw page
   length so that an empty-id album inside a *full* window can never truncate the
   walk — which would otherwise drop every later album and, because the derived
   total would then match the truncated set, green-light exactly the destructive
   prune this design exists to prevent. (Mirrors the flat pager's "only a
   genuinely empty page is terminal" rule; regression-tested.)

3. **Additive optional bulk enumerator on `MusicBackend`.**
   `enumerateAllTracks(pageSize:) -> AsyncThrowingStream<CatalogPage<Track>, any
   Error>?` with a default of `nil`. `LibrarySyncEngine` prefers it for the
   unbounded tracks phase and sets `requiresReportedTotalForPrune = true` on that
   path, so a `nil` total means "not provably complete → do not prune." Plex and
   Jellyfin return `nil` and are completely unaffected (they keep the flat-pager
   "non-empty ⇒ complete" default, which is safe because their full enumeration
   is authoritative).

4. **Credential envelope in the existing token slot (item 5).**
   `SubsonicCredential{mode, username, secret, salt?}` is JSON-encoded into the
   keychain `token` string — **no `StoredSession` schema change**. `apiKey` mode
   is preferred (OpenSubsonic `apiKeyAuthentication`) and **omits the `u`
   param**. `md5` mode generates a **stable** salt once at login, stores
   `t = MD5(password + salt)`, and **discards the plaintext password** — no
   reusable secret at rest, and deterministic URLs. `legacy` cleartext is modeled
   but not produced by login (deferred past v1).

5. **Single signing/decoding/validation choke point (item 6).** `SubsonicClient`
   attaches `v`, `c`, `f=json` + the credential's signing items to *every*
   request through a new `HTTPClient.defaultQueryItems`, and reuses the *same*
   signed items to build media/artwork/download URLs (so they are signed
   identically). It decodes the `subsonic-response` envelope — **errors arrive
   over HTTP 200** with `status=failed` + `error.code` — and maps 40/44/50 →
   `.unauthorized`, 70 → `.notFound`, everything else → `.unsupported(message)`.
   Binary endpoints are validated by HTTP status **and** content-type, so an
   XML/JSON/HTML error body is **never** written to disk as audio.

6. **Selective transcoding preserves gapless + quality (item 7).** Direct-play
   (`format=raw`) for iOS-friendly containers (mp3/aac/m4a/alac/flac/wav/aiff/
   caf); transcode to `aac` only for unsupported containers (opus/ogg/wma or
   unknown) or when a bitrate cap is requested. Offline originals go through
   `/download` (content-type validated).

7. **Deterministic artwork URLs (item 8).** Because the salt/apiKey is stable,
   `getCoverArt` URLs are byte-identical across launches, so the artwork cache
   (keyed on the resolved URL) doesn't thrash. Covered by a test asserting two
   independent backend instances produce the same URL.

8. **Multi-user server id (item 9).** `AppEnvironment.serverId` folds the
   normalized username into the Subsonic id (`subsonic-{username}-{baseURL}`) so
   two accounts on the same server don't collide. Plex/Jellyfin keep the historic
   `kind-baseURL` form.

9. **Best-effort capabilities (item 10).** `ping` is authoritative;
   `getOpenSubsonicExtensions` is best-effort — a 404 means "classic profile,"
   **not** a detection failure (guarded by `try?` and only attempted when the
   `openSubsonic` handshake flag is set). `star` → favorites, `setRating` →
   ratings, `songLyrics` extension → lyrics, `replayGain` (OpenSubsonic) →
   normalization gain.

10. **musicFolder scoping seam (item 11).** `musicFolderId` is stored in the
    generic `ServerConnection.musicSectionID` slot and applied to catalog
    requests. No picker UI in v1 — the seam is wired and tested.

11. **Secret redaction (item 12).** `SecretRedactor` now redacts `u`, `p`, `t`,
    `s` before any Subsonic logging/fixtures.

## Deviations from the spec (and why)

- **`enumerateAllTracks` returns an Optional stream** (`…?`) rather than a
  non-optional with a default flat-pager fallback. Returning `nil` is the
  cleanest way to say "this backend has no bulk enumerator"; the engine's
  branch (`if let stream = backend.enumerateAllTracks(...)`) then falls back to
  the existing `fetchTracks` pager. This keeps Plex/Jellyfin byte-for-byte
  unchanged and avoids every backend having to implement a passthrough.

- **Error-code mapping simplified.** Rather than mapping 41/42/43 to distinct
  cases, all non-auth/non-notFound codes become `.unsupported(message)` carrying
  the server's own message. `MozzError` has no finer-grained case that would
  change caller behavior, and preserving the server message is more useful than
  an invented category. Tests assert this exact mapping.

- **`SubsonicClient.send` is `internal`, not `public`.** Its return type is the
  internal envelope DTO. The public surface is the backend/authenticator; tests
  reach `send` via `@testable import`. `fetchBinary`/`mediaURL`/`validateBinary`/
  `mapError` stay public (they traffic only in public types).

- **`/rest/{name}.view` path.** The `.view` suffix is the historically safest
  form accepted by every Subsonic/OpenSubsonic server (some older servers 404 a
  bare `/rest/{name}`).

## Things I'd refine with more time

- **The album-walk fetches `getAlbum` sequentially.** Correct and memory-bounded,
  but on a large library the round-trips dominate. A bounded-concurrency window
  (e.g. 4–8 in-flight `getAlbum` calls, reordered back into album order) would
  cut wall-clock time substantially while preserving stable output.

- **Double album-list traversal.** `fetchAlbums` (albums phase) and
  `enumerateAllTracks` (tracks phase) each walk `getAlbumList2`. They could share
  a single cached album enumeration per sync run. Left separate for clarity and
  because the phases run somewhat independently in the engine.

- **`musicFolder` picker.** The scoping is wired end-to-end but there's no UI to
  choose a folder yet (mirrors where Plex/Jellyfin started). A small picker in
  the login/settings flow is the natural next step.

- **API-key acquisition.** v1 takes an API key the user pastes in. A future
  refinement could add the OpenSubsonic token-exchange flow where servers support
  minting a key from a password.

## Out of v1 scope (clean seams left, nothing half-built)

Playlist write-back (no `MusicBackend` mutation API), synced-lyrics UI (no lyric
fetch/domain/UI path exists — `supportsSyncedLyrics` is hard-false), custom
reverse-proxy headers, and legacy-cleartext servers.
