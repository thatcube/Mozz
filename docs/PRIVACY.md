# Privacy

Your music library lives on your own Plex or Jellyfin server, and Mozz talks to
that server and nothing else — with one exception, spelled out below.

## What Mozz doesn't do

No Mozz account. No analytics, no tracking, no ad networks, no telemetry. Mozz
doesn't phone home to me or anyone else — there's no Mozz server to phone home
to.

## The one exception: recommendations

For radio and recommendations to be any good, the app needs to know which songs
actually sound alike. Genre tags can't do that on their own — in most libraries
a mellow pop song and a hard rock song both just say "rock," so a station seeded
from one happily plays the other. That's the single biggest thing that makes
recommendations feel dumb.

To fix it, Mozz looks up music-similarity data from two free, open, non-profit
services run by [MetaBrainz](https://metabrainz.org):

- **MusicBrainz** — matches your songs to a stable ID so they can be looked up.
- **ListenBrainz** — finds songs that people tend to play alongside yours.

To do that, Mozz sends the **artist name, track title, and/or MusicBrainz IDs**
of songs in your library to those services. It does **not** send your name, your
server address, your account, or anything about who you are. The requests aren't
tied to an identity — MetaBrainz just sees "something asked what's similar to
this song." Answers are cached on your device, so each lookup happens once.

## Turning it off

It's on by default, because it's most of what makes the app good and because
MetaBrainz is a non-profit with open data — not a company trying to monetize
you. If you'd rather Mozz stay fully offline, there's a switch in Settings to
turn it off. With it off, recommendations fall back to your library's own genre
tags: still works, just blunter.

## Scrobbling (if it ever ships)

If Mozz later adds scrobbling to Last.fm or ListenBrainz, that's a separate thing
you opt into and set up with your own account. It won't be on unless you turn it
on.
