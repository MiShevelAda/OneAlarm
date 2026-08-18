# OneAlarm

One wake time. Every device follows it.

Set a single master wake time. Per-device offset rules propagate it to Eight Sleep, Whoop and the
iPhone (plus the paired Apple Watch, which comes free with the iPhone alarm). Change the master
time once and everything recomputes.

The problem it solves: setting the same alarm three times by hand, in three apps, every time the
wake time moves.

## Default rules

| Device | Offset | Why |
|---|---|---|
| Eight Sleep | T minus 10 | Thermal and vibration ramp needs a run-up |
| Whoop | T minus 5 | Haptic smart-wake window |
| iPhone | T | The loud backstop that actually gets you up |
| Apple Watch | T | Mirrors the iPhone alarm automatically, no integration work |

## Getting started

- **`BUILD.md`**: getting it onto your iPhone. Three routes, including one with no Mac at all.
- **`CONNECT.md`**: connecting the iPhone, Eight Sleep and Whoop, and what to do in each app first.
- **`promo/`**: two competing promotional websites, to pick between. Nothing in there is published.

## Status

**Built. Never compiled.** A complete Xcode project: open it, set your Apple ID as the signing team,
press play. It was written on a Linux machine with no Swift compiler and no Xcode, so no compiler
has seen it yet. Expect a build error or two and send over the first one.

The iPhone leg needs no credentials, no network and no accounts, so it works the moment it installs.

- `docs/RESEARCH.md`: pinned versions, endpoint specs, citations
- `docs/PLAN.md`: architecture, sequencing, definition of done
- `docs/STATUS.md`: what works, what needs you, what was deliberately left out

## Where this can and cannot go

It uses no private Apple APIs. AlarmKit is a published Apple framework, so a personal build and
TestFlight internal testing are both genuinely open routes, and `BUILD.md` covers them.

What it does use is Whoop's and Eight Sleep's own internal web services, which is a question about
their terms rather than Apple's technical rules. That is why this is a personal, single account
build and why it should not be published to the public App Store.

## Ground rules for anyone working on this

- Personal use, single account. Never send destructive, firmware or wipe commands to any device.
- Respect rate limits. Single-digit requests per second, with backoff.
- Credentials and tokens live in the iOS Keychain and nowhere else. Never in UserDefaults, never
  in plaintext, never logged, never committed.
- Local first. No backend we do not control, no telemetry, no third-party analytics.
- Every device write passes a preview and confirm gate in debug builds, so the exact outbound
  payload is visible before it fires.

## Repo note

This is the app's only home. It spent its first two weeks inside `Alex_personal_brand` as
`alarm-app/`, on a branch, mirrored by hand into a second repo, which meant every change had to be
pushed twice and a stale copy was always one missed push away. That ended on 2026-08-18. The copy in
the brand repo is gone and both `claude/*` branches there are deleted.
