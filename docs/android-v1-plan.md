# Mozz for Android — v1 plan

Decided with Brandon, 2026-08-30. This file is the durable record; it exists so
the plan survives a context reset. Nothing here is built yet.

## What v1 is

A beautiful, working Mozz player on a Pixel 9 Pro Fold: link a Plex account,
pick libraries, sync the catalog, browse albums, open Liked Songs, and listen —
with background playback, a notification/lock-screen transport, and a layout
that adapts when the device unfolds.

Not in v1: Jellyfin and Subsonic sign-in, downloads/offline, EQ, lyrics,
device pairing, continuity, history sync, widgets, Android Auto. All of those
are core capabilities already; they are later phases, not rewrites.

## Decisions

| Question | Decision | Why |
|---|---|---|
| Code location | `Mozz/clients/android`, same monorepo | Matches `clients/desktop`; core + client land in one commit |
| Swift ↔ Kotlin | Hand-written JNI shim over the existing C ABI | ADR-0014 §"swift-java versus plain JNI" |
| Audio | Media3 / ExoPlayer | Gapless, MediaSession, audio focus, download cache later, Android Auto later |
| First backend | Plex | `plexPin` / `plexPinCheck` browser-link flow, instant auth, instant sync |
| Design | Mozz design language, Android motion | Monochrome per `mozz-design-refs/REDESIGN-PLAN.md`; ripples, predictive back, M3 motion curves |
| Layout | Adaptive from day one | Fold is the primary device; iPad/foldable-iPhone is a parallel iOS track |
| Distribution | Play Store, automated via fastlane `supply` | Same tool the iOS release already uses |
| Package name | `com.brando.mozz` | Permanent once uploaded; appears in the Play Store URL and nowhere else users look |
| Networking | The core keeps its own HTTP. No Kotlin networking code | Settled by measurement — [ADR-0015](adr/ADR-0015-android-networking.md) |

## The networking question, settled

`libFoundationNetworking.so` has libcurl and BoringSSL statically linked inside
it, and reads Android's own trust store. HTTPS works from the core on device —
four real hosts, TLS, a 2 MB body. So the Kotlin layer never touches HTTP, and
nothing is vendored. Written up in
[ADR-0015](adr/ADR-0015-android-networking.md), including the
first-run false negative that nearly sent this the other way.

One gap it opens: Foundation's curl trusts the **system** CA store only, so a
self-hosted server with a self-signed certificate cannot be reached and no
Android-side trust config will change it. Fine for v1 against Plex; needs an
answer before Jellyfin and Subsonic sign-in ship.

## Phases

### Phase 0 — prove the boundary (no UI) — **done**
1. ~~Local toolchain~~ — SDK, NDK r27d, Swift 6.3.3 Android SDK, all pinned.
2. ~~HTTPS gate~~ — `mozz_ffi_probe_https` + gate 7 in the harness.
3. ~~ADR-0015~~ — written; the core keeps its own HTTP.

Also added: `spike/android-ffi/build-local.sh`, which cross-compiles on a Mac and
runs the whole battery on a plugged-in phone in one command. 7 of 7 gates pass on
arm64 Android 36.

### Phase 1 — the shim and the payload — **done**
4. ~~`libmozzjni.so`~~ — `core/src/main/cpp/mozz_jni.c`. The boundary deals in
   `ByteArray`, not `jstring`: JNI's modified UTF-8 would corrupt any
   astral-plane character in a library.
5. ~~Gradle staging~~ — `buildSwiftCore` + `stageSwiftCore` in
   `core/build.gradle.kts`. The Android ABIs are derived from the Swift
   architectures actually staged, so the two cannot drift.
6. ~~Kotlin `MozzCore`~~ — coroutine wrapper, `Dispatchers.IO`, one file
   (`MozzNative.kt`) that knows the core is native.

Verified on an arm64 Android 36 device: both instrumented tests pass, and the
app installs, launches, opens a library through the shim and renders the core's
answer.

One defect worth remembering: `libMozzFFI.so` had no `DT_SONAME`, so anything
linking it recorded the *absolute build-machine path* as its dependency and
failed to load on the phone. The core's link now sets `-soname`.

### Phase 2 — the data layer — **built; waiting on a real server**
7. ~~Kotlin `MozzServer`~~ — `connect`, `plexPin`, `plexPinCheck`, `attach`,
   `attachForSync`, `libraries`, `sync` (as a `Flow`), `streamURL`, `artworkURL`,
   plus `MozzLibrary` for the browse commands.
8. ~~Credential storage~~ — `SecretStore`, AES-256-GCM with the key in the
   AndroidKeyStore. Not `EncryptedSharedPreferences`: that library is deprecated,
   and this is ~80 lines with no dependency.
9. Artwork via Coil — not started; needs a synced library to be worth wiring.

Seven instrumented tests cover the typed layer against an empty library. What is
*not* proven is the shape of a populated response, which needs a real Plex
server — the next thing to do.

One bug this found, worth keeping in mind for the rest of the port: `plexPinCheck`
answers `{"url": null}` while the user has not approved yet. C# tolerated the
missing fields; kotlinx.serialization requires them unless they default. Any
wire type that models a *pending* state needs defaults, not required fields.

### Phase 3 — playback — **built, untested**
10. ~~`MozzPlaybackService`~~ — Media3 `MediaSessionService`, audio focus and
    becoming-noisy handled, foreground service declared.
11. ~~`PlayerController`~~ — resolves `streamURL` for a screen's worth of queue
    up front (a gap between tracks is exactly what near-gapless must not have),
    drops tracks whose URL will not resolve rather than leaving a hole.
12. ~~`recordPlayEvent`~~ on auto-advance, so history matches iOS.

Shuffle and repeat are not wired yet. Nothing here has made a sound: it needs a
synced library, which needs a signed-in server.

### Phase 4 — the UI — **started early, out of order**

Onboarding runs ahead of playback because nothing downstream can be tested
without a signed-in server. Built so far: the Mozz theme (monochrome, one
crimson action, light and dark), the brand mark transcribed to a vector
drawable, and the sign-in → Plex link → library picker → sync → home path, with
the adaptive list/detail scaffold in place from the first screen.

### Phase 4 (continued) — the rest of the UI
13. Compose + Navigation 3, `WindowSizeClass`-driven adaptive scaffold from the
    first screen: single pane folded, list/detail two-pane unfolded.
14. Screens: onboarding → Plex link → library picker → sync progress → Albums →
    Album detail → **Liked Songs** (`likedTracks`) → Player → Queue.
15. Design pass against `mozz-design-refs/REDESIGN-PLAN.md`: monochrome,
    typography and whitespace carry the identity, one meaningful accent on the
    primary action. Port the player's visual language from
    `Sources/MozzApp/NowPlaying/`.

Exit: it is pleasant to use as a daily player.

### Phase 5 — ship it
16. Release signing, app bundle, `versionCode` from CI.
17. GitHub Actions: build `.so` + AAB, upload via fastlane `supply` to the Play
    internal testing track.
    **Blocker to schedule early:** Google requires the *first* bundle to be
    uploaded by hand in the Play Console before the API will accept uploads, and
    a Play Console account (one-time $25) plus a service-account JSON key.

## Parallel track, not part of this plan

Brandon wants adaptive layout on iOS too — iPad today, a foldable iPhone
expected shortly. That is work in `Sources/MozzApp`, sharing the *design*
thinking with Android but none of the code. It gets its own plan.

## Open items deliberately deferred

- Jellyfin and Subsonic sign-in screens (core support already exists)
- Downloads / offline (`MozzDownloads` is in the core; needs a storage policy)
- EQ and volume normalization — whether Media3 `AudioProcessor`s can match the
  iOS DSP, or whether miniaudio comes over from desktop
- Pairing, continuity and history sync — proven on Android by the spike, unbuilt
- Android Auto, widgets, Wear
- **Stripping the payload.** The debug APK is ~277 MB for one ABI, almost all of
  it unstripped Swift runtime and — since the Facade started reaching the audio
  engine — a Rust decoder stack Android never calls, because Media3 does the
  playing. It has to come down long before anyone installs it: strip the
  `.so`s, and check what `android.bundle` splits can do with them.
  (swift-testing and XCTest are already gone — they were being staged into the
  APK by a wildcard copy, and nothing in the shipped graph needed them.)
- **Artwork.** Coil is chosen but unwired; `artworkURL` is ready in the core.
- **Shuffle and repeat**, which the core has semantics for and the player does
  not yet use.
- **The brand mark on the other platforms.** `docs/brand/mozz_logo.svg` now holds
  the new consistent face and Android is generated from it via
  `tools/svg-to-vector-drawable.py`; iOS, macOS and the desktop app still carry
  the old one in their own asset catalogues.
