# Mozz

**One app for your music, wherever it lives. Free forever. Open source.**

Mozz is a SwiftUI music client for iPhone and iPad that connects to the media
server you already run. Point it at **Plex**, **Jellyfin**, or a
**Subsonic / OpenSubsonic** server (tested against Navidrome) and it mirrors your
library onto the device, then lets you stream it or take it with you.

Streaming from your own server and offline playback of downloaded tracks are both
first-class here. Many people will stream everything and never download a thing;
others live on the subway with everything saved. Mozz is built for both, equally.

Licensed under **GPL-3.0** (see [`LICENSE`](LICENSE)).

---

## What it does

**Your servers, one library.** Plex, Jellyfin, and Subsonic/OpenSubsonic sit
behind a single `MusicBackend` abstraction. Sign in the way each expects — Plex
PIN/OAuth with connection discovery, Jellyfin Quick Connect or password, Subsonic
MD5 token or OpenSubsonic API key.

**The catalog lives on-device.** Your library is mirrored into a local SQLite
database that the whole UI reads from — artists, albums, tracks, playlists,
genres, favourites, and artwork *references*, never the audio. Lists paginate
instantly, search is full-text and diacritic-insensitive as you type, and
browsing works with the server unreachable.

**Near-gapless playback.** One `AVQueuePlayer` kept fed with pre-created items so
tracks cross boundaries without a load gap. The queue is a pure, fully tested
value type with repeat and a **balanced shuffle** that spreads artists out
instead of clumping them. Loudness normalization is on by default; a 10-band ISO
equalizer (31 Hz–16 kHz, ±12 dB) with presets is available in Settings.

**Offline downloads.** Transfers run on a background `URLSession` and survive the
app being suspended. Mozz saves the original file and keys it to stable internal
ids, so re-syncing your library never orphans a download. At playback time a
downloaded file is played straight from disk without touching the network.

**Lyrics.** Time-synced, highlighting and auto-scrolling the current line, or
plain — from your server first and [LRCLIB](https://lrclib.net) as a fallback,
cached and saved alongside downloads. A full-screen mode hides the chrome for
just the words.

**Siri and HomePod.** Ask for a song, album, artist, playlist, genre, liked
songs, or a mix. That includes from a HomePod, which has no apps of its own and
forwards the request to your iPhone to play and AirPlay back; the same handler
serves the Siri button, CarPlay, and Shortcuts. Plays started in the app are
donated, so Siri learns to reach your library from a plain "play music".

**CarPlay.** Home and Library tabs mirroring the phone's layout, with row
artwork, a Shuffle row leading long lists, and an Up Next screen. Browsing reads
the on-device database, so it stays responsive where signal is poor, and
downloaded tracks stay playable when the server is unreachable. There is no
CarPlay search by design — Apple's audio templates don't allow
`CPSearchTemplate`, so Siri is the search path in the car.

**Now Playing that morphs.** One view, not two: it morphs continuously between a
docked island above the tab bar and the full-screen player, so there is no
jarring present/dismiss. Drag to dismiss, scrub, reorder the up-next queue in
place, or jump from the title to the artist or album.

**Widgets and system integration.** Now Playing and recently played widgets
render from compact snapshots in a shared App Group, without reaching into the
app's database. `mozz://` deep links open straight to a tab, album, artist,
playlist, genre, or library section, and the same destinations are advertised as
Handoff activities. Sign-in travels between devices through the iCloud Keychain.

**Discovery and metadata.** "Mozz Weekly" rediscovers music already in your
library, on-device. Optional enrichment resolves MusicBrainz IDs and ListenBrainz
similarity to sharpen radio and mixes; turn it off and local genre-based
recommendations still work.

**Ratings and favourites.** Jellyfin/Subsonic favourites and Plex's 0–5 star
ratings are unified as likes and ratings, and written back where the server
supports it.

---

## Requirements

- iOS / iPadOS 17 or later (iPhone and iPad).
- A media server: Plex, Jellyfin, or Subsonic / OpenSubsonic (Navidrome is the
  QA'd target; other OpenSubsonic servers are best-effort).
- No Mozz account, no server of ours, no telemetry. Mozz talks to your media
  server, to Plex sign-in/discovery when you use Plex, and — only when you enable
  them — to LRCLIB, MusicBrainz, and ListenBrainz.

---

## Architecture

The design thesis is simple: **the on-device database is the single source of
truth.** Backends sync your catalog into a GRDB/SQLite store with FTS5 search;
the UI reads only from that store; playback and downloads resolve URLs, never
bytes. That is what keeps a large library fast, makes offline automatic, and
makes adding a backend a new `MusicBackend` conformer rather than a rewrite.

Everything ships as one Swift package, `MozzKit`, with one library per concern and
strict downward dependencies — the domain core and the backends never import UI,
and the backends never import the database. The iOS app target (`App/Mozz`) links
only the composed `MozzApp` product.

| Module | Responsibility |
|---|---|
| **MozzCore** | Domain models, the `MusicBackend` protocol, auth / capability / error types, URL resolution, Keychain store. No third-party dependencies. |
| **MozzNetworking** | Async `HTTPClient`, endpoint builder, URL normalization, retry/backoff, rate limiting, secret-redacting logger. |
| **MozzDatabase** | The GRDB + FTS5 source-of-truth store: migrations, records, the read repository the UI binds to, the single write API sync uses. |
| **MozzPlex** | `PlexBackend` — PIN/OAuth auth, connection discovery, DTOs/mapper, signed request headers. |
| **MozzJellyfin** | `JellyfinBackend` — Quick Connect / password auth, DTOs, mapper. |
| **MozzSubsonic** | `SubsonicBackend` — Subsonic / OpenSubsonic with MD5 token and API-key auth (Navidrome QA'd). |
| **MozzSync** | `LibrarySyncEngine` — mirrors a backend's catalog into the database, paged and off-main, with stable ids and pruning. |
| **MozzPlayback** | The near-gapless `AVQueuePlayer` engine, the pure `PlayQueue`, equalizer DSP, Now Playing / remote commands, audio-session handling. |
| **MozzDownloads** | Background `URLSession` downloads, on-disk file store, storage accounting, the download-aware track resolver. |
| **MozzRecommend** | On-device recommenders and the blender behind "Mozz Weekly"; network-free at its core. |
| **MozzEnrichment** | Open-metadata clients: MusicBrainz IDs, ListenBrainz similarity, LRCLIB lyrics, and the lyrics cache. |
| **MozzApp** | The SwiftUI feature layer (onboarding, Home, Library, Search, Siri, CarPlay, Now Playing, downloads, settings, widgets bridge) and the `AppEnvironment` composition root. |

Differences between servers are expressed through `ServerCapabilities`
(transcoding, original-file download, favourites, ratings, lyrics, synced lyrics,
normalization gain, progress reporting) detected once per server. The UI and
playback gate on those flags rather than branching on which backend is connected,
so a server that can't do something degrades gracefully and a backend gains a
feature just by reporting it.

For the full design record — schema, indexing, the sync pipeline, playback
internals, and measured performance — see [`ARCHITECTURE.md`](ARCHITECTURE.md).

---

## Building and running

Mozz uses [XcodeGen](https://github.com/yonaskolb/XcodeGen): `Mozz.xcodeproj` is
generated from [`project.yml`](project.yml) and is **gitignored**, so generate it
before opening Xcode.

You need XcodeGen (`brew install xcodegen`) and an Xcode with the iOS 26 SDK
(currently the beta), because the code compiles SwiftUI's iOS 26 Liquid Glass
APIs behind availability checks. The deployment target stays at iOS 17.

```bash
tools/generate-project.sh     # produces Mozz.xcodeproj from project.yml
tools/build-ios.sh            # simulator compile check (no signing)
tools/run-ios.sh              # build, install, and launch on a Simulator
tools/run-carplay-sim.sh      # the CarPlay simulator flow
tools/deploy-device.sh        # signed device build (--build-only to skip install)
```

`tools/build-ios.sh` regenerates the project first, so it always reflects
`project.yml`. Override the destination with `MOZZ_DEST`.

Releases go through fastlane — `fastlane beta` builds and uploads to TestFlight
(lanes: `build`, `beta`, `release`). Credentials come from a gitignored
`.env.fastlane`; copy [`.env.fastlane.example`](.env.fastlane.example) and fill
it in. See [`fastlane/README.md`](fastlane/README.md).

## Testing

The logic layers (domain, networking, database/search, sync, playback queue,
downloads, recommendations, enrichment) are macOS-clean and unit-tested
off-device — no simulator required. iOS-only code is guarded behind
`#if os(iOS)`, and providers are tested against recorded JSON fixtures rather
than a live server.

```bash
swift test                    # all logic-layer tests on the host toolchain
tools/run-tests.sh            # the same, via the helper (--filter, --sim)
tools/run-tests.sh --sim      # run the suite on an iOS Simulator
```

> Running raw `swift`/`xcodebuild` inside a git worktree can trip SwiftPM's
> package resolution; the helper scripts handle it. Invoking the tools directly,
> first `export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"`.

---

## Project layout

```
App/            iOS app target (Mozz) and the WidgetKit extension (MozzWidget)
Sources/        the MozzKit package — one library per concern (see the table above)
Tests/          unit tests and recorded provider fixtures
docs/           architecture notes, ADRs, privacy, and research
fastlane/       TestFlight and App Store lanes
project.yml     XcodeGen project definition (source of the generated .xcodeproj)
Package.swift   the MozzKit package graph
```

## Contributing

Issues and pull requests are welcome. The core is deliberately UI-free and
protocol-first, so the highest-leverage contributions are new backends (a single
`MusicBackend` conformer), capability coverage, and tests against recorded
fixtures. Please keep work off the main thread and reads flowing only through the
database, in keeping with the architecture above.

## Privacy

Mozz has no backend of its own and collects nothing. It connects to your media
server, to Plex sign-in/discovery when you use Plex, and, when enabled, to
LRCLIB, MusicBrainz, and ListenBrainz. See [`docs/PRIVACY.md`](docs/PRIVACY.md).

## License

Mozz is free software licensed under the **GNU General Public License v3.0**, with
an additional permission under section 7 allowing distribution through Apple's App
Store despite its DRM and code-signing requirements. See [`LICENSE`](LICENSE) for
the full terms.

Mozz is not affiliated with or endorsed by Plex, Jellyfin, Navidrome,
Subsonic/OpenSubsonic, MusicBrainz, ListenBrainz, or LRCLIB. All trademarks belong
to their respective owners.
