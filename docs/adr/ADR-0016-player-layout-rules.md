# ADR-0016 — The player's layout is a rule, not a screen

Status: **Accepted** (implemented on Android; iOS, iPad, desktop and web to follow)

## Context

iOS has one player: a single column, artwork above the transport, with the queue
and the lyrics swapping into the artwork's place. That is a good phone player and
it is the only player Mozz has ever specified.

Android forced the question, because the Fold's inner display is 852dp wide. A
phone layout stretched across it is the thing that looks wrong. But the answer
could not be "a tablet player" as a second design, because then Mozz would own
two players that drift apart, and the same question is already waiting on iPad,
on desktop, and on the web.

## Decision

**One piece of state, three presentations.** The player holds exactly one value:

```
panel: none | queue | lyrics
```

Width decides only how that value is *drawn*:

| | `none` | `queue` / `lyrics` |
|---|---|---|
| **wide** | artwork centred, full width | player left, panel in its own right column |
| **narrow** | artwork centred | panel takes the artwork's place |

That is the whole rule, and it is written once, as a pure function with no UI
framework in it (`playerPresentation(wide, panel)` in
`clients/android/app/.../ui/PlayerLayout.kt`).

Three consequences worth stating, because they are the reasons for the shape:

**There is no per-layout preference.** Closing the queue means the same thing on a
phone and a tablet, so folding a device mid-song rearranges the screen without
changing what the person asked for. Two independent memories — one for wide, one
for narrow — is the kind of state that feels broken the moment a device changes
shape underneath it.

**Narrow has nothing extra to turn off.** On one column there is no side panel to
close; `none` simply means the artwork is showing. The apparent asymmetry between
the two rows of that table is not a special case, it is the same state read at a
different width.

**Tapping the dock always gives a full-screen player**, at every width, over the
navigation rail included. The player and the dock are one object in two
presentations and never both; "full screen" is not negotiable per device, because
the artwork backdrop is the point and it wants the room.

## Also decided: the dock's geometry does not vary

Navigation moves with width — a bar along the bottom on a phone, a rail down the
left when there is room. The dock does not. It is the same floating pill at every
size: full width less a margin, at the bottom, with the rail stopping *above* it
rather than beside it.

This is what desktop Spotify, Apple Music on Mac and YouTube Music on tablet all
converged on — the transport owns the bottom edge of the window, navigation owns
the left — and it buys something specific: **one morph instead of two.** The
full-screen player grows from the same rectangle on a phone and on a tablet, so
there is a single set of geometry to get right and a single one to keep right.

## Consequences

Porting this to the other clients means porting *the table above*, not the
Kotlin. Each client keeps its own transitions and its own idioms; what has to
match is which panel shows where, and that there is one piece of state behind it.

The one thing that does not travel is the collapse gesture. Android drives the
morph from predictive back, which has no iOS equivalent; iOS drags the drawer
down, which Android does not do. Same object, same states, different hands.

## What was rejected

**A navigation rail that runs the full height, with the dock inset beside it.**
More conventionally Material, and it forks the morph: the player would launch
from a different rectangle depending on width, which is two animations to build
and two to maintain.

**A floating navigation bar, matching iOS.** Android has no floating primary
navigation — `NavigationBar`, `ShortNavigationBar` and `WideNavigationRail` are
all edge-attached, and Material's floating toolbar is a contextual-action
component, not navigation. Fixed navigation with a floating dock is both the
platform's idiom and, as it turns out, the arrangement that keeps the dock's
geometry constant.

**Porting iOS's scroll-minimize blob split.** It depends on the bar and the
island being one floating surface, which fixed navigation rules out, and on a
gooey metaball merge that has no Compose equivalent without a custom shader.
Replaced by the platform's own idiom: the navigation bar hides on scroll, and the
dock descends into the space it vacates. Same beat, native gesture, less code.
