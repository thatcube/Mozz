# Mozz

A music player for the media server you already run — Plex, Jellyfin or
Subsonic — on every device you own. This glossary fixes the words the project
uses for its own parts, because several of them are easy to confuse and the
distinctions carry real weight.

## Language

**Core**:
The Swift code that every platform runs unchanged: the local database, the
three server clients, sync, listening history, recommendations, continuity.
Everything that does not need a screen or a speaker.
_Avoid_: shared core, backend, engine, business logic

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

**Platform integration**:
A feature whose entire purpose is to meet a surface a platform provides —
CarPlay, Siri, a home-screen widget, Windows SMTC. These are the only features
allowed to exist on some platforms and not others, and only where the surface
itself exists.

**First-class platform**:
A platform whose shell is held to the same standard as every other: the same
features, the same performance, and idioms native to that platform rather than
another one's transplanted.
