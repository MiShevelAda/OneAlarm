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

## Status

Pre-implementation. Phase 0 research and the Phase 1 plan are in `docs/`. Nothing is built yet.

- `docs/RESEARCH.md`: pinned versions, endpoint specs, citations
- `docs/PLAN.md`: architecture, agent roster, sequencing, definition of done
- `docs/STATUS.md`: running build progress, once Phase 2 starts

## This app cannot ship on the App Store

Two of the three integrations talk to private, reverse-engineered APIs. Apple will reject that.
The target is a personal developer build, signed with a personal Apple Developer account and
installed on one device. Nothing here is designed for distribution, and it should not be.

## Ground rules for anyone working on this

- Personal use, single account. Never send destructive, firmware or wipe commands to any device.
- Respect rate limits. Single-digit requests per second, with backoff.
- Credentials and tokens live in the iOS Keychain and nowhere else. Never in UserDefaults, never
  in plaintext, never logged, never committed.
- Local first. No backend we do not control, no telemetry, no third-party analytics.
- Every device write passes a preview and confirm gate in debug builds, so the exact outbound
  payload is visible before it fires.

## Repo note

This folder is a standalone project. It currently sits inside another repository for convenience
only and has no dependency on anything outside `alarm-app/`. It is meant to be lifted out into its
own repo unchanged.
