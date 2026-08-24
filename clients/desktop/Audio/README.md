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
  a **separate executable** the user already has on `PATH`, so it is not even
  linked into the app — the loosest possible coupling.

We link `Hexa.NET.MiniAudio` (MIT) and shell out to `ffmpeg` ((L)GPL). Nothing
proprietary is linked or shipped.

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

This is verified without hardware by `Tests/PcmPipelineGaplessTests.cs`: one
continuous sine wave is split into two halves, played as two sources, and the
render output is asserted to be sample-contiguous across the boundary (no
discontinuity, no repeated or dropped frame) with `TrackChanged` firing once.

## What each file is

```
IAudioEngine.cs              The public surface + AudioSource/EqualizerSettings/events.
MiniAudioEngine.cs           The only IAudioEngine impl; owns the miniaudio device.
PcmPipeline.cs               Device-agnostic gapless core: ring + pump + DSP + boundaries.
Dsp/RingBuffer.cs            Lock-free single-producer/single-consumer float ring.
Dsp/Biquad.cs                RBJ biquads + a 10-band parametric equalizer.
Dsp/ReplayGain.cs            dB→linear and track/album gain selection with pre-amp.
Decoding/IPcmDecoder.cs      Decoder contract: interleaved F32 at the device rate.
Decoding/WavPcmDecoder.cs    Pure-managed RIFF/WAVE reader (the ffmpeg-free path).
Decoding/FfmpegProcessDecoder.cs  ffmpeg subprocess: all codecs + HTTP + seek.
Decoding/DecoderFactory.cs   Picks WAV vs ffmpeg per source.
Platform/INowPlayingIntegration.cs  OS "now playing" seam (SMTC / MPNowPlayingInfoCenter).
```

## Requirements coverage

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

- **Windows SMTC and macOS `MPNowPlayingInfoCenter`.** The `INowPlayingIntegration`
  seam is wired through the view model (play/pause/next/previous events and
  metadata/state/position updates), but the concrete platform surfaces are
  `NoopNowPlayingIntegration` today. SMTC needs WinRT interop and can only be
  verified on Windows; the macOS side needs Objective-C runtime interop. Filling
  either in is self-contained and touches no playback code.
- **In-process libav decoder.** The subprocess decoder is deliberate (ABI-proof,
  clean license boundary). If the process-per-track overhead ever matters, a
  second `IPcmDecoder` can be dropped in behind `DecoderFactory` with no other
  changes.
- **ReplayGain tag *reading*.** The engine *applies* gain supplied on
  `AudioSource`; parsing the gain tags out of files/stream metadata is the
  caller's job and is not yet populated by the library sync.
- **Verified on macOS only.** The WASAPI output path and SMTC could not be
  exercised on this Mac. They are argued from miniaudio's cross-platform backend
  (WASAPI is its default Windows device) and are the main thing a Windows machine
  should confirm.
