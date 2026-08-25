# Mozz.Desktop.Audio

The playback engine for the desktop client. It sits behind one interface,
`IAudioEngine`, so the rest of the app never learns which backend moves the
samples — the same way `Core/MozzCore.cs` is the only file that knows the core
is a native library.

## The choice: FFmpeg (decode) + miniaudio (output), stitched by an app-owned ring buffer

Serious gapless players split the problem in two: something that turns *any*
container/codec into PCM, and something that hands PCM to the sound card. Mozz
does the same.

- **Decode / demux / HTTP: the system `ffmpeg` binary, driven as a subprocess.**
  FFmpeg decodes every format we care about (MP3, AAC/M4A, FLAC, Ogg Vorbis,
  Opus, WAV, ALAC, and far more) and — crucially — speaks HTTP(S) itself:
  auth headers, query-token URLs, byte-range seeking, and reconnect-on-stall are
  all built in (`-headers`, `-reconnect`, `-ss`). We spawn
  `ffmpeg … -f f32le -ac 2 -ar 48000 -` and read interleaved float PCM off its
  stdout. See `Decoding/FfmpegProcessDecoder.cs`.
- **Output device: [miniaudio](https://miniaud.io/)** via the
  [`Hexa.NET.MiniAudio`](https://www.nuget.org/packages/Hexa.NET.MiniAudio)
  NuGet package. miniaudio is a single-file C library that wraps WASAPI on
  Windows, CoreAudio on macOS, and ALSA/PulseAudio/JACK/PipeWire on Linux behind
  one callback-based API. The package ships prebuilt natives for
  win-x64/arm64/x86, osx-x64/arm64 and linux-x64/arm64, so there is nothing to
  compile on any target. See `MiniAudioEngine.cs`.
- **The glue that makes it gapless: an app-owned lock-free PCM ring buffer with a
  decode pump thread.** `PcmPipeline.cs` owns the ring, the pump, the DSP chain,
  and the boundary bookkeeping; it is completely device- and codec-agnostic and
  is the piece the tests exercise.

### Why not the obvious single-library options

| Candidate | License | Verdict |
|---|---|---|
| **LibVLCSharp** (VLC) | LGPL-2.1+ / GPL | Rejected as the engine. GPL-compatible and plays everything, but its gapless is not *sample-accurate* (it re-opens the next input and there is a media-change boundary), it is a heavyweight native dependency, and per-sample DSP (our EQ/ReplayGain) is awkward. |
| **BASS / un4seen**, **ManagedBass** | **Proprietary** | **Rejected outright.** Free for freeware only; not open source; **not GPL-compatible.** Mozz is GPL-3.0, so this is a non-starter regardless of quality. |
| **NAudio** | MIT | Windows-only. Fine for WASAPI, but it is not a cross-platform answer, so at best it would be one of three output backends to maintain. |
| **FFmpeg in-process** (FFmpeg.AutoGen / bindings) | LGPL/GPL | Same decode power, but binds to a specific libav* ABI. This machine has FFmpeg 9.0 / libavcodec 63, which is ahead of the common binding packages; a subprocess is ABI-proof and puts the (L)GPL code behind a clean process boundary. |
| **SDL3 audio** | zlib | A good output layer with *no* decoding — it would replace miniaudio, not FFmpeg. miniaudio was chosen for its ready NuGet natives and its simpler single-callback model. |

## License — all GPL-3.0-distribution compatible

Mozz is **GPL-3.0, "free forever, open source."** Every piece here is compatible
with distributing the app under GPL-3.0:

- **miniaudio** — public domain (Unlicense) **or** MIT-0, author's choice. No
  obligations either way; GPL-compatible.
- **`Hexa.NET.MiniAudio`** (the managed binding + prebuilt natives) — **MIT**
  (`LICENSE.txt` in the package). GPL-compatible.
- **FFmpeg** — LGPL-2.1+ for the default build, GPL if built with GPL options.
  Either is compatible with a GPL-3.0 application, and here FFmpeg is invoked as
  a **separate executable** (located per `FfmpegProcessDecoder.ResolveFfmpeg` /
  `FfmpegLocator`, below), so it is not even linked into the app — the loosest
  possible coupling.

We link `Hexa.NET.MiniAudio` (MIT) and shell out to `ffmpeg` ((L)GPL). Nothing
proprietary is linked or shipped.

## Finding ffmpeg, and why "on PATH" was not enough

Playback failed on macOS with *"Could not open …"* for a reason that had nothing
to do with the audio: a double-clicked `.app` is launched by `launchd`, not a
shell, and inherits `launchd`'s minimal `PATH` — `/usr/bin:/bin:/usr/sbin:/sbin`,
which does **not** include `/opt/homebrew/bin`. Homebrew's ffmpeg lives there, so
`Process.Start("ffmpeg")` threw *"No such file or directory"* even though ffmpeg
was installed and worked perfectly from a terminal. Launching from a shell (or
`open` from one) hides the bug, because then the process inherits the shell's
full `PATH` — which is exactly why it looked like it had been ruled out. Windows
never saw it: its release bundles ffmpeg beside the app.

So the decoder no longer trusts the process `PATH` alone. `FfmpegLocator` resolves
ffmpeg in this order, and the first hit wins: an explicit `MOZZ_FFMPEG` override →
a copy shipped beside the app → the absolute directories a package manager
actually installs into (`/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`,
`/usr/bin`, `/bin`, `/snap/bin`) → the bare name for the OS to resolve. The
ordering is unit-tested with an injected filesystem, no subprocess required
(`FfmpegDiagnosticsTests`). The fix needs nothing from the user: a normal Mac
with Homebrew ffmpeg just works, GUI-launched or not.

## Surfacing failures (and never printing the token)

Two diagnostics bugs made this hard to see, both fixed:

- **The reason was lost.** The old message led with the whole track URL and
  appended `ex.Message`; on Plex that URL is hundreds of characters, so a status
  bar truncated away the one part that mattered. Messages now lead with the
  reason and put the (redacted) source second — `AudioDiagnostics.DescribeOpenFailure`.
- **A network/TLS/HTTP failure was silent.** When ffmpeg *is* found but dies at
  the network layer (bad certificate, 401, 404, refused), it exits non-zero and
  writes the reason to stderr — but the pipeline treats a decoder that stops
  producing frames as a finished track. `FfmpegProcessDecoder` now implements
  `IDecoderDiagnostics`; `PcmPipeline.OnCurrentEnded` asks a drained decoder
  whether it *failed* (before disposing it, which would kill the process and
  erase the evidence) and raises `Error` with a one-line summary of ffmpeg's
  stderr. A decode we tear down deliberately (seek/stop/dispose) is never
  mistaken for a failure.

`X-Plex-Token` (and `api_key`, `access_token`, …) is a credential and is
**redacted** from every user-facing string and stderr summary via
`AudioDiagnostics.Redact`, so it can never reach a status bar or a log.

On **TLS specifically**: this was investigated and is *not* a Mozz problem. ffmpeg
9's OpenSSL build validates publicly-trusted certificates — Plex's `*.plex.direct`
certs included — against its compiled-in CA bundle with no help from us, and query
strings pass through `ProcessStartInfo.ArgumentList` unmangled. A local self-signed
server did fail verification (correctly), but a real Plex server presents a trusted
cert, so no `-ca_file`/`SSL_CERT_FILE` override is shipped: it is unnecessary here
and would risk masking a genuine bad-certificate warning.

## Gapless — genuinely supported, and how

The device stream **never stops between tracks.** When a track nears its end and
a next source has been preloaded, the pump thread simply keeps filling the *same*
ring buffer from the next decoder's first sample, contiguous with the previous
track's last sample. Because there is no `DeviceStop`/`DeviceStart` and no ring
flush at the boundary, the hand-off is **sample-accurate**: no click, no gap, no
re-sync. Per-track ReplayGain switches exactly at the decoder swap; the EQ filter
state runs continuously across the seam so it never clicks either.

The `TrackChanged` event fires from a notifier thread the instant the *consumed*
sample count crosses the recorded boundary — i.e. when the listener actually
hears the new track, not when it was decoded — which is what drives the view
model to advance the queue and preload the following track.

This is verified without hardware by `clients/desktop-tests/PcmPipelineGaplessTests.cs`:
one continuous sine wave is split into two halves, played as two sources, and the
render output is asserted to be sample-contiguous across the boundary (no
discontinuity, no repeated or dropped frame) with `TrackChanged` firing once.
Those tests are pure-managed and BCL-only, so the same project's
`dotnet test` runs them on the **Windows CI leg** as well as macOS — which is
where the pipeline's Windows correctness is checked before a user does.

## What each file is

```
IAudioEngine.cs              The public surface + AudioSource/EqualizerSettings/events.
MiniAudioEngine.cs           The only IAudioEngine impl; owns the miniaudio device.
PcmPipeline.cs               Device-agnostic gapless core: ring + pump + DSP + boundaries.
Dsp/RingBuffer.cs            Lock-free single-producer/single-consumer float ring.
Dsp/Biquad.cs                RBJ biquads + a 10-band parametric equalizer.
Dsp/ReplayGain.cs            dB→linear and track/album gain selection with pre-amp.
Decoding/IPcmDecoder.cs      Decoder contract: interleaved F32 at the device rate.
Decoding/IDecoderDiagnostics.cs  Optional: lets a drained decoder report why it failed.
Decoding/WavPcmDecoder.cs    Pure-managed RIFF/WAVE reader (the ffmpeg-free path).
Decoding/FfmpegProcessDecoder.cs  ffmpeg subprocess: all codecs + HTTP + seek.
Decoding/FfmpegLocator.cs    Finds ffmpeg without trusting a GUI process's PATH.
Decoding/DecoderFactory.cs   Picks WAV vs ffmpeg per source.
AudioDiagnostics.cs          Token redaction + ffmpeg-stderr → one readable line.
Platform/INowPlayingIntegration.cs  OS "now playing" seam (SMTC / MPNowPlayingInfoCenter).
```

## Requirements coverage

- **OS now-playing** — macOS card implemented and tested against the real
  framework; Windows SMTC outstanding.
- **Cross-platform** — miniaudio covers Windows/macOS/Linux from one codebase;
  ffmpeg is on every desktop. Verified running and *audible* on macOS (arm64).
- **Formats** — anything ffmpeg decodes; WAV additionally has a managed reader.
- **HTTP streaming with auth + range seek + reconnect** — handled inside ffmpeg
  via `-headers`/`-ss`/`-reconnect`; `Process.Start` returns before the network
  connect, so `Play` never blocks the UI thread.
- **Transport + 10 Hz position + end-of-track event** — `Play/Pause/Resume/Stop/
  Seek/Volume`, `Position` derived from *consumed* frames, `PlaybackEnded` when
  the queue drains.
- **No UI-thread blocking** — decode and device callbacks run off-thread; every
  state change reaches the UI through `Dispatcher.UIThread.Post`.
- **ReplayGain** — `SetReplayGain(mode, preampDb)`; per-track/album gain read from
  `AudioSource` and applied as a linear pre-amp.
- **10-band parametric EQ** — `SetEqualizer(...)` with RBJ peaking biquads per
  channel.

## What is stubbed / not yet done (honest list)

- **Windows SMTC.** Needs WinRT interop and can only be verified on a Windows
  machine. The `INowPlayingIntegration` seam is wired through the view model, so
  filling it in touches no playback code.
- **Media keys, on any platform.** macOS now publishes to
  `MPNowPlayingInfoCenter` (the Control Center card — see
  `Platform/MacNowPlayingIntegration.cs`), but *commands* need
  `MPRemoteCommandCenter`, whose API takes Objective-C blocks. Constructing a
  block from C# means hand-building its layout — isa pointer, flags, invoke
  function pointer — which is a materially riskier piece of interop than message
  sending, so the transport events are declared and not yet raised.
- **In-process libav decoder.** The subprocess decoder is deliberate (ABI-proof,
  clean license boundary). If the process-per-track overhead ever matters, a
  second `IPcmDecoder` can be dropped in behind `DecoderFactory` with no other
  changes.
- **ReplayGain tag *reading*.** The engine *applies* gain supplied on
  `AudioSource`; parsing the gain tags out of files/stream metadata is the
  caller's job and is not yet populated by the library sync.
- **The WASAPI *output* path and SMTC are unverified on Windows.** The gapless
  pipeline, DSP, ring buffer and decoders are pure-managed and run green on the
  Windows CI leg, but *audible* output through miniaudio's WASAPI device and the
  SMTC media-key surface could not be exercised from this Mac. They are argued
  from miniaudio's cross-platform backend (WASAPI is its default Windows device)
  and are the main thing a physical Windows machine should confirm.
