# Contributing to Mozz

Thanks for your interest in Mozz! This document covers how the code is laid out, how
to build the app, how to run the tests, and how releases work. For the user-facing
overview see [`README.md`](README.md); for the deeper design rationale see
[`ARCHITECTURE.md`](ARCHITECTURE.md) and the notes and decision records under
[`docs/`](docs).

Issues and pull requests are welcome. The music core is deliberately UI-free and
protocol-first, so the highest-leverage contributions are new server backends,
broader capability coverage, and tests against recorded fixtures.

## Prerequisites

- **macOS** with a recent **Xcode**. The app targets **iOS 17**, but it compiles
  SwiftUI's iOS 26 "Liquid Glass" APIs behind `#available(iOS 26.0, *)` checks, so
  you need an Xcode with the iOS 26 SDK to build the app target. CI uses `macos-26`.
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew install xcodegen`) —
  `Mozz.xcodeproj` is **generated** from [`project.yml`](project.yml) and is
  gitignored, so it must be generated before you open Xcode.
- Swift Package Manager (bundled with Xcode) for the `MozzKit` package.

> If a Swift Package resolve fails with a "cannot use bare repository" error (some
> environments inject a stricter `safe.bareRepository` setting), export the fix
> first — the helper scripts do this for you:
>
> ```bash
> export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"
> ```

## Generating the Xcode project

`Mozz.xcodeproj` is generated and not committed. Generate (or regenerate) it after
changing `project.yml` or adding, removing, or renaming files:

```bash
tools/generate-project.sh
```

The wrapper runs XcodeGen **and** bakes in the version and build numbers, so prefer
it over a bare `xcodegen generate`:

- `CFBundleShortVersionString` (marketing version) is CalVer, set in `project.yml`.
- `CFBundleVersion` (build number) is derived from the git commit count, so it
  auto-increments with history.

## Building and running

Helper scripts live in [`tools/`](tools):

```bash
tools/build-ios.sh          # simulator compile check (no signing); regenerates the project first
tools/run-ios.sh            # build, install, and launch on an iOS Simulator
tools/run-carplay-sim.sh    # build/install/launch on a Simulator with CarPlay enabled
tools/deploy-device.sh      # signed build, install, and launch on a connected iPhone/iPad
```

`tools/build-ios.sh` regenerates the project first, so it always reflects
`project.yml`. Override the build destination with `MOZZ_DEST`, e.g.:

```bash
MOZZ_DEST="generic/platform=iOS Simulator" tools/build-ios.sh
```

`tools/deploy-device.sh` installs a **per-branch** app by default — a unique bundle
id (`com.thatcube.Mozz.<branch>`) and display name (`Mozz <branch>`) — so multiple
feature branches can coexist on one device without overwriting each other. Useful
flags: `--build-only` (compile, don't install), `--no-build` (reinstall the last
build), `--ipad` / `--iphone` / `--all`, and `--regen`. Set `MOZZ_WIDGETS=1` (and
`main` does this automatically) to build the canonical `com.thatcube.Mozz` app with
the widget extension. Device builds need your own signing team; simulator builds need
none.

## Running the tests

The logic layers are macOS-clean and run without booting a simulator, which makes for
a fast inner loop. iOS-only code is guarded behind `#if os(iOS)`, and the server
backends are tested against recorded JSON fixtures rather than a live server.

```bash
swift test                  # all logic-layer tests on the host toolchain
swift test --parallel       # the same, in parallel (what CI runs)
tools/run-tests.sh          # the same via the helper (sets the git flag for you)
tools/run-tests.sh --sim    # run the suite on an iOS Simulator instead
tools/run-tests.sh --filter <name>   # pass-through filter (host mode)
```

Every non-UI module (backends, database/search, sync, playback queue, downloads,
recommendations, enrichment, history, continuity) has a matching test target under
[`Tests/`](Tests). Language-neutral golden fixtures in [`spec/`](spec) are checked by
the Swift suite and by the other platforms against the same bytes, so cross-device
behaviour (such as the continuity queue hash) can't silently drift.

## Architecture

The design thesis is simple: **the on-device database is the single source of
truth.** Backends sync your catalog into a local SQLite store (GRDB, with FTS5
search); the UI reads only from that store; playback and downloads resolve URLs,
never bytes. That is what keeps a large library fast, makes offline automatic, and
makes adding a backend a new protocol conformer rather than a rewrite.

Everything ships as one Swift package, `MozzKit`, with one library per concern and
strict downward dependencies — the domain core and the backends never import UI, and
the backends never import the database. The iOS app target (`App/Mozz`) links only
the composed `MozzApp` product.

| Module | Responsibility |
|---|---|
| **MozzCore** | Domain models, the `MusicBackend` protocol, auth / capability / error types, URL resolution, Keychain store. No third-party dependencies. |
| **MozzNetworking** | Async `HTTPClient`, endpoint builder, URL normalization, retry/backoff, rate limiting, secret-redacting logger. |
| **MozzDatabase** | The GRDB + FTS5 source-of-truth store: migrations, records, the read repository the UI binds to, the single write API sync uses. |
| **MozzPlex** | `PlexBackend` — PIN/OAuth auth, connection discovery, DTOs/mapper, signed request headers. |
| **MozzJellyfin** | `JellyfinBackend` — Quick Connect / password auth, DTOs, mapper. |
| **MozzSubsonic** | `SubsonicBackend` — Subsonic / OpenSubsonic with MD5 token and API-key auth (Navidrome QA'd). |
| **MozzSync** | Mirrors a backend's catalog into the database, paged and off-main, with stable ids and pruning. |
| **MozzPlayback** | The near-gapless `AVQueuePlayer` engine, the pure `PlayQueue`, equalizer DSP, Now Playing / remote commands, audio-session handling. |
| **MozzDownloads** | Background `URLSession` downloads, on-disk file store, storage accounting, the download-aware track resolver. |
| **MozzHistory** | The append-only listening log (plays, skips, partials) behind the taste profile that personalizes recommendations. |
| **MozzContinuity** | Cross-device "continue here" playback checkpoints. |
| **MozzRecommend** | On-device recommenders and the blender behind "Mozz Weekly"; network-free at its core. |
| **MozzEnrichment** | Optional open-metadata clients: MusicBrainz IDs, ListenBrainz similarity, LRCLIB lyrics, and the lyrics cache. |
| **MozzFFI** | A C-ABI shared library that exposes the Swift core to the non-Apple desktop client. |
| **MozzApp** | The SwiftUI feature layer (onboarding, Home, Library, Search, Siri, CarPlay, Now Playing, downloads, settings, widgets bridge) and the `AppEnvironment` composition root. |

Differences between servers are expressed through capability flags (transcoding,
original-file download, favourites, ratings, lyrics, synced lyrics, normalization
gain, progress reporting) detected once per server. The UI and playback gate on those
flags rather than branching on which backend is connected, so a server that can't do
something degrades gracefully and a backend gains a feature just by reporting it.

For the full design record — schema, indexing, the sync pipeline, playback internals,
and measured performance — see [`ARCHITECTURE.md`](ARCHITECTURE.md) and the decision
records in [`docs/adr`](docs/adr).

### Guidelines

- Keep work off the main thread, and let reads flow only through the database.
- A new backend is a single `MusicBackend` conformer plus fixtures — please don't
  reach into the database or the UI from it.
- A feature is supported on every backend or it isn't shipped; prefer capability
  flags over per-backend branching.

## The desktop client

[`clients/desktop`](clients/desktop) is **Mozz Desktop** for Windows, macOS, and
Linux — an Avalonia/C# shell and audio engine driven by the same Swift core over the
C ABI in `MozzFFI`, so the library, sync, search, recommendations, and history are
the exact code the iOS app runs. `tools/build-macos-app.sh` packages a real macOS
`.app`; see [`clients/desktop/README.md`](clients/desktop/README.md) for building on
all three platforms. CI builds every platform on each push (the **Desktop app**
workflow).

## Project layout

```
App/            iOS app target (Mozz) and the WidgetKit extension (MozzWidget)
Sources/        the MozzKit package — one library per concern (see the table above)
Tests/          unit tests and recorded provider fixtures
clients/        the cross-platform desktop client (Windows, macOS, Linux)
spec/           language-neutral golden fixtures shared across platforms
docs/           architecture notes, ADRs, privacy, and research
fastlane/       TestFlight and App Store lanes
project.yml     XcodeGen project definition (source of the generated .xcodeproj)
Package.swift   the MozzKit package graph
```

## Releases

iOS releases go through [fastlane](https://fastlane.tools) with an App Store Connect
API key (no Apple ID password, no 2FA prompt). Lanes are `build`, `beta`, and
`release`; `fastlane beta --env fastlane` builds and uploads to TestFlight.
Credentials come from a gitignored `.env.fastlane` — copy
[`.env.fastlane.example`](.env.fastlane.example) and fill it in; neither it nor the
`.p8` key it points at is ever committed. See [`fastlane/README.md`](fastlane/README.md)
for the full process, including the one-time TestFlight bootstrap and the demo account
App Review needs.

## License

By contributing, you agree that your contributions are licensed under the project's
**GPL-3.0** license (with the App Store distribution permission noted in
[`LICENSE`](LICENSE)).
