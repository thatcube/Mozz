# Mozz

**One app for your music, wherever it lives. Free forever. Open source.**

Mozz is a SwiftUI music client for iPhone and iPad that connects to the media
server you already run. Point it at **Plex**, **Jellyfin**, or a
**Subsonic / OpenSubsonic** server (tested against Navidrome) and it mirrors your
library onto the device, then lets you stream it or take it with you.

Streaming from your own server and offline playback of downloaded tracks are
both first-class here. Many people will stream everything and never download a
thing; others live on the subway with everything saved. Mozz is built for both,
equally — it is not a streaming app with an offline afterthought, and not a
download manager that happens to stream.

Mozz is licensed under **GPL-3.0** (see [`LICENSE`](LICENSE)).

---

## What it does

- **Your servers, one library.** Plex, Jellyfin, and Subsonic/OpenSubsonic sit
  behind a single `MusicBackend` abstraction, with per-server capability
  detection so each server exposes exactly what it supports.
- **Everything is local first.** Your catalog is synced into an on-device
  SQLite database that the whole UI reads from, so browsing and search stay fast
  even on a large library and work with the server unreachable.
- **Gapless playback.** An `AVQueuePlayer` engine with a real play queue,
  shuffle and repeat, volume normalization, and a graphic equalizer.
- **Offline downloads.** Save albums and tracks over a background transfer and
  play them with no network at all — lyrics included.
- **Lyrics.** Synced (karaoke-style) and plain lyrics, from your server first and
  LRCLIB as a fallback, cached and stored with your downloads, plus a
  full-screen immersive mode.
- **CarPlay.** Browse your whole library and control Now Playing from the car,
  driven by the same playback engine as the phone.
- **Now Playing that morphs.** A single view that expands from a docked island
  into the full-screen player, with drag-to-dismiss and a reorderable queue.
- **System integration.** Home and Lock Screen widgets, Handoff between devices,
  `mozz://` deep links, and iCloud Keychain sign-in that carries your server to
  your other devices.
- **Discovery.** On-device recommendations ("Mozz Weekly") and open metadata
  enrichment via MusicBrainz.

---

## Requirements

- iOS / iPadOS 17 or later (iPhone and iPad).
- A media server to connect to: Plex, Jellyfin, or a Subsonic / OpenSubsonic
  server (Navidrome is the QA'd target; other OpenSubsonic servers are
  best-effort).
- No account with anyone, no server of ours, no telemetry. Mozz talks only to
  your server (and, for lyrics/metadata, to LRCLIB and MusicBrainz).

---

## Features in depth

### Your library

Mozz enumerates your server's whole catalog in pages and mirrors it into a local
database — artists, albums, tracks, playlists, genres, favourites, and artwork
*references* (never the audio itself). The UI then reads only from that database,
so lists paginate instantly and search is full-text and diacritic-insensitive
as you type. Artwork is requested at the exact pixel size the screen needs, so
scrolling never pulls full-resolution images.

Sign in with the flow each backend expects: Plex PIN/OAuth with connection
discovery, Jellyfin Quick Connect (or username/password), and Subsonic token
auth. Plex's music section is resolved for you during sign-in.

### Playback

Playback is AVFoundation only. A single `AVQueuePlayer` is kept fed with
pre-created items so tracks cross boundaries without a load/teardown gap
(near-gapless). The queue is a pure, fully tested value type with repeat
(off / one / all) and a **balanced shuffle** that spreads artists out instead of
clumping them. Loudness normalization (ReplayGain / Sound Check style) is on by
default and applied per item where the gain is known. A 10-band ISO graphic
equalizer (31 Hz–16 kHz, ±12 dB) with presets and a global preamp is available
in Settings and applied through an audio-processing tap.

Now Playing metadata and artwork are published to the Lock Screen and Control
Center, and remote commands (play/pause/next/previous/seek) are wired for
headphones and hardware controls. The audio session keeps playing in the
background and handles interruptions and route changes (unplugging headphones
pauses).

### Offline downloads and offline playback

Downloads run on a background `URLSession`, so transfers survive the app being
suspended. Mozz saves the **original file**, records its state and size in the
database, and reports live per-track progress; `downloadAlbum` queues a whole
album at once. Because downloads are keyed to stable internal ids, a re-sync of
your library never orphans them.

At playback time an offline-first resolver checks for a downloaded file that
still exists and plays it directly from disk, never touching the network;
otherwise it falls back to streaming. Combined with the local catalog, browsing
and playback work fully in airplane mode.

### Lyrics

Mozz shows both time-synced lyrics — highlighting and auto-scrolling the current
line, with a small anticipation lead so a line lights up right as it's sung — and
plain lyrics. It looks to your server first (Plex, Jellyfin, or the OpenSubsonic
`songLyrics` extension) and falls back to [LRCLIB](https://lrclib.net) when the
server has none. Results are cached and saved alongside downloads so they are
available offline. A circuit breaker backs off on a bad or throttled connection
and is careful never to burn a permanent "no lyrics" verdict onto a track that
actually has them. A full-screen immersive mode hides the chrome for just the
words.

### CarPlay

Mozz brings the full library to CarPlay: recently played, playlists, albums,
artists, and a library tab holding songs, genres and your downloads. Albums and
playlists lead with a Shuffle row, tapping a song plays the list it came from
starting there, and Now Playing has an Up Next screen you can jump around in.

Browsing reads the on-device database rather than the network, so it stays
responsive and keeps working where there is no signal — for downloaded tracks the
whole session needs no connection at all. It shares the same playback engine and
queue as the phone, so what you start in the car and what you start in your hand
are the same session.

### Now Playing experience

There is one Now Playing view, not two. It morphs continuously between a compact
docked "island" above the tab bar and the full-screen player, so there is no
jarring present/dismiss. You can drag it away to dismiss, scrub with a seek bar,
open the up-next queue and reorder it in place, and jump from the player title
straight to the artist or album.

### Widgets and system integration

A WidgetKit extension renders Now Playing and recently played widgets for the
Home and Lock Screens. The app writes compact snapshots (and downsized artwork)
into a shared App Group and reloads the widget timelines, so the widgets render
instantly without reaching into the app's database. `mozz://` deep links open
straight to a tab, album, artist, playlist, genre, or one of the library
sections, and the same destinations are advertised as Handoff activities so you
can pick up on another device.

### Discovery and metadata

"Mozz Weekly" is an on-device, offline recommendation set that rediscovers music
already in your library — no server round-trip required. Open metadata enrichment
resolves MusicBrainz IDs (from your server's embedded ids first, then a
rate-limited MusicBrainz lookup) to sharpen radio, mixes, and shuffle. On-device
listening history feeds the recommenders and is the foundation for scrobbling.

### Ratings and favourites

Mozz unifies the two models servers use: Jellyfin/Subsonic favourites and Plex's
0–5 star ratings, surfaced as likes and ratings in the track menus and on the
Now Playing screen, and written back to the server where the capability exists.

---

## Architecture

The design thesis is simple: **the on-device database is the single source of
truth.** Backends sync your catalog into a GRDB/SQLite store with FTS5 search;
the UI reads only from that store; playback and downloads resolve URLs, never
bytes. This is what keeps a large library fast, makes offline automatic, and
makes adding a backend a new `MusicBackend` conformer rather than a rewrite.

Everything ships as one Swift package, `MozzKit`, with one small library per
concern and strict downward dependencies — the domain core and the backends never
import UI, and the backends never import the database. The iOS app target
(`App/Mozz`) links only the composed `MozzApp` product.

| Module | Responsibility |
|---|---|
| **MozzCore** | Pure domain models, the `MusicBackend` protocol, auth / capability / error types, URL resolution, and the Keychain credential store. No third-party dependencies. |
| **MozzNetworking** | Async `HTTPClient`, endpoint builder, URL normalization, retry/backoff, rate limiting, and a secret-redacting logger. |
| **MozzDatabase** | The GRDB + FTS5 source-of-truth store: schema/migrations, records, the read repository the UI binds to, the single write API sync uses, and the performance harness. |
| **MozzPlex** | `PlexBackend` — PIN/OAuth auth, connection discovery, DTOs/mapper, and signed request headers. |
| **MozzJellyfin** | `JellyfinBackend` — Quick Connect / password auth, DTOs, and mapper. |
| **MozzSubsonic** | `SubsonicBackend` — generic Subsonic / OpenSubsonic backend with MD5 token auth (Navidrome QA'd). |
| **MozzSync** | `LibrarySyncEngine` — mirrors a backend's catalog into the database, paged and off-main, with stable ids and pruning. |
| **MozzPlayback** | The gapless `AVQueuePlayer` engine, the pure `PlayQueue` (shuffle/repeat), the equalizer DSP, Now Playing / remote commands, and audio-session handling. |
| **MozzDownloads** | Background `URLSession` downloads, on-disk file store, download-state and storage accounting, and the offline-first track resolver. |
| **MozzRecommend** | On-device recommenders and the blender behind "Mozz Weekly"; network-free at its core. |
| **MozzEnrichment** | Open-metadata clients and orchestration: MusicBrainz IDs, LRCLIB lyrics, and the lyrics cache. |
| **MozzApp** | The SwiftUI feature layer (onboarding, browse, Now Playing, search, downloads, settings, widgets bridge) and the `AppEnvironment` composition root. |

Feature differences between servers are expressed through `ServerCapabilities`
(transcoding, original-file download, favourites, ratings, lyrics, synced lyrics,
normalization gain, progress reporting, OpenSubsonic/Plex-Pass state) detected
once per server. The UI and playback gate on those flags rather than branching on
which backend is connected, so a server that can't do something degrades
gracefully and a backend gains a feature just by reporting it.

For the full design record — schema, indexing, the sync pipeline, playback
internals, and measured performance numbers — see [`ARCHITECTURE.md`](ARCHITECTURE.md).

---

## Building and running

Mozz uses [XcodeGen](https://github.com/yonaskolb/XcodeGen); the `Mozz.xcodeproj`
is generated from [`project.yml`](project.yml) and is **gitignored**, so generate
it before opening the project in Xcode.

**Prerequisites**

- Xcode 16 or later.
- XcodeGen: `brew install xcodegen`.

**Generate the project and build**

```bash
tools/generate-project.sh          # produces Mozz.xcodeproj from project.yml
open Mozz.xcodeproj                 # or build from the command line:

tools/build-ios.sh                 # simulator compile check (no signing needed)
```

`tools/build-ios.sh` regenerates the project first, so it always reflects
`project.yml`. Override the destination with `MOZZ_DEST` if needed, for example
`MOZZ_DEST="generic/platform=iOS Simulator" tools/build-ios.sh`.

## Testing

The logic layers (domain, networking, database/search, sync, playback queue,
downloads/offline, recommendations, enrichment) are macOS-clean and unit-tested
off-device — no simulator required. iOS-only code is guarded behind `#if os(iOS)`,
and providers are tested against recorded JSON fixtures rather than a live server.

```bash
swift test                         # fast: all logic-layer tests on the host toolchain
tools/run-tests.sh                 # same, via the helper (adds --sim, --filter, etc.)
tools/run-tests.sh --sim           # run the suite on an iOS Simulator
```

> Running raw `swift`/`xcodebuild` inside a git worktree can trip SwiftPM's
> package resolution; the helper scripts handle this for you. If you invoke the
> tools directly, first run
> `export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"`.

---

## Project layout

```
App/            iOS app target (Mozz) and the WidgetKit extension (MozzWidget)
Sources/        the MozzKit package — one library per concern (see the table above)
Tests/          unit tests and recorded provider fixtures
docs/           architecture notes, ADRs, privacy, and research
project.yml     XcodeGen project definition (source of the generated .xcodeproj)
Package.swift   the MozzKit package graph
```

---

## Contributing

Issues and pull requests are welcome. The core is deliberately UI-free and
protocol-first, so the highest-leverage contributions are new backends (a single
`MusicBackend` conformer), capability coverage, and tests against recorded
fixtures. Please keep changes off the main thread and reads flowing only through
the database, in keeping with the architecture above.

## Privacy

Mozz has no backend of its own and collects nothing. It connects to your media
server and, for lyrics and metadata, to LRCLIB and MusicBrainz. See
[`docs/PRIVACY.md`](docs/PRIVACY.md).

## License

Mozz is free software licensed under the **GNU General Public License v3.0**, with
an additional permission under section 7 allowing distribution through Apple's App
Store despite its DRM and code-signing requirements. See [`LICENSE`](LICENSE) for
the full terms.

Mozz is not affiliated with or endorsed by Plex, Jellyfin, Navidrome, MusicBrainz,
or LRCLIB. All trademarks belong to their respective owners.
