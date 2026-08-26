# ADR-0015 — One audio engine, written in Rust

Status: **Accepted** (decision recorded; not yet built).

The audio pipeline is currently written twice — in Swift over AVFoundation for
Apple platforms, and again in C# over FFmpeg and miniaudio for the desktop. This
ADR replaces both with a single engine, and records why that engine is in a
language neither of the existing shells is written in.

## Context

Mozz has one shared Swift core precisely so that a capability is written once and
every platform gets it. Audio is the conspicuous exception. `Sources/MozzPlayback`
(2,715 lines) drives AVFoundation on Apple platforms; `clients/desktop/Audio`
(2,437 lines) is an independent implementation with its own FFmpeg decode path,
ring buffer and miniaudio sink.

The cost of that is not hypothetical. **ReplayGain and the biquad equaliser exist
in two implementations that nothing forces to agree.** Two devices playing the
same file can apply different gain, and no test in either suite would notice,
because each suite only ever sees its own implementation. The failure mode is a
user hearing a difference between their phone and their PC and having no way to
report it usefully.

It gets worse rather than better. Android and the web have no engine at all yet,
so the honest projection is four implementations of the same DSP. And the planned
sonic-analysis feature makes the divergence a correctness problem rather than a
quality one: an embedding is a vector, and vectors computed by two different FFT
implementations do not live in the same space. Similarity search would return
different neighbours depending on which machine analysed the track — in an app
that is explicitly syncing state across devices.

The architecture's stated rule was "share everything that does not need a screen
or a speaker", which put decode and gain on the per-platform side of the line and
made this outcome inevitable. That rule has been corrected: the line is the
**sample buffer**. Producing finished samples is shared; handing them to an
operating system is not.

## Decision

One audio engine, in **Rust**, exposed over a C ABI. It owns decode, the gapless
ring buffer, ReplayGain, and the biquad equaliser. Per-platform code is reduced
to a *sink* — the piece that hands finished samples to CoreAudio, WASAPI, AAudio,
PipeWire or a WebAudio worklet.

It replaces `MozzPlayback` and the C# audio pipeline **wholly, not alongside
them**. A flag-guarded partial migration would preserve the exact duplication
this exists to remove.

Transport control — play, pause, seek, set gain — goes through the Facade like
every other capability, rather than each shell linking the audio library
directly. The audio callback itself never crosses a language boundary: the shell
hands the sink a pointer once and the callback runs entirely inside the Rust
library, so there is no realtime cost to routing control through the Facade.

## Why Rust rather than C, C++ or Swift

**Swift** was the obvious candidate — it is the language the core is already
written in, and it now compiles for Android and WebAssembly. It was rejected on
one specific ground: a realtime audio callback may not allocate, may not take a
lock, and may not touch anything that can block. ARC makes that very difficult to
*guarantee* rather than merely intend, and the failure mode is an audible glitch
that no unit test will catch.

**C** was the default choice and nearly won. Its advantage was reach — it is the
one language every target speaks natively. `cpal` erases that advantage: it
covers WASAPI, CoreAudio (macOS, iOS and tvOS), ALSA and PipeWire, AAudio, and
the Web Audio API. That is every platform Mozz targets or has considered,
including television, in one library.

**C++** is what the closest comparable products use — Plexamp's TREBLE engine and
Symfonium's audio core are both C++. It remains a perfectly defensible choice.
Rust was preferred because "no allocation on the audio thread" becomes something
the compiler can enforce rather than a discipline maintained by review, and
because every line of this codebase is written by an AI agent, where a rule the
compiler does not check is a rule that will eventually be broken.

There is a real cost, and it should be stated plainly: **this makes Rust a second
core language alongside Swift.** For a solo maintainer that is a permanent tax.
It was accepted knowingly, on the grounds that one engine in an unfamiliar
language is cheaper to own than four engines in familiar ones.

## Consequences

The desktop's existing miniaudio pipeline is not naive — it works, and it has
gapless playback and ReplayGain today. The Rust engine has to be at least as good
before it can replace it. That is the bar.

AVFoundation was providing more than DSP. Interruption handling, route changes,
AirPlay and the CarPlay audio path all came with it, and none of that is decode
or gain, so none of it moves into the shared engine. It stays on the Apple side
and has to be rewritten against the new engine — work that is easy to under-count
when scoping this.

`cpal`'s WebAssembly backend is the least-exercised part of this decision. If it
proves inadequate for the web player, the fallback is a WebAudio worklet driving
the same Rust DSP compiled to Wasm, which is more work but not a different
architecture.

The decode path must be built so that batch sonic analysis is a *second consumer*
of it from the start. Analysis ships later, but retrofitting a second entry point
into a decoder designed only for realtime playback is the expensive version.

## Falsifier

Bit-identical PCM from the same input file, with the same ReplayGain and EQ
settings applied, on macOS and Windows. If that cannot be demonstrated, the
central premise — that one engine removes acoustic divergence — has not been
delivered, whatever else has been built.
