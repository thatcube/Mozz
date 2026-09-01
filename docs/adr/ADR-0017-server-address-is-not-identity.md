# ADR-0017 — A server's address is not its identity

Status: **Proposed** (the enabler is in; the resolution path is not)

## Context

Plex does not have *an* address for a server. `api/v2/resources` returns several
candidate connections for the same machine — a LAN address, a remote address, and
a relay address that tunnels through Plex's own infrastructure — and which of
them works depends on the network the phone happens to be on.

Mozz picks one at sign-in and never asks again. `mozzServerId(kind:baseURL:)`
then derives the account's identity by hashing that address, and the catalogue,
the likes and the entire play history are keyed on the result.

Two consequences, both observed:

**The pinned address can die.** On 2026-09-01 the Android app was pinned to
`172-104-29-70.…plex.direct:8443` — a relay endpoint, Linode-hosted, chosen at
sign-in months earlier. TCP connected in 120ms and TLS failed instantly, five
times out of five, from the phone *and* from a laptop on the same network:

```
javax.net.ssl.SSLHandshakeException: connection closed
curl: (35) … exit 35, tls=0.000000s
```

Every cover in the app went grey and playback failed, while the same library was
fine on the iPhone and the TV — because those had re-resolved to a working
address. The failure is intermittent: it recovered on its own twenty minutes
later, which is exactly what makes it hard to recognise as an address problem
rather than a flaky app.

**Re-resolving would orphan the library.** Because identity is derived from the
address, pointing the account at a working address makes it, as far as the
database is concerned, a different server: a new empty catalogue, no likes, no
history.

## Decision

Identity belongs to the *account*, established once, and travels with it. The
address is a property that may change.

`attach` now accepts a `serverId` and uses it when given, deriving one only for
an account being met for the first time. Both clients pass the id they already
hold. This is the enabler and it is landed; nothing re-resolves yet.

## What is not decided

How to re-resolve, and it turns on a credential question rather than a technical
one.

`api/v2/resources` is account-scoped: it needs the Plex **account** token. Mozz
never stores that. `plexPinCheck` receives it, hands it straight to
`completeLogin`, and keeps only the per-server access token that comes back —
which is the narrower credential, and deliberately so.

Three ways forward, in order of how much they ask for:

1. **Store the candidate list at sign-in.** `discoverConnections` already returns
   every candidate with its own server access token. Persisting the addresses
   costs no new privilege — the token stored is the same class already held — and
   lets the app re-probe them in preference order whenever the pinned one fails.
   Takes effect only after a re-link, since existing accounts saved no list.
2. **Store the account token.** Simplest, works for existing accounts on next
   launch, and widens what a compromised device gives up from one server to the
   whole Plex account. That is a real trade and should be a deliberate one.
3. **Local discovery (GDM).** Plex servers answer a UDP broadcast on 32410–32414
   with no token at all. Credential-free and fixes the common case — being at
   home while pinned to a relay — but only the common case.

(1) is the honest default; (2) should not be adopted silently.

## Consequences

Until a resolution path exists, an account pinned to a bad address stays there,
and the symptom is a library that looks broken rather than a connection that is.
The retry and per-host cap on Android's artwork loader soften a *flaky* hop; they
do nothing for a dead one.
