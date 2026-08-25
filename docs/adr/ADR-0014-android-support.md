# ADR-0014 — Android: the core cross-compiles; what an app still needs

Status: **Accepted** (spike proven green in CI — cross-compile, on-device run and
all six gates; a shippable app still needs the packaging in "What remains").

The Android counterpart to the Windows FFI spike, and the second proof that
ADR-0011, ADR-0012 and ADR-0013's "put it in the shared core" bet holds off
Apple. Windows established that the platform-free core builds and runs on another
desktop OS. Android is the one that matters commercially — it is a phone, it is a
different CPU from the build host, and it runs on Bionic rather than glibc — so
it is the harder and more important of the two.

## Context

Three of the last four ADRs deliberately push logic *down* into the
platform-free Swift core — history sync (0011), the relay (0012) and device
pairing (0013) are all written once, in Swift, so that a Windows or Android
client is a UI over the same engine rather than a reimplementation. That bet is
only worth making if the core genuinely compiles and runs on those platforms.
Windows was the first evidence. This ADR records the second: an honest attempt to
cross-compile the whole FFI graph for Android, load it on a real Android
userspace, and drive the same gate battery — FTS5 search, HPKE pairing,
byte-identical continuity hashes — that the Windows and iOS runs use.

The specific worries going in, from the research, were concrete: GRDB links the
OS's SQLite through a `systemLibrary` target, and Android's system SQLite is both
unlinkable by policy and frequently built without FTS5 — the one feature Mozz
search cannot live without. swift-crypto gates parts of its surface on platform
primitives, and HPKE living in the shared core (ADR-0013) depends on it working.
And a cross-compile to arm64 exercises far more of the toolchain than a
same-CPU Windows build does.

## Findings

### The core cross-compiles for Android with zero source changes

Both `aarch64-unknown-linux-android` (arm64-v8a, every modern phone) and
`x86_64-unknown-linux-android` (the emulator), built `-c release`, with **no
changes to any file under `Sources/`.**

This is the headline, and it is not luck. The Windows spike found six Apple-only
leaks in the "portable" core — the `import Security` in `KeychainCredentialStore`,
the App Groups URL in `WidgetSnapshot`, the `os.Logger` privacy interpolation,
`URLSessionConfiguration.waitsForConnectivity`, and two more — and every one of
them was fixed with a capability guard (`#if canImport(Security)`,
`#if canImport(os)`) rather than an OS name (`#if os(Windows)`). A guard phrased
as "is this API present" is automatically correct for the *next* platform that
also lacks the API. Android lacks all the same ones, so the day the Windows leaks
were sealed, Android's were too. The spike is the evidence that writing the
guards that way — which cost nothing at the time — bought a second platform for
free.

Windows found six defects; Android found none in the source. What Android needs
is link integration, described next.

### SQLite still has to be compiled from the amalgamation, and FTS5 is why

Unchanged from Windows, and for the same reason, so the workflow does the same
thing: it compiles the SQLite amalgamation with an explicit feature list (FTS5,
snapshot, preupdate-hook, column-metadata, STAT4, RTREE, JSON1, threadsafe,
DQS=0) and archives it straight into `libMozzFFI.so`. GRDB's `GRDBSQLite` is a
`systemLibrary` target; Android *ships* a `libsqlite3.so` but it is a private
platform library the NDK will not let an app link, and the copy behind the NDK
omits FTS5. Building it ourselves is the only way to guarantee the feature, and
baking it in static (the linked `.so` exports 294 `sqlite3_*` symbols with none
left undefined) means the shipped `.so` carries its own SQLite with no runtime
dependency to satisfy.

The probe confirms it on-device rather than trusting the build flags:
`mozz_ffi_probe` actually runs `CREATE VIRTUAL TABLE … USING fts5` and reports
`fts5CreateSucceeded`.

### swift-crypto's HPKE works on Android — ADR-0013 holds

The pairing gate passes: `Curve25519_SHA256_ChachaPoly` seals and round-trips,
and rejects the wrong recipient, on Android. This was a genuine open risk —
swift-crypto contains HPKE but has historically gated pieces of its API on
platform availability — and it resolves in favour of the ADR-0013 decision. One
pairing implementation, in the shared core, for every platform; Android does not
need its own.

### Continuity hashes are byte-identical with iOS

Four of four `spec/continuity` fixtures hash identically on Android to the values
the Swift/iOS implementation produces. Cross-device resume (ADR-0010) between an
Apple device and an Android peer will agree on the queue hash, which is the whole
point of specifying it in `spec/` rather than in each app.

### The link needs two adjustments, both recorded where they bite

1. **A nested static-library search path.** The SDK keeps Foundation's networking
   archives one directory deeper than the driver searches
   (`swift_static-<arch>/android`). Without that `-L`, the FFI product fails to
   link with `unable to find library -l_CFURLSessionInterface` — a message that
   names a symbol and not the missing directory, so it points nowhere near its
   own cause. One added search path fixes it.

2. **Foundation networking's libcurl backend is present but unfed.** The static
   `lib_CFURLSessionInterface.a` wants ~26 libcurl symbols and the Android SDK
   ships no libcurl. This does *not* break the spike: the final `.so` binds the
   **dynamic** `libFoundationNetworking.so`, which depends on `libz`, not curl,
   so `libMozzFFI.so` links with zero undefined curl symbols and the gates —
   which do database, crypto and hashing, not HTTPS — all run. But it is a real
   limit, flagged rather than buried: a production Android app that makes HTTPS
   calls *through Foundation* would have to supply a libcurl or route networking
   another way. See remaining work.

### `--static-swift-stdlib` is not standalone on Android

On Apple and Windows that flag folds the Swift runtime into the artifact. On
Android it does not: the `.so` still lists the Swift Android runtime
(`libswiftCore.so`, `libFoundation*`, `libdispatch.so`, …) and the NDK's
`libc++_shared.so` as `DT_NEEDED`. Nothing is wrong — that is how the Android SDK
is built — but it means an app ships those ~28 `.so` files in `jniLibs/<abi>/`
alongside `libMozzFFI.so`. The emulator job assembles exactly this payload to run
the harness, so the workflow doubles as the manifest of what an APK must carry.

## The toolchain, pinned

| Piece | Value |
| --- | --- |
| Swift Android SDK | `swift-6.3.3-RELEASE_android.artifactbundle`, installed with `swift sdk install <url> --checksum d160cc3206dd1886dae3fef2337af5e25ec034692cd0ec225721c56cc69da7f5` |
| NDK | r27d (27.3.13750724); the SDK's `setup-android-sdk.sh` refuses anything below r27 |
| Android API level | 28 (the `…-android28` triples) — arm64-v8a and x86_64 |
| Host | Works on macOS (cross-compile + inspect) and on Linux (the `swift:6.3.3` image is what CI uses) |

The SDK is a *cross-compilation* SDK: it installs on an Apple-silicon Mac and
produces arm64 Android objects there. What a Mac cannot do is run an accelerated
x86_64 Android emulator, which is why the numbers below come from CI.

## Numbers

Measured by the same `PerformanceHarness` the iOS app ships, at 100k tracks, so
the columns are directly comparable. Android is the x86_64 emulator on a GitHub
KVM runner.

| metric | iOS (iPhone 17 Pro Max) | Windows x64 | Android (x86_64 emulator) |
|---|---|---|---|
| search p50 / p95 | 7.9 / 15.7 ms | 12.6 / 33.6 ms | 10.5 / 16.2 ms |
| cold open + count | 66.4 ms | 12.3 ms | 5.5 ms |
| FTS5 / HPKE / continuity | pass / pass / 4-of-4 | pass / pass / 4-of-4 | pass / pass / 4-of-4 |

A cloud emulator is a *floor*, not a phone: it shares a virtualised host CPU and
has no GPU, so the steady-state figures are conservative — search p95 lands just
behind iOS hardware and comfortably ahead of the Windows runner, exactly the
"same order of magnitude" the spike set out to show. Read the cold-open row with
care: at 5.5 ms it *beats* both other platforms, but that is an artefact, not a
phone-beating result. The GitHub KVM host has a fast x86_64 core and warm page
cache, while the iOS 66.4 ms includes real first-open cost on a mobile SoC. The
honest takeaway is steady-state search, which is the number a user feels; cold
open only proves the path works, not that Android is quicker than an iPhone. The
native macOS control job runs the identical harness and passes, which isolates
any Android failure from a bug in the facade or the harness itself.

For the record the emulator reported SQLite `3.51.0` (the amalgamation we
compiled, not Android's private system copy), `hasFTS5: true`,
`fts5CreateSucceeded: true`, an HPKE `Curve25519_SHA256_ChachaPoly` round-trip
that also rejects the wrong recipient, and 4-of-4 continuity fixtures
byte-identical with iOS — the same facade behaviour the other platforms show.

## swift-java versus plain JNI

**Recommendation: a small hand-written JNI shim over the existing C ABI. Do not
adopt swift-java for this.**

The architecture already made the decision that makes this easy. Mozz does not
expose a wide Swift API to its hosts; it exposes *one coarse-grained C ABI* —
`mozz_session_open` / `mozz_session_call` / `mozz_session_close`, with every
request and response a JSON string, plus `mozz_ffi_free_string` for ownership.
Bridging that to Kotlin is a handful of `dlsym` lookups and `GetStringUTFChars` /
`NewStringUTF` calls in a C file of maybe a hundred lines — the on-device harness
in this spike is essentially that shim already, minus the JNI glue.

swift-java exists to generate rich, fine-grained interop between Swift types and
Java/Kotlin types. That is real value for a project that wants to call a broad
Swift surface directly from Kotlin — and it is precisely the surface Mozz
deliberately does not have. Adopting it would add a code-generation step and a
build-graph dependency, and couple the Android build to swift-java's own
maturation, to marshal a single JSON call the C ABI already marshals. It is worth
revisiting only if Mozz ever decides to expose Swift objects to Kotlin directly,
which every ADR so far has been at pains to avoid. For a JSON-over-C-ABI facade,
plain JNI is simpler, has fewer moving parts, and is already 90% written.

## What still stands between this and a shippable Android app

The core is proven. The app is not, and this ADR should not be read as claiming
otherwise. In rough order:

1. **A JNI shim + Kotlin binding** around the C ABI (small; see above).
2. **Packaging the runtime.** The ~28 Swift Android `.so`s and `libc++_shared.so`
   into `jniLibs/arm64-v8a/` (and `x86_64/` for the emulator), driven from
   Gradle. The emulator job's payload step is the reference list.
3. **A networking decision for HTTPS.** Either supply a libcurl to Foundation's
   Android backend, or keep the core's HTTP boundary abstract and let the Kotlin
   layer make the calls (OkHttp) while the core stays pure compute. This is the
   one genuinely open design question the spike surfaced, and it wants its own
   short ADR.
4. **Gradle/AGP integration** to invoke the Swift cross-compile and stage
   `jniLibs` as part of the Android build.
5. **A Compose UI** — the actual per-platform work, which is the point of having
   pushed everything else into the core.
6. **Platform playback plumbing** — a foreground service, audio focus,
   `MediaSession`. Android work, outside the core, not blocked by any of the
   above.

## Alternatives considered

- **Link Android's system `libsqlite3`.** Rejected: private platform library,
  unlinkable by NDK policy, and frequently no FTS5. The amalgamation is not a
  workaround, it is the supported path.
- **swift-java for Kotlin interop.** Rejected for now, above.
- **Reimplement the core logic in Kotlin.** Rejected outright: it discards the
  single-source-of-truth the last four ADRs are built on, and the
  continuity-hash requirement (byte-identical across platforms) is a standing
  invitation for a parallel reimplementation to drift.

## Consequences

- The "write it once in the core" strategy is now proven on the two platforms
  beyond Apple that Mozz cares about. ADR-0013's single pairing implementation,
  in particular, is confirmed to work on Android rather than merely hoped to.
- `android-ffi-spike.yml` keeps it true: it cross-compiles the whole core on any
  change to the FFI graph, so a future Apple-only leak is caught by CI in minutes
  rather than discovered when someone finally tries an Android build.
- The remaining Android work is now well-scoped shell-and-packaging work with one
  open networking question — not core research. That is a materially different
  and smaller risk than it was before the spike.
