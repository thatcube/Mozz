# ADR-0016 — One doorway: audio goes through the Facade

Status: **Accepted** (decision recorded; not yet built).

ADR-0015 puts the audio engine in a Rust library behind a C ABI. Every shell can
therefore call it directly, which is how most media players are built. This ADR
records the decision not to, and why the reasoning is about parity rather than
about audio.

## Context

Mozz's recurring bug is structural, not incidental. Of seven parity defects found
in one recent week, **four had the same cause**: a capability was added to the
shared core, the iOS shell could use it immediately because it calls Swift
directly, nobody wrote a Facade command for it, and every non-Apple platform was
blind to it. Not one of those was a coding error. Each was the predictable result
of the core having **two doorways** — a privileged one for iOS and a narrower,
hand-maintained one for everybody else.

The response to that is a generated schema (one definition producing the Swift,
C#, Kotlin and TypeScript clients) and the removal of iOS's direct access, so
that a capability outside the declared surface is useless to *everyone* and
therefore never gets written.

A new C-ABI audio library arriving in the middle of that work is a live threat to
it. Linking it directly from each shell is genuinely tempting: it is the obvious
thing, it is what Plexamp and foobar2000 do, and it avoids a layer. But it would
create a **second doorway into shared code** at the exact moment the first one is
being closed — and the failure it invites is the one already documented four
times over: a capability reachable from some shells and not others, with nothing
in the build to notice.

## Decision

Audio transport — play, pause, seek, next, previous, set gain, set EQ, queue
operations — is expressed as commands on the Facade, alongside every other
capability. No shell links the audio library directly for control.

The **audio callback is exempt, and does not need an exemption.** The shell hands
the sink a pointer once, at stream setup; from then on the callback runs entirely
inside the Rust library and never crosses a language boundary. There is no
realtime path through the Facade to be slow.

## Why this costs nothing

The objection to routing audio through a schema-generated boundary is
serialization overhead, and it does not apply here. Transport control happens at
**human speed** — a person presses pause a few times a minute, not a few thousand
times a second. Serialising a pause command is free relative to the gap between
one press and the next.

The thing that *is* latency-critical, the callback filling a buffer every few
milliseconds, is precisely the thing that stays inside the library. The two
concerns separate cleanly, which is what makes the decision cheap. If they did
not — if the shells had to stream PCM across the boundary — this would be a
genuine trade-off rather than a free one, and the answer would probably differ.

## Consequences

Playback state becomes observable the same way everything else is, through the
subscription mechanism in the schema rather than a bespoke audio-specific
callback. One mechanism for "tell me when something changed", not two.

It constrains build order: the audio engine is a *consumer* of the Facade, so the
schema's shape needs to settle first. Building the engine first would mean
hand-writing its commands in exactly the style being deleted, then regenerating
them.

Equaliser and repeat/shuffle settings move into the core rather than living in
each platform's local preferences, where the desktop currently keeps them
(`AppPreferences`, `mozz.equalizerSettings`). That closes a parity gap and a
cross-device sync bug at the same time: settings that live in a per-device
preferences file can never follow the user to another device.

If a future platform's audio integration genuinely cannot be driven through
commands — an OS that demands the app own the transport loop rather than respond
to it — that is the signal to revisit this, and it should be revisited explicitly
rather than by quietly linking the library on one platform.
