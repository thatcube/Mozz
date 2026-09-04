# Mozz

A music player for the media server you already run — Plex, Jellyfin or
Subsonic — on every device you own. This glossary fixes the words the project
uses for its own parts, because several of them are easy to confuse and the
distinctions carry real weight.

## Language

**Core**:
The code every platform runs unchanged: the local database, the three server
clients, sync, listening history, recommendations, continuity, and everything
that turns an encoded file into finished audio samples. The line is not "needs
a screen or a speaker" — it is the sample buffer. Producing that buffer is
shared; handing it to an operating system is not.
_Avoid_: shared core, backend, engine, business logic

**Sink**:
The small per-platform piece that takes finished audio samples and gives them to
the operating system. Deliberately thin, and deliberately stupid: it decodes
nothing, applies no gain and makes no choices, because every decision it was
allowed to make would be a way for two platforms to sound different.
_Avoid_: audio backend, output layer, driver, audio engine

**Circle**:
The set of devices that trust each other and sync as one. It has no owner and
no centre: any member can admit a new device, and any member can remove one.
Size is not two — a circle is however many devices someone owns, and the word
was chosen because every alternative implied a pair.
_Avoid_: pair, pairing group, linked devices, trusted pair

**Joining**:
What a device does when it enters a circle. The user-facing act, and the one to
name in an interface: someone adds a device to their circle, they do not pair
two of them.
_Avoid_: pairing (as a user-facing word), linking, connecting

**Pairing ceremony**:
The two-party protocol that performs a join: a commitment, an exchange, six
digits or a scanned code, and a sealed handover. This one *is* between exactly
two devices — the joiner and one member already inside — so "pairing" is right
here and wrong everywhere else. The distinction is the point: the ceremony is
between two, what it achieves is membership of many.
_Avoid_: handshake, pairing (unqualified), key exchange

**Joiner** / **Member**:
The two sides of a ceremony. The joiner is the device asking to be let in and
has nothing yet, so it advertises and displays. The member is already in the
circle and has secrets to give, so it looks and scans. Which is which follows
from whether a device is already in a circle, never from which button someone
pressed.
_Avoid_: client/server, host/guest, primary/secondary

**Boundary**:
The point where one track gives way to the next. Not an event — a *label on a
sample position*. Gapless playback makes the last sample of one track and the
first of the next adjacent, so nothing happens to the audio there and there is
nothing to observe; a boundary is only "reached" when the audio reaches it. The
decoder runs ahead of the speaker by however much buffer it has filled, so
anything announced when a track finishes decoding is announced early, by a
margin that moves with buffer pressure.
_Avoid_: track change event, track transition, song ended

**Position**:
How much of the current track has actually been heard — measured from the audio
handed to the operating system, never from a clock and never from how far the
decoder has read. Those differ by the whole buffer. A player that reports
decoded position appears to run ahead of its own sound, most visibly on a slow
network, where the gap is largest.
_Avoid_: playhead, elapsed, current time

**Shell**:
One platform's user interface, written in that platform's own framework. A
shell is deliberately not shared; two shells presenting the same capability
differently is correct, two shells *disagreeing* about it is a bug.
_Avoid_: client, frontend, app layer

**Facade**:
The single doorway into the Core for a shell that is not written in Swift. It
takes a named command with JSON arguments and returns JSON. A capability that
exists in the Core but has no command on the Facade is unreachable from every
platform except Apple's, which has been the cause of most parity bugs.
_Avoid_: C ABI, FFI, the bridge, the interface

**Command**:
One named operation on the Facade — `albums`, `setFavorite`, `continuitySave`.
The unit in which the Core's capabilities become available to other platforms.

**Backend**:
One kind of media server Mozz can talk to: Plex, Jellyfin, or Subsonic. Refers
to the protocol, never to a particular person's machine.
_Avoid_: provider, service, source

**Server**:
One person's actual media server — an address, a credential, a library. A
Backend is a kind; a Server is an instance.

**Design language**:
The decisions every shell obeys — colour, spacing, type scale, corner radius,
motion, and the shape of a screen's layout. It is shared as values, never as
components: a button's size and feel belong to its platform, but its colour and
the rhythm around it do not. This is the only part of a shell that is shared.
_Avoid_: design system, component library, theme

**Parity**:
Every platform can do everything every other platform can do. Presentation is
free to differ — a desktop window and a phone are different instruments — so
long as each clears the same bar. The exception is sound: two platforms playing
the same file should produce the same samples, and a difference there is a
defect rather than a variation. A platform that lacks a capability is behind,
never exempt.
_Avoid_: feature parity, consistency, cross-platform support

**Platform integration**:
A feature whose entire purpose is to meet a surface a platform provides —
CarPlay, Siri, a home-screen widget, Windows SMTC. These are the only features
allowed to exist on some platforms and not others, and only where the surface
itself exists.

**First-class platform**:
A platform whose shell is held to the same standard as every other: the same
features, the same performance, and idioms native to that platform rather than
another one's transplanted.
