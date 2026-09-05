# Symfonium — onboarding and settings, as a reference

Screenshots captured 2026-09-04 on a Pixel, Symfonium on its free trial, pointed at the same
Plex server Mozz is developed against. Kept because Symfonium is the closest thing to a peer
Mozz has on Android — it is the app a Plex-or-Jellyfin user on Android most likely already owns,
and it has clearly been through the onboarding problems Mozz is walking into now.

These are one person's screenshots of one build on one device, not a spec. Where a screen looks
better than ours, the interesting question is usually *why* rather than *what it looks like*.

| File | Screen |
|---|---|
| `01-welcome-where-is-your-music.png` | First run — device vs. network/cloud |
| `02-select-primary-music-source.png` | Provider grid, after choosing "network server" |
| `03-home-while-syncing.png` | Home during the first library sync |
| `04-settings-root.png` | Settings root |

---

## 1 — "Where is your music located?"

Two large targets: **On this device** and **On a network server or cloud provider**, each with a
sentence of plain explanation underneath. The provider list is *not* on this screen; it is one tap
deeper. The trial notice sits at the bottom, after the choice, not before it.

What seems worth taking:

- **The first question is about the user's situation, not about our feature list.** "Where is your
  music?" is answerable by someone who has never heard of Jellyfin. "Choose a backend" is not.
- Deferring the 13-provider grid one level keeps the first screen from reading as a wall.
- The paid-app disclosure is placed after the user has seen what the app is for. Mozz is free, so
  this specific card has no analogue — but the ordering principle (orient first, terms second)
  probably still holds for anything we need to disclose.

What is less clearly right: "On this device" being co-equal with network sources is a Symfonium
product decision. Mozz is a self-hosted client; local files are not obviously our first-run branch.

## 2 — "Select your primary music source"

Providers grouped under three headings — **Media providers** (Plex, Emby, Jellyfin, (Open)Subsonic,
AudioBookShelf (Experimental), Kodi (19+)), **Cloud providers** (OneDrive, Box, pCloud, Google Drive,
Dropbox), **Network shares** (WebDAV, Samba (SMB v2/v3)). Each is a pill with the provider's own
logo. Footer: "Note: You can add more music locations after the initial setup."

Worth taking:

- **Real provider logos.** Recognition beats reading. Someone who runs Jellyfin finds the purple
  triangle before they finish reading the row.
- **The word "primary."** It says, without a paragraph, that this is not a one-time irreversible
  choice — reinforced by the footer note. Mozz supports multiple servers and should say so this
  cheaply.
- **Maturity is labelled inline** — "(Experimental)", "(19+)", "(Open)Subsonic". Honest, and it
  costs one parenthetical rather than a support thread.

Mozz's list is much shorter (Plex, Jellyfin, Subsonic). Three pills need no group headings; the
grouping here is a consequence of having thirteen.

## 3 — Home while the first sync runs

The home screen is live immediately, with a progress banner: "Syncing and scanning your library —
Artists: 3004 • Albums: 73 • Tracks: 0". Mix tiles (Track mix / Album mix / Decade mix) are already
tappable. Every content shelf below shows its own placeholder: "Your data is being synced with your
media provider. Please wait for the end of the process."

Worth taking:

- **Running counts, not a percentage.** Symfonium does not know the total up front, so it does not
  invent one. It shows what it has actually ingested. This is directly relevant to our sonic
  analysis progress UI, where the honest number is also "n done" and the total is only known
  because we enumerated the library first.
- **Per-shelf placeholders rather than one global spinner.** The user learns which parts are
  waiting on what.
- **The counts are visibly lopsided** (3004 artists, 73 albums, 0 tracks) because the sync fills
  entity types in passes. It looks odd mid-flight. If Mozz shows counts during sync, the ordering
  is worth thinking about — or say "found so far" rather than implying a finished tally.

## 4 — Settings root

Two dismissible cards at top (trial expiry + purchase; the "Don't kill my app" manufacturer warning),
then **Settings**: Interface, Playback, Offline/cache/download, Android Auto, Advanced. Then
**Miscellaneous**: Manage media providers, Sync manager, and more below the fold.

Worth taking:

- **Five top-level settings groups.** Symfonium is a deep app and still resists a flat list.
- **The manufacturer-killing card.** On Android this is a real problem for anything doing background
  work, which now includes our sonic analysis worker. Symfonium links to dontkillmyapp.com rather
  than trying to explain OEM battery behaviour itself. If our analysis worker gets killed on
  Samsung/Xiaomi/OnePlus — plausible, untested — this is a cheap known answer.
- **"Manage media providers" and "Sync manager" are separate entries.** Identity/connection is not
  the same concern as what gets pulled down and when.

Note the icon on **Playback** is a radio set. Symfonium groups radio-ish behaviour under playback;
Mozz currently treats radio as a recommendation feature. Not obviously either right or wrong, but
worth knowing that a mature app in this space filed it the other way.

---

## The thing these screenshots do not show

Nothing here reveals how Symfonium builds its mixes. Track mix / Album mix / Decade mix are visible
on the home screen but their basis is not — metadata, play history, something acoustic, or a
combination. Mozz's bet is on-device sonic analysis (see `docs/adr/ADR-0018-on-device-sonic-analysis.md`),
which is a different bet from anything visible here, and these screenshots are not evidence either way.
