<p align="center"><img src="docs/brand/mozz_logo.svg" alt="Mozz logo" width="128" /></p>

<h1 align="center">Mozz</h1>

<p align="center">One app for your music, wherever it lives.<br />
A free, open-source player for the Plex, Jellyfin, or Subsonic server you already run.</p>

<p align="center">
  <a href="LICENSE"><img alt="License: GPL-3.0" src="https://img.shields.io/badge/License-GPL--3.0-blue.svg" /></a>
  <img alt="Platform: iOS and iPadOS" src="https://img.shields.io/badge/Platform-iOS%20%C2%B7%20iPadOS-lightgrey.svg" />
  <a href="https://github.com/sponsors/thatcube"><img alt="Sponsor" src="https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa.svg" /></a>
</p>

Mozz plays the music that lives on your own media server. Point it at **Plex**,
**Jellyfin**, or a **Subsonic / OpenSubsonic** server (tested against Navidrome)
and your whole library shows up on your iPhone and iPad — ready to stream over
the network or download and take with you.

Streaming and offline both matter here, equally. Some people stream everything
and never download a thing; others save their library and live underground on
the subway. Mozz is built for both, and it does not push you toward either.

**One app for your music, wherever it lives. Free forever. Open source.**

---

## Who it's for

You already self-host your music — on Plex, Jellyfin, Navidrome, or another
Subsonic-compatible server — and you want a fast, native iPhone and iPad player
that respects it: no second subscription, no re-uploading your library to
someone else's cloud, and no telemetry watching what you listen to.

## Features

### Your library, your servers

- **Bring your own server.** Connect Plex, Jellyfin, or Subsonic/OpenSubsonic and
  sign in the normal way for each — a Plex login, Jellyfin Quick Connect or
  password, or a Subsonic account. Choose exactly which libraries to pull in.
- **One tidy library.** Artists, albums, songs, playlists, and genres all live in
  one place, however your server organizes them.
- **Works when the network doesn't.** Your catalog is kept on the device, so
  browsing, searching, and opening albums stay instant even when the server is
  slow, far away, or offline.
- **Search that keeps up.** Results appear as you type, and accents and
  punctuation don't get in the way — "bjork" finds "Björk".

### Playback

- **Near-gapless.** Tracks flow into one another without a silent gap between
  them, the way an album is meant to play.
- **Smart shuffle.** Shuffle spreads your artists out instead of clumping the same
  one back to back, plus the usual repeat modes.
- **Even loudness.** Volume normalization keeps quiet and loud tracks at a
  comfortable level, so you're not reaching for the volume between songs.
- **A real equalizer.** A 10-band graphic EQ (31 Hz–16 kHz) with presets, for when
  you want to shape the sound.
- **Lyrics.** Time-synced lyrics that highlight and scroll the current line, with a
  full-screen mode for just the words. Mozz uses your server's lyrics first and
  falls back to [LRCLIB](https://lrclib.net) when there are none.
- **A player that flows.** Now Playing glides between a small bar above the tabs
  and the full-screen player — no jarring pop-up. Scrub, reorder what's up next,
  or tap through to the artist or album.

### Take it offline

- **Download for the road.** Save albums, playlists, or tracks to the device and
  play them straight from storage — no network needed, no quality loss.
- **Downloads that stick around.** Transfers keep going while the app is in the
  background, and re-syncing your library never loses what you've already saved.
- **Lyrics come too.** Saved lyrics travel with your downloads, so they're there
  when you're offline.

### Across your devices

- **Continue here.** Leave off on one device and Mozz can offer to pick playback up
  where you left it on another — resumed only when you choose, never yanked away.
- **Handoff & deep links.** Hand a screen off between your Apple devices, and
  `mozz://` links open straight to an album, artist, playlist, genre, or tab.
- **Sign in once.** Your server credentials travel between your own devices through
  the iCloud Keychain, so you don't retype them.

### Siri, CarPlay, HomePod & widgets

- **Ask for anything.** "Play …" a song, album, artist, playlist, genre, your liked
  songs, or a mix — from the Siri button, Shortcuts, or a **HomePod**, which hands
  the request to your iPhone and plays it back through the speaker.
- **CarPlay.** Your Home and Library on the car screen, with artwork, a shuffle
  shortcut, and an Up Next list. It reads the on-device library, so it stays quick
  where signal is poor and downloaded tracks keep playing when the server can't be
  reached.
- **Widgets.** Now Playing and Recently Played widgets for your Home Screen.

### Discovery

- **Mozz Weekly.** A weekly mix that rediscovers music already in your library,
  built right on the device.
- **Radio and mixes** seeded from what you're listening to.
- **Optional enrichment.** Turn it on to sharpen radio and mixes using open music
  databases (only song and artist names are sent); leave it off and recommendations
  stay entirely on your device.

### Ratings & favourites

- **Likes and stars, unified.** Jellyfin and Subsonic favourites and Plex's star
  ratings show up together as likes and ratings, and Mozz writes them back to your
  server where it's supported.

### Make it yours

- **Themes & appearance.** Light, dark, or follow the system, with a choice of dark
  looks and an optional Liquid Glass player finish on newer iOS.

### Also on the desktop

A companion **Mozz Desktop** app for **Windows, macOS, and Linux** shares the same
library, history, and taste as the phone. It's early and distributed as a build you
download rather than through an app store — see
[`clients/desktop/README.md`](clients/desktop/README.md).

---

## Requirements

- **iPhone or iPad** running iOS / iPadOS 17 or later.
- **A media server** you can reach: Plex, Jellyfin, or Subsonic / OpenSubsonic.
  Navidrome is the tested Subsonic target; other OpenSubsonic servers are
  best-effort.

## Getting started

1. Install Mozz on your iPhone or iPad (see [building it yourself](#contributing--development)
   below while a public release is in progress).
2. Open the app and choose your server type — Plex, Jellyfin, or Subsonic.
3. Sign in the way that server expects and pick the libraries you want.
4. Wait for your library to appear, then start streaming — or download some albums
   for offline.

## Privacy

Mozz has no backend of its own and collects nothing about you — no account, no
analytics, no tracking. It talks to **your** media server, to Plex's sign-in and
discovery service when you use Plex, and — only when you turn those features on — to
LRCLIB for lyrics and open music databases for recommendations, sending only the
minimum needed (song and artist names). Full details are in
[`docs/PRIVACY.md`](docs/PRIVACY.md).

## Reporting bugs & requesting features

Found a bug or have an idea? Please open an issue on
[GitHub Issues](https://github.com/thatcube/Mozz/issues). Clear steps to reproduce,
your server type, and what you expected all help.

## Contributing & development

Mozz is open source and contributions are welcome. Build instructions, the code
layout, testing, and how releases work live in
[`CONTRIBUTING.md`](CONTRIBUTING.md); the deeper design rationale is in
[`ARCHITECTURE.md`](ARCHITECTURE.md) and the notes and decision records under
[`docs/`](docs).

## Donate

Mozz is **free forever**. If it's earned a place on
your Home Screen and you'd like to chip in, you can sponsor development through
[GitHub Sponsors](https://github.com/sponsors/thatcube). It genuinely helps — but
not donating is completely fine, and you get every feature either way.

## License

Mozz is free software licensed under the **GNU General Public License v3.0**, with an
additional permission under section 7 allowing distribution through Apple's App Store
despite its DRM and code-signing requirements. See [`LICENSE`](LICENSE) for the full
terms.

Mozz is not affiliated with or endorsed by Plex, Jellyfin, Navidrome,
Subsonic/OpenSubsonic, MusicBrainz, ListenBrainz, or LRCLIB. All trademarks belong to
their respective owners.

<!-- app-family:start -->
<!-- Generated by https://github.com/thatcube/brando — edit apps.json there, not this block. -->

---

<p align="center"><b>More open source from Brandon</b></p>

<p align="center">
  <a href="https://github.com/thatcube/hozz" title="Hozz — Apple Health, exported to storage you own"><img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/hozz.svg" width="32" align="middle" alt="" />&nbsp;<b>Hozz</b></a>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://github.com/thatcube/Mozz" title="Mozz — Your music, wherever it lives"><img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/mozz.svg" width="32" align="middle" alt="" />&nbsp;<b>Mozz</b></a>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://github.com/thatcube/Plozz" title="Plozz — Movies &amp; TV on Apple TV, iPhone &amp; iPad"><img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/plozz.svg" width="32" align="middle" alt="" />&nbsp;<b>Plozz</b></a>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://github.com/thatcube/Twozz" title="Twozz — Twitch on Apple TV, with real emotes"><img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/twozz.svg" width="32" align="middle" alt="" />&nbsp;<b>Twozz</b></a>
</p>

<p align="center">
  <a href="https://brando.page">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thatcube/brando/main/logos/brando-white.svg" />
      <img src="https://raw.githubusercontent.com/thatcube/brando/main/logos/brando-black.svg" height="22" alt="Brandon Moore" />
    </picture>
  </a>
</p>
<!-- app-family:end -->
