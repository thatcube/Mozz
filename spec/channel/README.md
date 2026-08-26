# `spec/channel` — how devices write without colliding

Ten devices can be playing at once. They are all members of one circle, holding
one `channelKey`, writing to one relay. Nothing may be lost and nothing may
overwrite anything else.

The usual attempt is a shared object plus a merge strategy, and it usually
fails: two devices read `history.blob`, both append locally, both write, and
whoever writes second silently erases the other's evening. Conflict resolution
then becomes a permanent tax on a problem that did not need to exist.

**So there are no shared objects.** Every object in a channel is owned by exactly
one device, and no device ever writes an object another device writes. Collisions
are not resolved; they are unrepresentable.

## Layout

```
c/{channelId}/d/{deviceId}/history/{epoch}/{seq}    append-only play events
c/{channelId}/d/{deviceId}/history/{epoch}/compact  this device's rolled-up past
c/{channelId}/d/{deviceId}/state/{epoch}            likes, settings — latest wins
c/{channelId}/d/{deviceId}/library/{epoch}          library snapshot, if made here
c/{channelId}/d/{deviceId}/servers/{epoch}          server connections and tokens
c/{channelId}/now/{epoch}                           see "Now playing" below
```

`deviceId` is assigned at pairing and never reused. `seq` is a per-device counter
that only increases. `epoch` comes from the circle's key rotation, so a removed
device's objects become unreadable rather than merely ignored.

Reading is: list every `d/*` prefix, read what is there, merge. Writing is:
append under your own prefix. A device asleep for a month reads everyone else's
log and catches up, and nobody had to coordinate.

## Why history merges trivially

A play is an **event**, not a state. "The phone played *Mambo Sun* at 14:32" does
not conflict with "the Mac played *Kashmir* at 14:32" — both happened, both are
true. The merge of two event logs is their union, and union is commutative,
associative and idempotent, which is exactly why this survives a device syncing
twice or arriving out of order.

It is also why a skip is worth recording as its own event rather than a mutation
of an existing one.

## Clocks are a hint, not an order

Devices have wrong clocks. A phone three hours off would, under naive wall-clock
sorting, scatter its evening through someone else's afternoon.

Every event therefore carries two things:

- `seq` — the device's own monotonic counter. **Authoritative within that device.**
- `at` — the device's wall clock, integer milliseconds. **A hint across devices.**

Within one device the order is exact. Across devices it is approximate, and that
is sufficient: nothing Mozz does needs a total order over two devices' plays.
"What did I listen to this year" tolerates seconds of disagreement. Anything that
genuinely needed a total order would be a design mistake here, because there is
no authority to provide one and inventing a clock server would reintroduce the
thing this architecture exists to avoid.

## Servers sync, under their own key

A server added on the phone must appear on the PC. Anything else means the app
works until the day the user does something completely reasonable, and then
quietly does not.

`servers/` therefore syncs like everything else, with one difference: it is
encrypted with `credentialsKey` rather than `channelKey`, and that key lives in
the platform secure store — Keychain, Keystore, DPAPI — while `channelKey` can
sit in ordinary app storage.

That distinction is the entire point. Someone who copies the app's files or
restores its backup gets a listening history. Reading the tokens additionally
requires the secure store, which is a different and much harder thing to reach.
Compartmentalisation by key alone would be decoration; compartmentalisation by
storage tier is real.

It merges like any other state object: newest write per server id wins, and a
device that has not seen a server simply learns about it.

## Mutable things, and the honest limit

Likes and playback settings are state rather than events — there is one current
answer, not an accumulating list. Each device writes its own `state` object with
a timestamp per field, and the newest write per field wins.

That is last-writer-wins, and it can lose an edit: like a track on the phone,
unlike it on the Mac within the same minute while both are offline, and one of
those disappears. A real limitation, stated rather than hidden. It is acceptable
because the loss is one toggle a user can see and redo, not a month of history —
and the alternative, a CRDT per field, is a great deal of machinery for a problem
measured in individual likes.

**Playlists are deliberately not here.** Ordered mutable collections are the case
last-writer-wins handles worst, and Plex, Jellyfin and Subsonic all own playlists
already. Mozz does not need a second, worse copy.

## Now playing

`now/{epoch}` is the one object more than one device writes, and it is the
exception that proves the rule: it is not a merge, it is a claim. Whichever
device is actually producing sound writes it; the others read it to offer
"listen here instead". Ownership and the handoff rules belong to ADR-0010, which
already settled that a stored checkpoint must not decide who is playing.

Because it is a claim rather than accumulated truth, a lost write costs nothing —
the next one arrives seconds later.

## Compaction

A device that has played music for two years should not make every other device
read two years of objects. Each device periodically rolls its own old events into
`compact` and deletes what it absorbed.

**A device only ever compacts its own prefix.** Compaction is where a design like
this usually acquires its first cross-device write, and with it its first real
conflict. Readers take `compact` plus any `seq` above its high-water mark.

## What this costs

- **Reads scale with device count.** Ten devices means ten prefixes to list. At
  these sizes that is nothing, and compaction keeps object counts flat.
- **A device that never syncs holds unique data.** Its log exists only there. That
  is the accountless trade, the same one stated in `spec/pairing`.
- **Last-writer-wins can lose a toggle.** Said above, said plainly, accepted.
