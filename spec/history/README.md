# `spec/history` — the listening-history contract

Mozz syncs its listening history between devices so the taste profile behind
recommendations doesn't fork. Each event is identified by a **content-derived
uid**:

```
uid = SHA-256(canonicalUIDBytes(event))[0..16]   // 128 bits, 32 lowercase hex
```

## Why history has to sync at all

Every backend records a *scrobble* — a completed play. **None of them record a
skip, and none record a partial listen.** `TasteProfile` weights those heavily
and in opposite directions:

| Signal | Weight |
|---|---:|
| liked | +1.5 |
| completed | +1.0 |
| started | +0.2 |
| skipped | **−0.6** |
| unliked | −1.0 |

So the signal that actually personalizes Mozz exists nowhere but the local
`play_event` log. An hour of listening on a second device isn't merely unsynced
— it's gone, permanently, and the two devices' recommendations drift apart.

## Why this needs no consensus

ADR-0010 found that no available substrate offers compare-and-swap or atomic
append, which is why continuity ownership had to be reduced to best-effort.
History escapes that entirely, because of one property:

> **Play events are immutable facts, and are only ever added.**

A set that only grows is a **G-Set**, the simplest CRDT there is. Union is
idempotent, commutative and associative, so:

- devices can merge in any order and still agree
- a merge applied twice changes nothing
- no locking, no arbitration, no ownership
- no tombstones, because nothing is ever deleted

The only thing the union needs is a **stable identity per event**, so both sides
can tell "the same event" from "a different event". That is what the uid is, and
why it's content-derived: a local autoincrement means device A and device B both
call their first event `1`.

## The encoding

```
"h1" ␁ deviceID ␁ trackRef ␁ kind ␁ createdAtMS ␁ positionMS ␁ durationMS
```

Then SHA-256, truncated to the first 16 bytes.

| Rule | Value |
|---|---|
| Field separator | `U+0001` |
| Version prefix | `h1` |
| Text encoding | UTF-8, no normalization, no escaping |
| Times/positions | integer milliseconds, base 10 — **never** floating point |
| `nil` numeric fields | empty string, **not** `0` |
| Digest | SHA-256, first 128 bits, lowercase hex |

Two decisions worth understanding:

**`context`/`contextID` are excluded.** They describe an event without defining
it. Including them would mean the same listen, re-imported once richer context
was known, looked like a second listen.

**`deviceID` *is* included.** The same track played at the same instant on two
devices is genuinely two listening events, and collapsing them would silently
under-count.

**Truncation to 128 bits** is deliberate: these ride in a payload written to the
user's server on every sync, and a batch of a thousand events would pay 32 KB for
a second half of the digest that buys nothing. At any plausible scale a collision
is vanishingly unlikely, and its effect would be to deduplicate two events rather
than corrupt anything.

## `event-uid-fixtures.json`

| Case | Guards against |
|---|---|
| `completed-play` | the ordinary path |
| `skip-partway` | the signal no server records |
| `like-no-position` | `nil` position and duration, and an empty serverID in the ref |
| `position-zero-is-not-absent` | **`nil` vs `0`** — "no position recorded" and "position zero" are different facts, and a language that renders both as `0` collapses them |
| `unicode-track-ref` | non-ASCII in ids; a port that normalizes (NFC/NFD) or escapes strings diverges here and nowhere else |

Each carries the input, the expected canonical bytes (hex) and the expected uid.
The intermediate bytes are included on purpose: when two implementations
disagree, the bytes are where the difference is. SHA-256 is never what's wrong.

## Batches

History is written **one slot per device**, never one shared slot. Two devices
writing a shared slot would overwrite each other and there's no CAS to stop
them; with a slot each, every write is last-writer-wins over *that device's own*
history — a write it can always safely make, because it's the only author.

A batch carries `windowStartMS`, the oldest event it could contain. Without it a
reader can't distinguish "this device has played nothing since" from "this device
trimmed older events" — the events alone look identical in both cases.

Windowing keeps batches bounded: 180 days by default (the taste profile's 30-day
half-life makes anything older worth ~1.6%), further trimmed to the backend's
byte budget. When size binds, the **newest** events are kept.

## Two artifacts, because a year in review asks a different question

The raw event window above is tuned for **taste**: recent, precise, and trimmed
oldest-first when space runs out. That is exactly wrong for a **year in review**,
which needs the whole year and cares most about the months the window would drop
first.

So history publishes a second artifact per device — a compact `HistoryRollup`
(`Sources/MozzHistory/HistoryRollup.swift`):

| | Raw events | Rollup |
|---|---|---|
| Span | 180 days | a full calendar year |
| Detail | every event | monthly totals + top artists/albums/tracks |
| Size (heavy listener) | megabytes | a few KB |
| Merge | G-Set union by uid | per-device totals, summed across devices |
| Purpose | taste profile | year in review |

Three things make the split necessary rather than merely tidy:

1. **A year of raw events is megabytes per device**, in a record every device
   re-uploads on every write. A year of totals is kilobytes.
2. **Trimming oldest-first destroys January**, which a December review needs
   most.
3. **Names disappear.** Play events are keyed on `trackRef` and deliberately
   outlive the catalog, so when a server drops an album the events remain but
   nothing can name them. Rollups capture names **at play time**, so a review
   still reads correctly years later.

Note the local/sync asymmetry that makes this work: the local `play_event` table
is *never* pruned, so a device can always rebuild its own full year even though
it only *syncs* 180 days of raw events. The rollup is what carries the rest
across devices.

### Why the rollup merge is still coordination-free

Counts cannot be a G-Set — adding two devices' totals twice would double them.
But the same per-device-slot arrangement solves it: each device publishes *its
own complete totals*, and merging **replaces** that device's contribution before
summing across devices. That is a state-based CRDT, so it stays idempotent,
commutative and associative, and still needs no compare-and-swap.

**One honest limitation.** Each device publishes only its top 200 entries, so an
artist ranked just below the cutoff on *every* device is missing from the merge
even if their combined total would place them well inside it. This is inherent to
merging truncated top-K lists; the only complete fix is shipping every key, which
is the cost the rollup exists to avoid.

## Verifying an implementation

Swift conformance runs in the normal suite
(`Tests/MozzHistoryTests/HistorySpecConformanceTests.swift`).

Any other language: read the file, recompute both values per case, compare.

```python
import json, hashlib

spec = json.load(open("spec/history/event-uid-fixtures.json"))
for case in spec["cases"]:
    raw = your_canonical_bytes(case["input"])
    assert raw.hex() == case["canonicalBytesHex"], case["name"]
    assert hashlib.sha256(raw).hexdigest()[:32] == case["uid"], case["name"]
```

## Changing the encoding

Don't, casually. A changed uid doesn't throw — it makes every already-synced
event look brand new, so the next sync re-imports the user's entire history as
duplicates and **double-counts every play** in their taste profile.

If it must change: bump the `h1` prefix, keep reading the old form, and add
fixtures for the new version alongside the old rather than replacing them.

## Regenerating

Generated from the Swift implementation, then verified against an **independent**
SHA-256 (Python's `hashlib`) so a bug in one library can't quietly certify
itself. Re-verify independently if you ever regenerate.
