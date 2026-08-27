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
c/{channelId}/d/{deviceId}/catalog/{epoch}/{scope}/
    {kind}/{hash}                                   bounded catalog chunks
    index/{hash}                                    one complete snapshot index
c/{channelId}/d/{deviceId}/servers/{epoch}          server connections and tokens
c/{channelId}/manifests/{epoch}/{deviceId}/{gen}-{hash}
                                                    immutable object hashes
c/{channelId}/now/{epoch}                           see "Now playing" below
```

`deviceId` is assigned at pairing and never reused. `seq` is a per-device counter
that only increases. `epoch` comes from the circle's key rotation, so a removed
device's objects become unreadable rather than merely ignored.

Reading is: list every `d/*` prefix, read what is there, merge. Writing is:
append under your own prefix. A device asleep for a month reads everyone else's
log and catches up, and nobody had to coordinate.

The manifest follows the same rule: generations are immutable and grouped per
device, never one mutable record for the channel. Readers choose the greatest
generation (breaking an impossible same-device tie by path). They sit together
under a manifest-only prefix so a list never has to walk years of
content-addressed history objects. Old generations expire by bucket lifecycle.

This avoids requiring compare-and-swap from the provider. B2's native API has
none, and pretending a read-then-write is atomic would be worse than admitting
it. A channel-wide manifest would make every device its writer and reintroduce
the overwrite race this layout exists to eliminate.

## Why history merges trivially

A play is an **event**, not a state. "The phone played *Mambo Sun* at 14:32" does
not conflict with "the Mac played *Kashmir* at 14:32" — both happened, both are
true. The merge of two event logs is their union, and union is commutative,
associative and idempotent, which is exactly why this survives a device syncing
twice or arriving out of order.

It is also why a skip is worth recording as its own event rather than a mutation
of an existing one.

## Catalog snapshots warm a device; they never become authority

A newly joined PC should not spend minutes showing an empty library when another
circle member already mirrored the same server. After a complete server sync, a
device publishes a catalog snapshot under `channelKey`. Another device with an
empty local catalog may hydrate it, render immediately, and then run the normal
full server sync in the background.

The scope is exact: backend, stable server id, account/profile id, and selected
music-library ids. A Plex Home child's snapshot must never warm the owner's
database, and changing the selected libraries creates a different scope rather
than silently mixing the two catalogs. Plex's default "all music libraries" is
recorded as that intent (and scoped as `*`), not collapsed to whichever section
happened to be listed first; every desktop shell preserves the same meaning and
the full resolved section list.

Large libraries are split into bounded, content-addressed chunks for artists,
albums, tracks, playlists, and ordered playlist membership. Chunks are uploaded
first. Only after every chunk exists does the device publish an encrypted index
through its manifest, so a failed upload leaves unreachable garbage rather than
half a current snapshot. Re-publishing an unchanged catalog writes no chunk
bodies.

Catalogs do **not** merge entity-by-entity. They are coherent caches taken at one
point in time; combining two can resurrect a track one device saw before it was
deleted. Readers choose the newest complete snapshot for the exact scope,
breaking a timestamp tie by device id, and reject it as a whole if any chunk is
missing or fails authentication. The media server then reconciles everything.

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

### Removal has to be written down

Adding merges for free. Removing does not, and the layout above is the reason:
every device writes only under its own prefix, and reading is the union of all
of them. Drop a server from the phone's object and the PC's object still lists
it, so the union puts it back. **A server the user deleted reappears**, which is
worse than not supporting deletion at all, because it looks like the app
ignoring them.

So removal is a write rather than an absence. A deleted server stays in the
object carrying `removedAt`, and the merge compares every entry for a given
server id — tombstone and live alike — taking the newest. A device that has
been asleep learns the removal the same way it learns anything else.

Tombstones for servers are kept forever. There are a handful of them per user,
so the storage argument for expiring them does not exist, and an expiring
tombstone is exactly how a deletion comes back months later.

The honest edge: this comparison uses wall clock, which everywhere else in this
document is called a hint rather than an authority. Removing a server on one
device and re-adding it on another within a few seconds is genuinely ambiguous.
It is also not a thing people do, and the alternative — a tombstone that always
beats a live entry — would make re-adding a server impossible, which people
*do* do.

### On Plex, a token is a person as well as a server

Plex Home lets one account hold several users, and **managed users have no
plex.tv login at all** — no email, no password. They exist only as profiles
under the admin account. So the PIN flow Mozz uses today cannot sign them in;
there is nothing for them to type. Today Mozz is not merely inconvenient for a
managed user, it is unusable by them, and every play it records lands on the
account owner's Plex history instead of theirs.

The way in is `GET /api/v2/home/users`, then
`POST /api/v2/home/users/{uuid}/switch`, which returns *that user's* token
derived from the admin one. Protected users need their PIN to switch.

`servers/` therefore stores **the switched token, not the admin token plus a
uuid.** Syncing the admin token would mean every device in the circle could
assume any profile in the Home, which hands a phone the keys to a household.
The switched token can do exactly what its user can do and nothing more.

The uuid and display name ride alongside it, for two reasons that are not
cosmetic: play state has to be attributed to the right Plex user, and a device
needs to be able to notice that a token belongs to someone other than who the
channel says it does.

The price of least privilege, stated plainly: a switched token that is revoked
cannot be re-derived, because no device holds the admin token any more. That
costs one re-authentication on one device. Holding the admin token everywhere
to avoid it would be a worse trade.

Jellyfin and Subsonic have no equivalent — their users are separate accounts
with their own credentials, so choosing one *is* logging in. This is Plex-only.

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
