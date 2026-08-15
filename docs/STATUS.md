# Status

Updated 2026-08-15.

## Where this is

**Built and pushed: a complete Xcode project.** Open `alarm-app/OneAlarm.xcodeproj`, set your Apple
ID as the signing team, press play. `BUILD.md` walks through it step by step.

**Never compiled.** This session runs on Linux with no Swift toolchain and no Xcode, verified rather
than assumed. Every line is written against the pinned API surface in `RESEARCH.md` and reviewed by
a panel, but no compiler has seen it. Expect at least one build error and send over the first one.

## What works without anything from you

The **iPhone leg needs no credentials, no network and no accounts.** Install, grant the alarm
permission once, set a time, press Set all alarms. That is a real system alarm that rings through
Silent mode and Focus, shows on the Lock Screen and Dynamic Island, and mirrors to a paired Apple
Watch with no extra work.

That was the deliberate shape of v1: the thing that must never fail depends on nothing.

## What needs you

| | Why |
|---|---|
| **A Mac with Xcode 26** | No way around it. iPhone apps are built by Xcode, and Xcode is macOS only. |
| **An existing Eight Sleep alarm** | OneAlarm moves the alarm you already have rather than creating one. |
| **An existing Whoop smart alarm** | Same reason. |
| **Your Whoop model** | If it is a 4.0, the Bluetooth path is better than what is built and worth switching to. |

## Decisions taken without asking

The goal was something testable today, so these were made rather than queued.

**Alert only, no snooze.** Snooze requires a countdown presentation, which makes a Widget Extension
mandatory. Skip the extension and the system dismisses alarms and fails to alert, silently. A whole
extra target for a feature nobody asked for.

**Read modify write on both remote legs.** Neither adapter creates an alarm. This is what makes the
Eight Sleep leg safe rather than a gamble: the reference library's create payload and its documented
read shape disagree about field names, in the same file, thirty lines apart. Echoing back whatever
the server sent means the contradiction cannot bite, and your vibration, thermal and smart wake
settings survive untouched.

**Whoop over HTTP, not Bluetooth.** The BLE path is better in almost every respect, no credentials
stored, no terms of service exposure, nothing to break when Whoop changes a backend, and it is
already Swift. But it is only hardware verified on a WHOOP 4.0 and the model is unknown. HTTP works
on all of them. Worth revisiting.

**iOS 26.1 minimum, not 26.0.** Lets the current AlarmKit alert initialiser be used with no
availability branching.

**Swift 5 language mode.** Strict concurrency violations stay warnings instead of errors, which
matters a lot for code that cannot be iterated against a compiler here.

## Not built, on purpose

Snooze and its widget extension. The webhook and Home Assistant output. Background token refresh
via `BGTaskScheduler`, since refresh on foreground carries this on its own and the background path
is unreliable enough that promising it would be dishonest. Biometric lock on the connections screen.
Fitbit, whose legacy API deprecates next month anyway.

## Known limits, stated rather than buried

- **Whoop stops working after roughly a month** and needs a fresh sign in with an SMS code. Their
  refresh token is opaque, so its expiry cannot be read in advance and there is no way to warn you
  before it happens.
- **Eight Sleep alarms are gated behind an active subscription.** If that lapses, sign in still
  succeeds and the alarm call returns 403. It surfaces as its own message rather than a generic
  failure.
- **The Whoop write may not reach the strap.** The reference project deliberately skips the
  `strap-status` push and relies on the official app to sync. Whether the strap actually buzzes
  without it is genuinely unknown. The read back confirms Whoop's servers accepted the time; it
  cannot confirm the band vibrated.
- **Neither remote API is official.** Both can change without warning. The Whoop client fingerprint
  in particular was captured in May and goes stale around November.
- **This cannot go on the App Store**, and was not designed to.
