# `spec/continuity` — the cross-platform continuity contract

Mozz resumes playback across devices by writing a checkpoint to the user's own
server (ADR-0010). A queue is identified by a **content hash**:

```
queueHash = SHA-256(canonicalBytes(queue))
```

The whole design rests on one property: **a client on another platform, written
in another language, must compute the identical hash.** If it doesn't, the
receiving device decides the queue it just read doesn't match its cursor, and
continuity silently fails — no error, no crash, just "my queue didn't come
over".

That failure is invisible in every single-platform test suite, which is why the
contract lives here as language-neutral fixtures instead of only in Swift tests.

## The encoding

`canonicalBytes` is written by hand rather than via `JSONEncoder`, because stock
JSON is **not** canonical — key order and float formatting vary by
implementation and by language. The rules, which any reimplementation must
follow exactly:

| Rule | Value |
|---|---|
| Field separator | `U+0001` |
| Record separator | `U+0002` |
| Version prefix | `v1` |
| Text encoding | UTF-8, no normalization, no escaping |
| Durations/times | integer milliseconds, base 10 — **never** floating point |
| `nil` string fields | encoded as empty string |
| Digest | SHA-256, lowercase hex |

Header fields, in order:

```
v1 ⟂ descriptor.kind ⟂ descriptor.sourceID ⟂ descriptor.sourceRevision
   ⟂ repeatMode ⟂ isShuffled("1"/"0") ⟂ totalCount ⟂ startAbsoluteIndex
```

then one record per item, each being:

```
backend ␁ serverID ␁ accountID ␁ remoteID ␁ baseOrdinal
```

**Only identity-defining fields participate.** Display metadata — title, artist,
artwork — is deliberately excluded, so re-fetching richer metadata does not
invalidate an otherwise identical queue. The fixtures include that metadata in
their `input` purely to prove it makes no difference to the digest.

## `queue-hash-fixtures.json`

Each case carries the input, the expected **canonical bytes** (hex) and the
expected **hash**:

```json
{
  "name": "album-three-tracks",
  "queueHash": "018644cc…",
  "canonicalBytesHex": "76310261…",
  "canonicalByteCount": 168,
  "input": { "descriptor": {…}, "items": […], … }
}
```

The intermediate bytes are included on purpose. When two implementations
disagree on a hash, the bytes are where the difference actually is — comparing
them turns a guessing game into a five-minute diff. SHA-256 is never the thing
that's wrong; the encoding is.

### Cases, and what each one is defending

| Case | Guards against |
|---|---|
| `album-three-tracks` | The ordinary path — a plain album queue |
| `shuffled-playlist-window` | Shuffle/repeat participating in identity; a window not starting at 0 |
| `subsonic-adhoc-no-server-id` | Empty `serverID` (generic Subsonic has no protocol-level server UUID) and a `nil` descriptor source |
| `unicode-and-empty-fields` | **The one most likely to break a port.** Non-ASCII in ids and server names, mixed scripts, and empty vs `nil` fields. A language that escapes, normalizes (NFC/NFD), or re-encodes strings will produce different bytes here and nowhere else |

## Verifying an implementation

Swift conformance runs as part of the normal test suite
(`Tests/MozzContinuityTests/SpecConformanceTests.swift`).

Any other language: read the file, recompute both values per case, compare.
Nothing else is required — no Mozz code, no server.

```python
import json, hashlib

spec = json.load(open("spec/continuity/queue-hash-fixtures.json"))
for case in spec["cases"]:
    raw = your_canonical_bytes(case["input"])
    assert raw.hex() == case["canonicalBytesHex"], case["name"]
    assert hashlib.sha256(raw).hexdigest() == case["queueHash"], case["name"]
```

## Changing the encoding

Don't, casually. A changed hash means every checkpoint already written to every
user's server stops matching, and their queues stop resuming.

If it genuinely must change: bump the `v1` prefix, keep the old path for
reading, and add fixtures for the new version alongside the old ones rather
than replacing them.

## Regenerating

Fixtures are generated from the Swift implementation, then verified against an
**independent** SHA-256 (Python's `hashlib`) so a bug in one library can't
quietly certify itself. If a legitimate change requires regenerating, re-verify
independently — never trust the implementation to grade its own homework.
