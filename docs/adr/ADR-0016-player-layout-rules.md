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

## Also decided: one dock rule, two shapes

Navigation moves with width — a bar along the bottom on a phone, a rail down the
left when there is room. The dock is governed by a single rule at every size:

> centred over the **content area** (the window less any rail), full width less a
> margin, capped at 640dp.

On a phone the content is narrower than the cap, so the dock is simply full width
less a margin and nothing appears to be capped. On a tablet it stops growing and
floats as a centred capsule, with the rail running the full height behind it.

One rule, so there is still **one morph instead of two**: the player grows from
whatever rectangle the dock occupies, and that rectangle is computed the same way
everywhere.

*Superseded a first version of this section*, which had the dock spanning the
full window with the rail stopping above it. That was reasoned from desktop
players — Spotify, Apple Music on Mac — and it is a defensible arrangement, but
it is not the one Mozz wants: a bar welded across a tablet window reads heavier
than a floating capsule, and the capsule is what the design references call for.
The cap is what lets both fall out of one expression.

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
