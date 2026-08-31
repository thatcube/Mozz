# Android FFI spike

**Question this answers:** does Mozz's platform-free Swift core *cross-compile*
to a C-ABI shared library for Android, load on a real Android userspace, and run
its search / crypto / continuity paths correctly — and is it fast?

This is the Windows spike (`../windows-ffi/`) taken one step further. Windows
proves the core builds and runs on another desktop OS *of the same CPU*. Android
adds the two things a phone actually demands: a **cross-compile** (the build host
is x64 Linux/macOS, the target is arm64), and execution on **Bionic** (Android's
libc) rather than glibc/MSVCRT. The same `MozzFFI` C ABI is exercised by the same
gate battery, so the results line up column-for-column with the Windows and iOS
numbers.

## What it checks, in order

| # | Gate | Why it matters |
|---|---|---|
| 1 | `MozzCore` + `MozzDatabase` cross-compile | Is the core genuinely portable, or accidentally Apple-only? Release mode, to catch what debug hides |
| 2 | `MozzFFI` links as a `.so` | Does `@_cdecl` produce something Android's loader can `dlopen`? |
| 3 | The `.so` exports the session ABI | `llvm-nm`/`readelf` confirm `mozz_session_open/call/close` + `mozz_ffi_*` are really there |
| 4 | **SQLite has FTS5** | Apple's system SQLite always does. Android's does **not** reliably — and Mozz's entire search story dies without it |
| 5 | It loads and runs on an emulator | A static symbol dump can't show that the Swift runtime + SQLite deps resolve on-device |
| 6 | Search p95 < 100 ms | The hard product requirement, independent of platform |
| 7 | **HPKE (RFC 9180) works** | ADR-0013 puts pairing crypto in the shared core. If swift-crypto's HPKE doesn't function on Android, pairing needs a per-platform implementation |
| 8 | Continuity hashes match `spec/` | A non-Apple peer must derive byte-identical queue hashes, or cross-device resume fails silently |
| 9 | **HTTPS through Foundation** | The core makes its own HTTPS calls. If Foundation cannot on Android, the client has to supply the transport — see ADR-0015 |

Gate 4 is the decisive one, and the reason this spike compiles SQLite from the
amalgamation. See the ADR below.

## Why SQLite is built from source (the central finding)

GRDB's `GRDBSQLite` is a **systemLibrary** target — it links whatever `sqlite3`
the OS provides. On Apple that's fine; on Android it is not:

- Android *ships* a `libsqlite3.so`, but it is a **private platform library**;
  the NDK deliberately does not expose it for apps to link, and relying on it is
  a policy violation that can break between OS versions.
- The copy behind the NDK, and many device builds, **omit FTS5** — the one
  feature Mozz search cannot do without.

So, exactly as on Windows, the workflow compiles the amalgamation itself with an
explicit feature list (FTS5, snapshot, preupdate-hook, column-metadata, STAT4,
RTREE, JSON1, threadsafe, DQS=0) and archives it straight into `libMozzFFI.so`.
The shipped object is self-contained: 291 `sqlite3_*` symbols defined, zero left
undefined.

## Baselines to beat

Measured on iPhone 17 Pro Max, 100k tracks (`ARCHITECTURE.md` §8), with the
Windows spike's x64 column alongside:

| Metric | iOS | Windows x64 |
|---|---|---|
| search p50 / p95 | 7.9 / **15.7 ms** | 12.6 / 33.6 ms |
| cold DB open + first count | 66.4 ms | 12.3 ms |
| page fetch (100 rows) | 3.8 ms | — |
| catalog generation (100k) | 3.9 s | — |

Different hardware won't match these, and that's fine. What matters is staying
inside the 100 ms search budget and not regressing by an order of magnitude —
that would mean the boundary design is wrong, not just the silicon.

## Running it

### GitHub Actions (the only way to get real device numbers)

Actions → **Android FFI spike** → *Run workflow*. Three jobs run:

- **Cross-compile (aarch64 / x86_64)** — builds the amalgamation, the core, and
  `libMozzFFI.so` for both ABIs inside the official `swift:6.3.3` image, and
  verifies the exported ABI. arm64-v8a is every modern phone; x86_64 is what the
  emulator runs.
- **Run on Android emulator (x86_64)** — a KVM-accelerated API-28 emulator runs
  the harness, which `dlopen`s the `.so` and drives the C ABI on a real Android
  userspace. This is the job that produces the Android numbers.
- **macOS control** — the identical harness against a native macOS build. If the
  Android job fails and this passes, the fault is Android-specific rather than a
  bug in the facade or the harness.

### Locally on macOS (cross-compile + inspect, no device)

The Swift Android SDK is a cross-compilation SDK; it installs on macOS too. You
can build the `.so` and inspect it, but you can't run an x86_64 Android emulator
on Apple Silicon with acceleration — take the numbers from CI.

```bash
# Host toolchain + the official Android SDK bundle (pinned by checksum)
swiftly install 6.3.3
swift sdk install \
  https://download.swift.org/swift-6.3.3-release/android-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_android.artifactbundle.tar.gz \
  --checksum d160cc3206dd1886dae3fef2337af5e25ec034692cd0ec225721c56cc69da7f5

# Point the SDK at an NDK (r27d or later)
export ANDROID_NDK_HOME=/path/to/android-ndk-r27d
( cd ~/Library/org.swift.swiftpm/swift-sdks/*_android.artifactbundle/swift-android \
  && ./scripts/setup-android-sdk.sh )

# Build the amalgamation for the target, then the .so (see the workflow for the
# exact clang invocation and the nested static-lib search path both need).
swift build -c release --swift-sdk aarch64-unknown-linux-android28 \
  --static-swift-stdlib --product MozzFFI \
  -Xcc -I<sqlite>/include -Xlinker -L<sqlite>/lib \
  -Xlinker -L~/Library/org.swift.swiftpm/swift-sdks/*_android.artifactbundle/swift-android/swift-resources/usr/lib/swift_static-aarch64/android

# Confirm the ABI is exported
llvm-nm -D --defined-only .build/aarch64-unknown-linux-android28/release/libMozzFFI.so | grep mozz_
```

The macOS **control** harness (native, exercises the same gates) is one command:

```bash
swift build -c release --product MozzFFI
clang -O2 spike/android-ffi/harness/android_harness.c -o harness
./harness .build/release/libMozzFFI.dylib 20000 /tmp/mozz.sqlite spec/continuity/queue-hash-fixtures.json
```

## The harness

`harness/android_harness.c` is the C mirror of the Windows spike's C# harness. It
deliberately does **not** link `MozzFFI`: it `dlopen`s `libMozzFFI.so` and
resolves every entry point with `dlsym`, exactly the way a JNI shim (or a Kotlin
app) would. That makes the run a real test of two things a static dump cannot
show — that the shared object *loads* on Android with all its transitive Swift
runtime and SQLite dependencies resolved, and that its C ABI holds when called
from a foreign toolchain. Exit code is 0 only if every gate passes.

Arguments: `harness <lib.so> <trackCount> <db_path> <fixtures.json>`.

## What packaging the `.so` for a real app still needs

`--static-swift-stdlib` does **not** produce a standalone object on Android — the
`.so` still lists the Swift Android runtime (`libswiftCore.so`, `libFoundation*`,
`lib_FoundationICU.so`, `libdispatch.so`, …) and the NDK's `libc++_shared.so` as
`DT_NEEDED`. The emulator job assembles these into a payload and pushes them
alongside the harness; a shipping app puts them in `jniLibs/<abi>/` in the APK.
That set — and Foundation's networking backend, discussed in the ADR — is the
work that stands between "the core runs" and "an app ships."

## Interpreting a failure

| Symptom | Likely cause |
|---|---|
| Stage 1 fails | Something in the core isn't as portable as believed — the diagnostic names the file |
| Stage 2 fails, `unable to find library -l_CFURLSessionInterface` | The nested `swift_static-<arch>/android` search path is missing from the link (Foundation's networking archives live one dir deeper than the driver searches) |
| Stage 3 reports a missing `mozz_*` symbol | `@_cdecl` didn't emit it, or dead-strip removed it — the export contract broke |
| `dlopen failed` on the emulator | A `DT_NEEDED` runtime `.so` (or `libc++_shared.so`) isn't on `LD_LIBRARY_PATH` — check the payload assembly |
| `fts5CreateSucceeded: false` | **The big one.** The linked SQLite lacks FTS5 — the amalgamation feature flags are wrong |
| HPKE `available: false` | swift-crypto's HPKE doesn't function on Android; ADR-0013's "one pairing implementation everywhere" is off |
| A continuity hash mismatch | Compare the reported bytes, not the digests — the encoding is where the difference is |
| search p95 way over the iOS column | Investigate before writing any UI — likely index or configuration drift, not the boundary |
