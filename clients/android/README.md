# Mozz for Android

Mozz on your phone, your tablet and your fold — the same library, the same
history, the same taste profile as the iPhone app, because it is the same core.

## What this actually is

The music logic is not reimplemented here. `Sources/` at the repository root is
Swift, cross-compiled to `libMozzFFI.so` and driven over a C ABI: the database,
the Plex/Jellyfin/Subsonic clients, sync, search, recommendations and listening
history are all the code the iOS app runs. This project is a window, a queue and
an audio engine.

Three files know that:

- `core/src/main/cpp/mozz_jni.c` — the JNI shim over the C ABI.
- `core/src/main/java/com/thatcube/mozz/core/MozzNative.kt` — the only Kotlin
  that knows the core is native.
- `core/build.gradle.kts` — the tasks that cross-compile the Swift and stage it.

Everything else is ordinary Kotlin.

See [`../../docs/adr/ADR-0014-android-support.md`](../../docs/adr/ADR-0014-android-support.md)
for why it is built this way, and [`PLAN.md`](PLAN.md) for what is and is not in v1.

## Building it

You need the Android SDK (platform 36, NDK r27d) and the Swift Android SDK. The
Swift side is pinned in `../../spike/android-ffi/README.md`; the short version:

```bash
swiftly install 6.3.3
swift sdk install \
  https://download.swift.org/swift-6.3.3-release/android-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_android.artifactbundle.tar.gz \
  --checksum d160cc3206dd1886dae3fef2337af5e25ec034692cd0ec225721c56cc69da7f5
```

Then, from this directory:

```bash
./gradlew :app:assembleDebug
```

Gradle drives the Swift cross-compile itself (`buildSwiftCore`), stages the
result into `core/src/main/jniLibs/<abi>/` (`stageSwiftCore`), and only then
builds the JNI shim against it. There is no separate manual step.

By default only `arm64-v8a` is built, because that is every phone. To add the
emulator ABI:

```bash
./gradlew :app:assembleDebug -Pmozz.swiftArchs=aarch64,x86_64
```

## What ships in the APK

`--static-swift-stdlib` does not make the core standalone on Android: the `.so`
still lists the Swift Android runtime and the NDK's `libc++_shared.so` as
`DT_NEEDED`. So `jniLibs/<abi>/` carries `libMozzFFI.so` plus ~28 runtime
objects — around 150 MB per ABI, unstripped. That is why the build splits by ABI
rather than shipping a universal APK, and why stripping is on the list before
this reaches anyone.

## Running the portability gates

The app's correctness rests on the core behaving the same here as on iOS. That
is checked by the spike harness, which runs the whole gate battery — FTS5
search, HPKE pairing, byte-identical continuity hashes, and HTTPS — on a real
device rather than in a unit test:

```bash
../../spike/android-ffi/build-local.sh --run --tracks 20000
```

Point it at your own server to test the network path against something real:

```bash
../../spike/android-ffi/build-local.sh --run --https-url https://your-server.example
```
