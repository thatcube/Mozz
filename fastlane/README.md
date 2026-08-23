# Shipping Mozz

Everything here runs on an App Store Connect API key, so no Apple ID password
and no 2FA prompt. Secrets live in `.env.fastlane` at the repo root, which is
gitignored along with the `.p8` key it points at — neither ever gets committed.

Start from `.env.fastlane.example`:

```sh
cp .env.fastlane.example .env.fastlane
$EDITOR .env.fastlane
```

Every lane takes `--env fastlane` to load it.

## One-time setup

```sh
fastlane bootstrap_testflight --env fastlane
```

This fills in the parts of App Store Connect a build alone doesn't:

- the beta description and feedback address testers see in TestFlight,
- the App Review contact details and demo account,
- an external tester group with a **public join link** enabled.

It's idempotent — running it again updates rather than duplicates.

### The demo account is not optional

Mozz has no catalogue of its own; it plays what's on a server you own. A
reviewer who can't sign in sees a login form and nothing else, which is a
rejection under guideline 2.1. So `MOZZ_DEMO_SERVER_URL`,
`MOZZ_DEMO_ACCOUNT_NAME` and `MOZZ_DEMO_ACCOUNT_PASSWORD` need to point at a
server reachable from outside your network that stays up for the length of the
review.

Whatever music is on it should be freely licensed — public domain or Creative
Commons — since Apple will stream it.

## Shipping a beta

Write what testers should look at, then ship:

```sh
echo "Lyrics, and CarPlay." > WHAT_TO_TEST.txt
fastlane beta --env fastlane
```

`beta` takes the next build number from TestFlight itself — not the commit
count, which can go backwards between branches — bakes it into the app and the
widget extension together, archives, uploads, and submits to Apple's beta review
for external distribution.

Notes can also come from the environment, which is easier to script:

```sh
MOZZ_WHATS_NEW="Lyrics, and CarPlay." fastlane beta --env fastlane
```

Beta review usually clears within a day. Once it does:

```sh
fastlane testflight_link --env fastlane
```

prints the public URL anyone can use to join.

## Shipping to the App Store

```sh
fastlane release --env fastlane
```

This uploads the binary. Screenshots, description, and the actual "submit for
review" step stay in the App Store Connect web UI — deliberately, since those
are worth looking at with your own eyes before they go out.

The version comes from `MARKETING_VERSION` in `project.yml`, which stays the
single source of truth. Bump it there before a release.

## Other lanes

| Lane | What it does |
| --- | --- |
| `build` | Archives a signed `.ipa` into `build/`, uploads nothing |
| `generate_project` | Just regenerates `Mozz.xcodeproj` |
| `testflight_link` | Prints the public beta link |

## Why a release Xcode gets forced

This machine runs the Xcode beta as its active toolchain, and App Store Connect
rejects anything built against a beta SDK (`altool` error 90534). Every lane
that compiles calls `select_release_xcode` first, which points `DEVELOPER_DIR`
at a release Xcode automatically. If only a beta is installed the lane stops
with an explanation, rather than spending a build on an upload that would
bounce.
