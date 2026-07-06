# Mozz — Music App Research & Architecture Brief

> **What this is.** The synthesized research that founds Mozz: a **free-forever, open-source
> (GPL-3.0) music app for Plex AND Jellyfin**, iOS-first (tvOS later). It is the shared context
> for a 7-branch architecture bake-off (see §10) and a permanent reference.
>
> **How it was made.** 12 parallel research/audit agents (Claude Opus 4.8 max + Sonnet 5 max):
> 3 audited the existing Plozz tvOS client, 9 covered competitors, the Plex/Jellyfin APIs, Plex
> Pass restrictions, and the open-data ecosystem.
>
> **Read this first if you are building a Mozz foundation candidate.** It contains the product
> requirements, the API/auth facts you need, the reuse map, the feature bar, and the architecture
> the bake-off is testing.

---

## Table of contents
1. [Product vision & non-negotiables](#1-product-vision--non-negotiables)
2. [Positioning & competitive landscape](#2-positioning--competitive-landscape)
3. [Plex Pass & the free-tier question](#3-plex-pass--the-free-tier-question)
4. [Plex third-party API — auth, discovery, streaming, ToS](#4-plex-third-party-api--auth-discovery-streaming-tos)
5. [Jellyfin API — auth & music streaming](#5-jellyfin-api--auth--music-streaming)
6. [Open-data replication strategy](#6-open-data-replication-strategy)
7. [Plozz reuse audit (a code source, NOT the gold standard)](#7-plozz-reuse-audit-a-code-source-not-the-gold-standard)
8. [Feature bar & pitfalls to avoid](#8-feature-bar--pitfalls-to-avoid)
9. [Performance bar (mandatory)](#9-performance-bar-mandatory)
10. [Architecture decision & the 7-branch bake-off](#10-architecture-decision--the-7-branch-bake-off)
11. [Sources](#11-sources)

---

## 1. Product vision & non-negotiables

Mozz is the **first free, open-source, iOS-native music client that supports both Plex and Jellyfin**
equally well, with the reliability/polish of a premium app. It is a dedicated music app (not a video
app with music bolted on).

**Non-negotiables (v1):**
- **Both backends behind one abstraction** — Plex *and* Jellyfin. Adding a backend later (e.g.
  OpenSubsonic) must be one new conformer, not a rewrite.
- **Offline downloads** — download tracks/albums for offline and play them with networking disabled
  (airplane mode). This is a hard requirement, not a later phase. (Plexamp paywalls this; Mozz gives it free.)
- **Bulletproof background playback** + accurate lock-screen / Control Center now-playing + remote commands.
- **Gapless playback** (all common formats) and **loudness normalization** (ReplayGain/R128) done correctly.
- **Fast on large libraries** (target 100k+ tracks) — instant search, smooth scroll (see §9).
- **iOS 17 minimum**, SwiftUI, modern Swift concurrency. tvOS is a later target — keep platform-specific
  UI thin so shared packages can serve both.
- **Free forever, no IAP, no paywalls, no telemetry-by-default, no rug-pulls.** This is a core value
  proposition and a direct response to Plex's recent monetization (see §2/§3).

**Business/legal reality (good news):** building a third-party Plex client is explicitly permitted and
has shipping precedent; free-Plex users can stream music (incl. remotely) through Mozz; the only
Plex-Pass-gated music features are server-side extras Mozz can replicate with open data. Details in §3–§4.

---

## 2. Positioning & competitive landscape

**The whitespace:** *no free, open-source, iOS-native app supports both Plex and Jellyfin.*
- **Plexamp** — Plex's dedicated music app. Excellent, but **Plex-only**, closed-source, and paywalls
  downloads/EQ/lyrics/sonic-discovery behind Plex Pass. Free base app since 2023.
- **Finamp** — leading Jellyfin music app, free/OSS, but **Jellyfin-only**, and its polished redesign
  (incl. CarPlay) is stuck in **perpetual beta**; the stable App Store build is dated. **No CarPlay in stable.**
- **Amperfy** — the closest open-source iOS analog (GPLv3), but **Subsonic/Ampache only** (no Plex/Jellyfin),
  **no ListenBrainz**, and has real reliability issues (open battery-drain regression, CarPlay breakage,
  gapless took 3.5 years to fully land).
- **Symfonium** — the multi-backend leader (Plex+Jellyfin+Subsonic+…), sets the feature ceiling, but is
  **Android-only + paid** with no iOS plans.
- **Narjo** — the *one* iOS app doing multi-backend (Plex+Jellyfin+Subsonic+Emby) today. Ships nearly the
  whole wishlist (CarPlay, a real Watch app, widgets, synced lyrics, EQ, AudioMuse-AI, offline). But it's
  **closed-source, subscription/lifetime-monetized, and barely adopted (~22 reviews)**. → Feature parity
  alone won't differentiate Mozz; **free + open-source + reliability/polish + trust** is the moat.
- **Caldera Music** — the *original Plexamp developer* left Plex (2026) and shipped an audiophile player
  incl. a **native tvOS app** (Metal visualizer, multi-room). Track it as a tvOS competitor.

**Trust openings to exploit:** Plex tripled Lifetime Pass pricing (→ $749.99 on 2026-07-01), **removed
music from its main app** in 2025 (forcing everyone into a separate Plexamp — active user backlash), and
keeps adding paywalls. Mozz can be the stable, dedicated, won't-rug-pull, free music home for both ecosystems.

**Plexamp free vs. Plex Pass (so we know what "free" must match/beat):**
- *Free in Plexamp:* unlimited local + **remote** music streaming, gapless, Sweet Fades crossfade,
  loudness leveling, pre-caching, smart/genre stations, CarPlay, Android Auto, AirPlay, Chromecast, Siri,
  search, basic visualizers.
- *Plex Pass only:* **offline downloads**, 10-band EQ, bit-perfect/Pro Audio, **lyrics (LyricFind)**,
  Sonic-Analysis discovery (sonically-similar, Track/Album Radio, Mixes For You, Mix Builder, Sonic
  Adventure, Guest DJ, Sonic Sage), Autoplay, home-screen customization, headless.
- **Plexamp weak spots (Mozz wins):** no official Apple Watch app (only 3rd-party "WatchAmp"); no
  confirmed widgets/Live Activities; iPad UI is a scaled-up iPhone layout; downloads/EQ paywalled.

---

## 3. Plex Pass & the free-tier question

**Headline: a free-Plex user does NOT lose music *playback* through a third-party app like Mozz.**
- The infamous **"1-minute preview" wall was client-side in Plex's *own* apps only** (proven: it was a
  per-App-Store in-app purchase, tied to your Apple ID, not your Plex account). It **never applied to
  third-party API clients**, and Plex has removed it from its new apps.
- **Music is explicitly exempt from Plex's 2025 remote-video paywall.** Official Plex support wording:
  *"Music and photos content can be streamed for free."* So free-Plex users stream their full library
  **locally and remotely** through Mozz. (Plex Relay caps at 2 Mbps/stream — a non-issue for music; PMS
  transcodes down if needed.)

**What free Plex *does* lack are two SERVER-SIDE features** (gated on the *server admin's* Plex Pass, so
they affect any client, including Mozz):
1. **Sonic-Analysis discovery** — sonically-similar artists/albums/tracks, Track/Album Radio, Mixes For
   You. Requires the server admin's Plex Pass + a completed analysis pass; the data simply won't exist on
   a free server. (Also, Plex says these are "currently only available in Plexamp" — API exposure to
   third-party clients is **unverified**; treat as absent.)
2. **Automatic LyricFind lyrics** — a free server never fetches them.

**Both are replicable by Mozz with open data** (see §6), equally on Plex *and* Jellyfin — so Mozz's free
experience is strong regardless of backend or Pass.

**Capability detection (design implication):** Plex gates key off the *server admin's* subscription, not
the listening user's. So detect capabilities **per-server**, not per-user. You cannot cleanly "detect Plex
Pass" from a third-party client — probe the gated endpoints and treat empty/absent responses as "not
entitled," cache the result per server, and **grey out (don't hide)** unavailable features with a helpful
tooltip.

**⚠️ Watch item:** Plex has said 2026 enforcement will reach "third-party clients using the API." Music is
exempt *by content type* today, but that's policy, not a written third-party guarantee. **Stream from music
library item types**, and **verify empirically** (free server + remote + third-party client) before relying on it.

---

## 4. Plex third-party API — auth, discovery, streaming, ToS

**Allowed & precedented.** Plex's ToS explicitly permits client apps ("Interfacing Software"). There is now
an **official public OpenAPI** (2025, `developer.plex.tv` / `plexapi.dev`), plus the 10-year reference
implementation **`pkkid/python-plexapi`**. Shipping precedent on iOS: **Prism** (Plex music client; open-
sources its networking layer as **`lcharlick/PlexKit`**) and **Plezy** (Flutter Plex+Jellyfin client, on the
App Store). No API key or app registration — you self-generate `X-Plex-*` headers.

**Auth flow (PIN/OAuth against plex.tv):**
1. `POST https://plex.tv/api/v2/pins?strong=true` with `X-Plex-Client-Identifier`, `X-Plex-Product`,
   `Accept: application/json` → `{ id, code }`.
2. Open `https://app.plex.tv/auth#?clientID=<id>&code=<code>&context[device][product]=Mozz&forwardUrl=<deeplink>`
   in `ASWebAuthenticationSession`.
3. Poll `GET https://plex.tv/api/v2/pins/<id>` (~1s) until `authToken` is set; store token in Keychain.
4. Discover servers: `GET https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1` → each resource
   has a `connections[]` list (`uri`, `local`, `relay`, `protocol`).
5. Pick a connection: race `GET {uri}/identity` across connections; take the first success, preferring
   **local → remote → relay** and **https → http** (mirrors python-plexapi's `preferred_connections()`).
6. All PMS calls use the base URL + `X-Plex-Token` (header preferred) and `Accept: application/json` (else XML).

**Required client headers:** `X-Plex-Client-Identifier` (stable UUID per install, effectively mandatory —
persist in Keychain, don't regenerate), plus recommended `X-Plex-Product`, `X-Plex-Version`, `X-Plex-Platform`,
`X-Plex-Device`. No published rate limit, but PMS returns `429 (error 1003)` under load → **self-throttle,
cache, back off**.

**Browse music:** `GET {base}/library/sections` → section with `type="artist"`; then
`GET {base}/library/sections/<key>/all?type=8|9|10` (artists/albums/tracks) or walk
`/library/metadata/<ratingKey>/children`.

**Play a track (two paths):**
- **Direct play** (for AAC/MP3/ALAC/FLAC/etc. AVPlayer decodes): the track's `Media.Part.key` →
  `{base}{part.key}?X-Plex-Token=<token>` (add `download=1` to force the original file). Feed to `AVPlayer`.
- **Universal transcode/HLS** (lossless/incompatible/adaptive): `GET {base}/music/:/transcode/universal/start.m3u8?...`
  or `.../start.mp3` with `musicBitrate`, session id, `X-Plex-*`. AVPlayer consumes the HLS manifest.
- **iOS gotcha:** pass the token as a **query parameter** on media URLs — custom-header injection into
  `AVPlayer`/`AVURLAsset` HLS requests is unreliable across iOS versions/redirects. Prefer HTTPS; avoid logging full URLs.

**Report playback:** `POST /:/progress?key=<ratingKey>&identifier=com.plexapp.plugins.library&time=<ms>&state=playing|paused|stopped`.

**Auth wrinkle (2023):** all access — even LAN-only — now requires a signed-in plex.tv account. No anonymous local access.

**Branding:** cannot use "Plex" in the app name/domain or Plex iconography; "Mozz — works with Plex" is fine.
"Mozz" is a distinctive name, so this is safe. **Risk overall: low** (Prism/Plezy ship unimpeded).

---

## 5. Jellyfin API — auth & music streaming

Jellyfin is **fully free/open-source, no paywall** — every music API is available to all users.
Verified against the `jellyfin/jellyfin` server source.

**Auth:** **Quick Connect** (`/QuickConnect/Initiate` → user approves a code in their Jellyfin web UI →
poll `/QuickConnect/Connect`) or username/password (`/Users/AuthenticateByName`). Requests carry the
`X-Emby-Token` / `X-MediaBrowser-Token` header (Jellyfin's analog to `X-Plex-Token`) plus a device profile.
LAN auto-discovery via UDP is available; manual URL entry as fallback.

**Browse music:** `/Artists`, `/Items?IncludeItemTypes=MusicAlbum|Audio|Playlist`, `/MusicGenres`,
`/Playlists/{id}/Items`; favorites via `POST/DELETE /UserFavoriteItems/{id}`; ratings via `/UserItems/{id}/Rating`.

**Stream audio:** `GET /Audio/{id}/universal` with `DeviceId`, `MaxStreamingBitrate`, a `Container` direct-play
allow-list (`mp3,aac,m4a,flac,alac,wav,m4b`), `TranscodingContainer=ts`, `TranscodingProtocol=hls`,
`AudioCodec=aac`, `PlaySessionId`, `api_key`. Direct-play-vs-HLS-transcode is decided server-side from the
`Container` list — a deterministic URL, no `/PlaybackInfo` round-trip needed for audio.

**Lyrics:** `GET /Audio/{id}/Lyrics` (native since Jellyfin 10.9; supports synced LRC). Gate the synced-lyrics
UI on server version ≥ 10.9 via `/System/Info`.

**"Smart" features are basic** (verified in source): "Similar Items" = genre/tag match + random; "Instant Mix"
= same-genre random (capped 200); "Suggestions" = `OrderBy Random`. Jellyfin *does* ship a ListenBrainz-backed
**similar-artist** provider (MBID-keyed). **Loudness:** the server exposes `NormalizationGain` on `BaseItemDto`
(from ReplayGain/LUFS tags) — **the client must apply it** during playback.

**Reference apps:** Finamp (offline, gapless, ReplayGain, AudioMuse-AI integration); note Jellyfin's own
official iOS app (Swiftfin) **explicitly excludes music** — another reason Mozz exists.

---

## 6. Open-data replication strategy

Plex's real moat is server-side **Sonic Analysis** (Plex Pass, PMS-only, not portable). Jellyfin's smarts are
thin. **Mozz levels the field client-side with free open data — identically on both backends.** This is a core
differentiator and directly makes free-Plex ≈ Jellyfin ≈ Plex-Pass for most user-facing value.

| Gated / server feature | Free open replacement (client-side) | Notes |
|---|---|---|
| Synced + plain lyrics | **LrcLib** (`lrclib.net`, no API key; query by artist/title/album/duration) | Highest value / lowest effort. Works for both backends; Jellyfin already has an official LrcLib plugin. |
| Loudness leveling | Apply **ReplayGain/R128** client-side (Jellyfin exposes `NormalizationGain`; parse tags for Plex) | Watch the transition-glitch + over-correction bugs competitors hit. |
| Similar artists | **ListenBrainz Labs** similar-artists (MBID-keyed) | Same source Jellyfin uses; degrade gracefully when no MBID. |
| Similar tracks | **Last.fm `track.getSimilar`** (free) or ListenBrainz recording similarity | No auth needed for Last.fm read. |
| Track/Album Radio, Instant Mix | Jellyfin native (free); client-side genre-weighted radio for Plex | Guarantees a functional floor on both backends. |
| "Mixes For You" | **ListenBrainz** Troi "Weekly Jams/Exploration" playlists for opted-in users | `GET /1/user/{user}/playlists/createdfor` (public). |
| Scrobbling | Client-side **Last.fm** `track.scrobble` + **ListenBrainz** `submit-listens` | Do it in the client (Finamp/Amperfy/Symfonium lack ListenBrainz → a clean win). |
| "Year in Music" recap | Local play-history recap + **ListenBrainz** stats/Year-in-Music API | Plex has no native equivalent → a differentiator. |
| NL playlists (Sonic Sage) | BYO-key / small LLM → structured filters over the user's own library metadata | Portable; "smarts" are in the LLM + metadata, not Plex compute. |
| Artwork fallback | Deezer (artist), MusicBrainz / Cover Art Archive (album) | Plozz's `MetadataKit` already implements these keyless providers. |
| True acoustic analysis | **No free hosted API** (AcousticBrainz shut down 2022). Optionally detect a self-hosted **AudioMuse-AI** plugin on Jellyfin; else be honest + fall back to ListenBrainz. | Don't claim "sonic analysis" unless AudioMuse-AI is present. |

**Capability matrix (per connected server):** `{ backend, hasPlexPass?, jellyfinVersion, hasSyncedLyrics,
hasListenBrainzMbid, hasAudioMuse }` — populate opportunistically, cache, and drive all UI gating from it.

---

## 7. Plozz reuse audit (a code source, NOT the gold standard)

Plozz (`/Users/brandon/Development/Plozz`) is a mature Jellyfin/Plex **tvOS** client — a Swift Package
(one library per concern) + a thin XcodeGen app target. It has a working music layer that never touches
mpv (music is pure AVFoundation; mpv is video-only). **Treat Plozz as a source of reusable code and a
reference — not a template to copy wholesale. Critique it and only reuse what is genuinely good.** It was
built tvOS-first and video-first, with music added later; its music layer has real gaps (below).

**Reusable with little/no change (Foundation-only, UI-agnostic):**
- `CoreModels` — `MusicProvider` protocol, `MusicModels` (Artist/Album/Track/Playlist/Genre), `Lyrics`
  (LRC + Plex timed-JSON parsers), `AudioPlaybackRequest`/`PlaybackQuality`. **Note the shape:** music is a
  *separate optional* `MusicProvider` protocol (detected via `as? MusicProvider`), distinct from the video
  `MediaProvider`. A fresh design may prefer a unified, music-first backend abstraction.
- `ProviderJellyfin` + `ProviderPlex` music conformers — the stream-URL / direct-play-vs-transcode logic
  described in §4/§5 is already implemented and symmetric across backends. Strong reuse candidate.
- `CoreNetworking` — `HTTPClient`, `Endpoint`, URL normalization, secret-safe logger. Portable.
- `FeatureAuth` **logic** — Quick Connect, Plex Link/PIN, session state machine, Keychain stores (UI is tvOS).
- `MetadataKit` music paths — Deezer/MusicBrainz/CoverArtArchive artwork + `LRCLIBLyricsProvider`. Portable.
- `FeatureMusic/AudioPlaybackController` — an `AVQueuePlayer`-based engine with `MPNowPlayingInfoCenter` /
  `MPRemoteCommandCenter` / `AVAudioSession`, cross-platform-gated (no `#if os(tvOS)`). Reusable with ~5%
  iOS work (add interruption/route-change handling; relax the synced-only-lyrics filter; background-audio mode).

**Rebuild for iOS (tvOS focus-engine bound):** all `CoreUI` components + the SwiftUI views (Now Playing,
mini-player, scrubber, browse screens). Keep only `ArtworkImageCache` / color utilities.

**Drop entirely:** `EngineMPV`, `TopShelfKit`, mpv tooling, tvOS user-management entitlement.

**Known GAPS in Plozz's music layer (things a Plexamp-class app needs that Plozz lacks — do NOT assume they
exist):** real queue construction (its `queueContext` is a stub returning a single track), **gapless**
(single-item `AVQueuePlayer`), music favorites, track scrobble/progress reporting, Instant Mix/radio,
ReplayGain *application*, playlist editing, and **offline downloads (none — explicitly deferred)**. See Plozz's
`docs/music-library-proposal.md`.

**Build recipe (Plozz's, generalizes cleanly):** single multi-platform SPM package + XcodeGen app target,
`UIBackgroundModes:[audio]`, `TARGETED_DEVICE_FAMILY "1,2"`, fastlane-ready, **skip mpv**. Candidates may
diverge from this — it's a reference, not a mandate.

---

## 8. Feature bar & pitfalls to avoid

Evidence-ranked across Plexamp / Finamp / Amperfy / Symfonium / Narjo (GitHub reaction counts, App Store
reviews, forums).

**Tier 1 — table stakes (v1):** bulletproof **background playback**; **CarPlay** (day-one, *stable* — the
#1 most-wanted *and* most-broken feature industry-wide); reliable **offline downloads/sync** (a Mozz
requirement — free, unlike Plexamp); accurate lock-screen/now-playing; **gapless** (all formats); **loudness
normalization** done correctly; fast large-library search; true shuffle/repeat; server-synced favorites;
recently added/played; multi-server + multi-backend; a **modern, non-dated UI**.

**Tier 2 — strongly desired:** synced lyrics (LrcLib); **scrobbling to Last.fm + ListenBrainz**; EQ (free =
win); crossfade with real control; AirPlay 2; widgets; Siri/Shortcuts; smart/instant-mix radio; per-network
(Wi-Fi/cellular) quality; artist images/bios.

**Tier 3 — delighters:** a real **Apple Watch app** (Plexamp has none); casting (Chromecast/DLNA/Sonos);
cross-device remote control; NL playlist generation; "Year in Music" recap; spinning-vinyl now-playing visual;
**client-side compilation/Various-Artists/multi-disc/classical metadata fixing** (a 5-year unresolved
server-side pain point across both ecosystems — a real edge).

**Pitfalls that make users abandon an app (avoid these):** background playback silently stopping; broken
CarPlay after iOS updates; offline-sync failures; battery drain/overheat; dated/clunky UI; loudness/gapless
transition glitches; broken scrobbling; shuffle that isn't random; slow search / janky large-library scroll;
and **vendor-overreach backlash** (paywalling core features, social features, silent removal) — Mozz answers
this by being free/open + QA-disciplined.

---

## 9. Performance bar (mandatory)

"Extreme performance" is a first-class goal. Every foundation candidate is built and measured against a
**large synthetic library (~100k tracks / ~10k albums)** and must report:
- cold app launch → first interactive frame;
- **scroll FPS** on the 100k-track / 10k-album lists (must stay smooth, no hitching);
- **search latency** (type → results) — target **sub-100 ms**;
- memory footprint while browsing + during playback;
- time-to-first-audio after tapping play; **gapless** transition correctness;
- **offline**: download an album, enable airplane mode, play it back.

**Enablers (strongly recommended for all candidates):** a **local indexed store as the source of truth**
(SQLite/GRDB with **FTS5** preferred), **DB-level pagination + indexed sorts** (never load the whole library
into memory), **all sync/parsing off the main thread** (actors/background contexts), **list virtualization**,
and **downsampled, disk-cached artwork** (a documented scroll-jank + OOM-crash source). Store choice is
per-thesis; a candidate using SwiftData must *prove* it meets this bar at 100k rows (its scale limits are documented).

---

## 10. Architecture decision & the 7-branch bake-off

We do **not** assume Plozz's architecture is the base. Seven autopilot branches compete; the winner becomes
Mozz's foundation (and a candidate to back-port music into Plozz — so keep the design clean, not Plozz-coupled).

**Frontrunner thesis — Candidate B (offline-first, normalized local DB as single source of truth):** a fresh
music-centric backend abstraction (not Plozz's video-shaped `MediaProvider`); the library **catalog** (not the
audio files) is synced from the server into an on-device **GRDB/SQLite + FTS5** database; the UI reads from the
DB; providers sync into it; capability detection and offline are first-class; sync/parsing run off the main
thread. This directly attacks the field's #1 pain point (large-library performance + offline). *It is the
a-priori frontrunner for long-term + extreme performance.*

**The 7 branches (all: Plex+Jellyfin, iOS 17, shared deliverable + offline + performance bar + `ARCHITECTURE.md` + tests):**

*Frontrunner cohort — 4× Candidate B, identical spec, one per model (a clean model-vs-model comparison):*
`mozz-b-opus48` (Opus 4.8 max), `mozz-b-sonnet5` (Sonnet 5 max), `mozz-b-opus47` (Opus 4.7 max),
`mozz-b-opus46` (Opus 4.6 max).

*Wildcard cohort — other theses, all Opus 4.8 max, in case they surprise us:*
- **A `mozz-arch-reuse`** — extend Plozz's proven layers fast (critique, don't cargo-cult; must build offline downloads — Plozz has none). The ship-fast baseline.
- **C `mozz-arch-modern-native`** — SwiftData + actor-isolated engines + Swift 6 strict concurrency (must prove SwiftData meets the perf bar, or fall back to GRDB/Core Data).
- **D `mozz-arch-unidirectional`** — TCA / unidirectional store with provider+playback effect clients; deterministic + highly testable.

**Shared deliverable per branch:** a runnable iOS-17 app that signs into Jellyfin **or** Plex, browses
artists/albums/tracks, **plays a track** (background audio + lock-screen + basic queue), **downloads for
offline and plays in airplane mode**, behind one backend abstraction; plus `ARCHITECTURE.md` (design,
trade-offs, Plex+Jellyfin + offline + capability handling, honest reuse-vs-rebuild notes, self-assessment)
and tests (backend abstraction, playback/queue, download/offline).

**Evaluation (winner):** performance bar (first) · offline download + airplane-mode playback (required) ·
correctness on both backends · architecture clarity/testability · large-library readiness · capability
detection/graceful degradation · extensibility to the Tier-1 bar + tvOS · code quality · suitability to
share back into Plozz.

---

## 11. Sources

Primary/official sources verified during research (see the session's agent reports for full citations):
- **Plex:** `support.plex.tv` (remote-playback requirements & the music exemption; sonic-analysis-music;
  automatic-lyrics-from-lyricfind; Plex Pass feature overview; local-network authentication), `plex.tv/blog`
  (important-2025-plex-updates "So Long, Mobile Unlock Fee"; new-lifetime-plex-pass-pricing; Free Bird / Super
  Sonic), Plex ToS + trademark guidelines, `developer.plex.tv` / `plexapi.dev`, `pkkid/python-plexapi`,
  `lcharlick/PlexKit`.
- **Jellyfin:** `jellyfin/jellyfin` server source (Instant Mix / similar-items / suggestions providers;
  `NormalizationGain`; LyricsController), `jellyfin.org` docs, `jellyfin/Swiftfin` (music explicitly unsupported),
  `jellyfin/jellyfin-plugin-lrclib`.
- **Open data:** `lrclib.net` (`lrclib/lrclib`), ListenBrainz (`listenbrainz.readthedocs.io`,
  `metabrainz/troi-recommendation-playground`), Last.fm API, MusicBrainz / Cover Art Archive, `MTG/essentia`,
  AcousticBrainz shutdown notice, `NeptuneHub/AudioMuse-AI`.
- **Competitors:** Plexamp (App Store + Plex docs), `UnicornsOnLSD/finamp`, `BLeeEZ/amperfy`, `jeffvli/feishin`,
  Symfonium (`symfonium.app`), Narjo (`narjomusic.com`), Caldera Music (`caldera.homes/music`), Navidrome apps
  directory, OpenSubsonic API (`opensubsonic/open-subsonic-api`).
- **Plozz reuse:** audit of `/Users/brandon/Development/Plozz` (`Sources/CoreModels`, `ProviderJellyfin`,
  `ProviderPlex`, `CoreNetworking`, `FeatureAuth`, `MetadataKit`, `FeatureMusic`, `Package.swift`, `project.yml`).

*Note: some Plex marketing pages are JS-rendered and were corroborated via official support docs + reputable
secondary sources. The remote-music exemption for third-party clients is inferred from content-type-based
wording and should be verified empirically. Pricing/policy reflect mid-2026 and may change.*
