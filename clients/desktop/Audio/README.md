# Mozz.Desktop.Audio

The playback engine for the desktop client. It sits behind one interface,
`IAudioEngine`, so the rest of the app never learns which backend moves the
samples — the same way `Core/MozzCore.cs` is the only file that knows the core
is a native library.

## The choice: one shared engine, in Rust, reached by P/Invoke

The desktop client used to carry its *own* audio engine — an `ffmpeg`
subprocess decoder, a managed PCM ring buffer, a decode pump, and biquad DSP —
duplicating what the Apple client did natively. Two independent engines drift:
they had already begun to disagree about ReplayGain above roughly +12 dB. That
whole managed stack is gone.

Playback now runs through the **shared Rust engine in `audio/`**, exposed over a
C ABI by the `audio/ffi` crate (`libmozz_audio_ffi`). Decode, the output device,
the DSP chain (EQ + ReplayGain), gapless hand-off, and the HTTP byte-range
semantics all live in Rust and are shared with the Apple app, so the two clients
cannot diverge again. The C# side is a thin shell: it opens the bytes, hands the
engine read/seek/close callbacks, and reflects the state the engine reports.

## What stayed on the C# side, and why

- **`IAudioEngine.cs`** — the public surface the app is allowed to see
  (`Play`/`PreloadNext`/`Pause`/`Resume`/`Stop`/`Seek`/`Volume`,
  `SetEqualizer`/`SetReplayGain`, `Position`/`Duration`/`State`, and the
  `TrackChanged`/`PlaybackEnded`/`Error` events, plus `AudioSource` and
  `EqualizerSettings`). Unchanged: swapping the backend touched no view model.
- **`Native/RustAudioEngine.cs`** — the only `IAudioEngine` implementation. It
  owns the `MozzPlayer` handle and bridges the engine's *poll*-based model
  (state, position and current-track are getters) to the interface's
  *event*-based one with a background monitor thread that watches those getters
  and raises the events on the transitions a listener would notice. Position
  comes from `mozz_player_position_seconds`, never a wall clock — they differ by
  the whole output buffer. `state == ended` means the audio finished *playing*,
  not decoding, so the queue never advances early.
- **`Native/MozzAudioInterop.cs`** — the raw P/Invoke surface plus the glue that
  lets the engine read managed bytes (see below).
- **`Streaming/`** — `ByteStreamSource` and its `File`/`Http` implementations.
  The engine never fetches anything; credentials belong to the shell, so the app
  supplies the bytes. `HttpByteStreamSource` is the one piece with real logic of
  its own and is unit-tested in isolation.
- **`AudioDiagnostics.cs`** — token redaction and failure-message shaping. Pure,
  side-effect-free, and therefore testable in the headless test project (which
  cannot load the native library). `RustAudioEngine` routes its open-failure
  messages through `DescribeOpenFailure`, which redacts the URL. The
  `SummariseFfmpeg`/`DescribeFfmpegFailure` helpers are retained but now
  vestigial — the desktop no longer spawns ffmpeg — and are kept only because
  they are harmless pure functions still covered by tests.
- **`Platform/`** — the OS "now playing" seam (`MacNowPlayingIntegration` and its
  interface). Genuine platform integration, not audio production, so it is not
  duplicated in Rust.

## Bytes come from a callback, not a URL

The engine decodes bytes it is *handed*; it does not open connections, so no
credential ever crosses the ABI. `RustAudioEngine` opens a `ByteStreamSource`
for each track and hands the engine three function pointers — `read`, `seek`,
`close` — that pull from it:

- **File tracks** open eagerly, so a missing file fails `Play` immediately rather
  than starting a silent track.
- **HTTP tracks** open lazily and carry the app's auth headers.
  `HttpByteStreamSource` serves seeks with fresh ranged requests. A server that
  ignores `Range` and answers `200` with the whole body is honest only at offset
  zero; anywhere else it is **rejected** (read returns an error) rather than
  decoding from the start of the file while claiming to be elsewhere — which
  would sound like a corrupt track, not a bug. This mirrors the Swift
  `MozzAudioEngine/Streams.swift` semantics exactly.

### Delegate lifetime (a crash you only see on the decode thread)

The callback trampolines are `static [UnmanagedCallersOnly]` methods, so their
native entry points are fixed and never move under the GC. The *managed* stream
they act on is what must be kept alive: `MozzAudioInterop.Attach` roots the
`ByteStreamSource` with a `GCHandle` and passes the handle as the callbacks'
context pointer. A .NET object collected while Rust still holds that pointer is a
crash on the decode thread that would be blamed on the audio engine, so the
handle lives for the whole life of the stream. `close` is invoked **exactly
once, from the decode thread**; that is where the handle is freed and the stream
closed — not before. There must be no fallible work between `Attach` and the FFI
call, or the handle leaks.

## Getting the native library next to the app

P/Invoke needs `libmozz_audio_ffi.dylib` (`.so`/`.dll` elsewhere) beside the
executable at run time, or the first `Play` throws `DllNotFoundException`.

- **`tools/build-audio-cdylib.sh`** builds the release cdylib
  (`cargo build --release -p mozz_audio_ffi`) and prints its path.
- **`Mozz.Desktop.csproj`** wires this into the normal build: a
  `BuildMozzAudioNative` target (before `Build`/`Publish`) builds the crate, and
  `CopyMozzAudioNativeToOutput`/`CopyMozzAudioNativeToPublish` copy the library
  into the output and publish folders. `dotnet run` and `dotnet build` therefore
  just work.
- **`tools/build-macos-app.sh`** copies the whole publish folder into
  `Mozz.app/Contents/MacOS`, so the dylib rides into the bundle with no extra
  step.

## License

Mozz is **GPL-3.0, "free forever, open source."** The audio engine is now
first-party Rust in this repository (`audio/`), built and shipped as part of the
app; nothing proprietary is linked. Codec and platform licensing is a property
of that crate and its dependencies — see `audio/` for the authoritative list.

## File map

```
IAudioEngine.cs                     The public surface + AudioSource/EqualizerSettings/events.
Native/RustAudioEngine.cs           The only IAudioEngine impl; owns the Rust MozzPlayer, poll→event monitor.
Native/MozzAudioInterop.cs          P/Invoke surface + read/seek/close trampolines + GCHandle rooting.
Streaming/ByteStreamSource.cs       The read/seek/close contract the engine pulls bytes through.
Streaming/FileByteStreamSource.cs   Local file bytes; opened eagerly so a missing file fails Play.
Streaming/HttpByteStreamSource.cs   Ranged HTTP with the app's auth; rejects a 200 answered off-zero.
AudioDiagnostics.cs                 Token redaction + failure-message shaping (pure, tested headless).
Platform/INowPlayingIntegration.cs  OS "now playing" seam (SMTC / MPNowPlayingInfoCenter).
Platform/MacNowPlayingIntegration.cs  macOS MPNowPlayingInfoCenter card.
```

## Requirements coverage

- **OS now-playing** — macOS card implemented and tested against the real
  framework; Windows SMTC outstanding (the `INowPlayingIntegration` seam is
  wired through the view model, so filling it in touches no playback code).
- **Cross-platform output, formats, HTTP streaming with auth + range seek,
  gapless, EQ and ReplayGain** — all provided by the shared Rust engine and
  covered by its own tests, so the desktop and Apple clients share one
  implementation.
- **Transport + position + end-of-track event** — `Play/Pause/Resume/Stop/Seek/
  Volume`; `Position` derived from the engine's played-sample clock;
  `PlaybackEnded` when the audio (not the decode) finishes.
- **No UI-thread blocking** — decode and device work happen on the engine's own
  threads; the monitor marshals state changes back through the view model.

## What is not yet done (honest list)

- **Windows SMTC** and **media keys** (`MPRemoteCommandCenter` on macOS) — the
  now-playing *card* is published on macOS, but transport *commands* are not yet
  wired. These are platform-integration work in `Platform/`, independent of the
  engine.
- **ReplayGain tag *reading*** — the engine *applies* gain supplied on
  `AudioSource`; parsing gain tags out of files/metadata is the caller's job.
