# Mozz Desktop

Mozz for Windows, macOS and Linux. Same library, same history, same taste
profile as the phone — because it is the same core.

## What this actually is

The music logic is not reimplemented here. `Sources/` is Swift, compiled to a
native shared library (`MozzFFI.dll` / `libMozzFFI.dylib` / `libMozzFFI.so`) and
driven over a C ABI: the database, the Plex/Jellyfin/Subsonic clients, sync,
search, recommendations and listening history are all the code the iOS app runs.
This project is a window, a queue and an audio engine.

Two files know that:

- `Core/MozzCore.cs` — the only file that knows the core is native.
- `Audio/MiniAudioEngine.cs` — the only file that knows which library moves samples.

Everything else is ordinary C#.

## Getting a build

Every push builds both platforms. Download from the **Desktop app** workflow run:

```
gh run list --workflow "Desktop app" --limit 1
gh run download <run-id> -n mozz-desktop-windows-x64
```

or from the run's page in the browser under **Artifacts**.

- `mozz-desktop-windows-x64` — unzip, run `Mozz.Desktop.exe`. Nothing to
  install: .NET, the Swift runtime and FFmpeg are all in the zip.
- `mozz-desktop-macos-arm64` — unzip and run. macOS provides the Swift runtime;
  FFmpeg comes from `brew install ffmpeg`.

## Building it yourself

```bash
# The Swift core. On this repo you need the git flag first.
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"
swift build -c release --product MozzFFI

# The app.
export DOTNET_ROOT="$HOME/.dotnet" PATH="$HOME/.dotnet:$PATH"
cd clients/desktop
dotnet build -c Debug
cp ../../.build/release/libMozzFFI.dylib bin/Debug/net10.0/   # or .so / .dll
dotnet run -c Debug --no-build
```

Tests (they are beside the app, not inside it — see the note in the test
project's `.csproj`):

```bash
dotnet test clients/desktop-tests/Mozz.Desktop.Tests.csproj
```

### Environment variables

| Variable | Effect |
|---|---|
| `MOZZ_LIBRARY` | Use a specific SQLite library file instead of the one in app support. Handy for pointing at a seeded demo database. |
| `MOZZ_FFMPEG` | Use a specific ffmpeg binary. Otherwise: beside the app, then `PATH`. |

## Where things live

```
Core/MozzCore.cs      The C ABI bridge — one JSON command dispatcher.
Core/MozzServer.cs    Typed sign-in / sync / stream-URL layer over it.
Core/SecretStore.cs   DPAPI, Keychain, or a 0600 file. See below.
Core/Models.cs        Wire types.
Audio/                The playback engine. Has its own README.
ViewModels/           MVVM, CommunityToolkit source generators.
Views/                Avalonia XAML.
```

## Credentials

The Swift core returns an auth token from `connect` and then forgets it. It
does not persist secrets, and there is no cross-platform keychain in it.

That is deliberate. Secret storage is one of the few genuinely irreducible
platform differences — Windows has DPAPI keyed to the logged-in account, macOS
has the Keychain, Linux has libsecret, Android has the Keystore — and a
"portable" store would be the worst of all of them. The host already links those
APIs. So the core does protocol work, the host does platform work, and a token
crosses between them exactly twice: out of `connect`, back in via `attach`.

`Core/SecretStore.cs` is that host half. On Linux it falls back to a file with
owner-only permissions, which is **not encrypted at rest** — the same protection
an SSH private key gets, and no more. `ISecretStore.Description` says so in
words the settings screen can show a user.

## Known gaps

- **Windows SMTC and macOS `MPNowPlayingInfoCenter`** are seams, not
  implementations — media keys and the OS now-playing card do nothing yet.
- **ReplayGain tags are not read** during sync; the engine applies gain it is
  given, and nothing gives it any.
- **Audible output on Windows is unverified by a human.** The pipeline, DSP and
  decoders run green on the Windows CI leg and the whole bundle is proven to
  load and query standalone, but nobody has yet put headphones on a Windows box.
- **No iPad-class adaptive layout** shared with the phone app.
