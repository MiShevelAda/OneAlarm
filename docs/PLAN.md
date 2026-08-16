# OneAlarm: Phase 1 plan

Written 2026-08-15, after Phase 0. Read `RESEARCH.md` first, this plan assumes its findings.

**This document is the approval checkpoint. Nothing gets built until it is green-lit.**

---

## 0. Read this before the rest: the demo definition in the brief cannot be met from here

The brief asks for "a personal-device build where I enter one wake time, the app authenticates and
sets both alarms, core tests green" by end of today. That is not achievable from this session, and
the reasons are environmental rather than a matter of effort or scope.

This session runs in a **Linux x86-64 container**. Verified just now:

| Needed | Status here |
|---|---|
| macOS | not present, `uname` reports Linux |
| Xcode 26 and the iOS 26 SDK | not present, macOS-only |
| A Swift toolchain of any kind | **not installed**, `command -v swift` is empty |
| An iPhone to install on | not present |
| Network egress to `auth-api.8slp.net`, `app-api.8slp.net` | **blocked by policy**, 403 on the CONNECT tunnel |
| Network egress to `api.prod.whoop.com` | **blocked by policy**, 403 on the CONNECT tunnel |
| Network egress generally | works, GitHub returns 200, so this is host-specific blocking |

Three consequences, stated plainly:

1. **No Swift written here can be compiled, run, or tested here.** Not the app, not the RulesEngine,
   not its unit tests. Anything I hand over is code-shaped text that has never seen a compiler.
2. **The risk-first auth spike cannot run here even with credentials**, because the two hosts it
   would talk to are blocked at the proxy. This was the single most important item in the brief's
   sequencing, and it has to move to Alex's Mac.
3. **I cannot ever be the one who declares the demo working.** Only a run on his device can do that.

**What I am not going to do about it:** write Swift, assert it is correct, and call the demo done.
The brief says a smaller honest demo beats a broken complete one, and that applies to this document
too. The revised definition of done is in section 8, split into what this session can finish and
what only his machine can.

---

## 1. Four decisions I need from Alex

Three of these gate real work and one gates the whole Whoop leg. All are quick.

**1. Which Whoop is on the wrist: 4.0, or 5 / MG?**
This decides the entire Whoop architecture. On a **4.0**, the Bluetooth path is the better option by
a wide margin: already Swift, hardware-verified as actually buzzing, no credentials stored, no ToS
exposure, nothing that breaks when Whoop changes a backend. On a **5 or MG**, BLE firing is
unverified and the HTTP path becomes the only option, with everything in section 2.4 of the research
attached to it. `[blocking for the Whoop leg only]`

**2. Is the Eight Sleep subscription currently active?**
A live bug report from April shows the alarm endpoint returning `403 {"message": "subscription
required"}`. Auth succeeds and the alarm call is what fails, so without checking this we would find
out late and misread it as a bug in our code. `[blocking for the Eight Sleep leg]`

**3. Is the iPhone on iOS 26.1 or later?**
AlarmKit needs 26.0 minimum. 26.1 changed the alert API, and targeting 26.1+ lets us use the current
initializer with no deprecation branch. `[non-blocking, I will assume 26.1+]`

**4. Whoop ToS: accepted or not?**
Only relevant if the answer to (1) is 5 or MG, since the BLE path carries no account risk. The
maintainer of the reference project puts it bluntly: Whoop's terms let them suspend API access or
terminate the membership, and "if losing your Whoop account would be a problem for you, don't use
this." Blast radius is exactly one personal membership. This is Alex's call, not mine.
`[blocking for the Whoop HTTP path only]`

I will not block the whole build on these. Everything in section 6 up to and including the
RulesEngine is independent of all four.

---

## 2. Architecture

```
SwiftUI views
      |
WakeSchedule store            master time + rules, the single source of truth
      |
RulesEngine                   pure, deterministic, no I/O, fully unit-testable
      |  produces [ResolvedTarget]
      |
DeviceAdapter protocol
      |
      +-- AlarmKitAdapter       local, Apple framework
      +-- EightSleepAdapter     HTTPS, OAuth password grant
      +-- WhoopAdapter          BLE or HTTPS, decided by question 1
```

No server. No shared state beyond the device. Keychain for credentials. The app talks directly to
each device over HTTPS or Bluetooth.

### 2.1 The core problem the RulesEngine solves

The three legs express time in three incompatible ways, and this is the main source of correctness
risk in the whole product:

| Leg | Time representation | Who owns the timezone |
|---|---|---|
| AlarmKit | `.relative(Time(hour:minute:))` plus `.weekly([Locale.Weekday])` | the device, automatically |
| Eight Sleep | bare wall-clock string `"07:00:00"`, no offset | **the server, invisibly** |
| Whoop HTTP | wall clock plus a fixed offset string `"-0700"` | us, **with no DST handling** |
| Whoop BLE | absolute epoch, one-shot | us, entirely |

Note AlarmKit and Eight Sleep are opposite conventions, and the Whoop paths are opposite to each
other. Handing each adapter a raw `Date` and hoping is how this ships a wrong alarm.

**So the RulesEngine produces one unambiguous canonical intent and every adapter projects from it:**

```swift
struct ResolvedTarget {
    let device: DeviceID
    let localTime: WallClockTime        // hour, minute after the offset is applied
    let weekdays: Set<Locale.Weekday>   // may differ from master if the offset crossed midnight
    let dayShift: Int                   // -1 when the offset pushed it to the previous day
    let nextOccurrence: Date            // absolute UTC instant, the verification anchor
}
```

`nextOccurrence` is what makes verification possible. Eight Sleep returns a UTC `nextTimestamp` on
read-back, and comparing it against this field is the only way to detect that the server resolved
our wall-clock string against a timezone we did not expect. The research is explicit that the client
cannot detect this from the write alone, so **read-back verification is part of the adapter protocol,
not an optional extra.**

### 2.2 The DeviceAdapter protocol

```swift
protocol DeviceAdapter {
    var device: DeviceID { get }
    var authState: AuthState { get }              // connected | needsReauth | disconnected

    func preview(_ target: ResolvedTarget) throws -> WritePreview   // no I/O, pure
    func write(_ target: ResolvedTarget) async throws -> WriteReceipt
    func verify(_ receipt: WriteReceipt, against target: ResolvedTarget) async throws -> Verification
}
```

Three things this shape buys us:

- **`preview` performs no I/O and is pure**, so the debug preview gate can show the exact outbound
  payload without any risk of sending it, and preview output is unit-testable against fixtures.
- **`verify` is separate from `write`**, so "the write returned 200" and "the alarm is actually set
  for the instant we meant" are different results. The research is emphatic that a 200 is not
  evidence on either remote leg.
- **Adapters cannot express a destructive operation.** The protocol has no delete, no temperature,
  no base angle. Each adapter holds an **allowlist** of the paths it may call, not a blocklist,
  which is what the research recommends given how much destructive surface both bearer tokens reach.

### 2.3 Data model

```swift
struct WakeSchedule {
    var masterTime: WallClockTime
    var weekdays: Set<Locale.Weekday>
    var rules: [DeviceRule]
}

struct DeviceRule {
    var device: DeviceID
    var offsetMinutes: Int      // negative is earlier. Eight Sleep -10, Whoop -5, iPhone 0
    var isEnabled: Bool
    var weekdayOverride: Set<Locale.Weekday>?
}
```

Persisted as JSON in Application Support. **No credentials in this file**, it holds only schedule
data, so it is safe to back up and inspect.

---

## 3. Agent roster

Defined as `.claude/agents/*.md` files, one per agent. **Correcting the brief on two points, both
from current documentation:** Claude Code reads `CLAUDE.md`, not `AGENTS.md`, and agent definitions
live in `.claude/agents/`, which is a third location distinct from both. And **this should not run
as an Agent Teams session**: teams are experimental, every teammate is a full session so cost scales
linearly, and the docs are direct that sequential same-file work is exactly what teams handle worse
than subagents. In-session subagents with one lead is the right shape here.

| Agent | Model | Tools | Owns | Done when |
|---|---|---|---|---|
| `orchestrator` (me) | opus | all | decomposition, integration, the merge, this document | none |
| `researcher` | opus | Read, Grep, Glob, WebSearch, WebFetch. **No write tools** | Phase 0, on call for spec lookups | `RESEARCH.md`, delivered |
| `ios-lead` | opus | Read, Edit, Write, Grep, Glob, Bash | app shell, AlarmKitAdapter, RulesEngine, Keychain layer | RulesEngine passes its tests on a Mac |
| `integrations-dev` | opus | Read, Edit, Write, Grep, Glob, Bash | EightSleepAdapter, WhoopAdapter, the spike CLI | contract tests pass against fixtures |
| `designer` | sonnet | Read, Edit, Write, Grep, Glob | the single-screen UX, tokens, the five states | a spec `ios-lead` can implement without asking questions |
| `security-reviewer` | opus | Read, Grep, Glob. **No write tools. Veto over merge** | credential paths, the write gate, secrets hygiene | sign-off, or a named list of blockers |
| `qa-engineer` | opus | Read, Edit, Write, Grep, Glob, Bash | test harness, RulesEngine TDD, contract tests, the DoD gate | the gate is green or names what is not |

Two deliberate choices. **`researcher` and `security-reviewer` get no write tools at all**, which is
the cheapest real safety measure available and costs one line of frontmatter each. And
**`isolation: worktree` goes on the three implementers only**, never on the read-only agents: two
agents writing the same file in one tree produce no conflict, the later write just erases the
earlier, and isolation turns that invisible data loss into a visible merge. Read-only agents would
pay a fresh-checkout cost for nothing.

---

## 4. The working loop

Each unit of work: feature branch in its own worktree, then implement, then tests, then the review
panel, then I integrate to main. No agent merges to main. `security-reviewer` has a veto.

**Chain the build, fan out the verification.** The documented reason to fan out review is anchoring:
one reviewer finds a plausible issue and stops, and a single reviewer gravitates to one issue class
at a time. So the review panel is three read-only reviewers with deliberately non-overlapping lenses,
told to challenge each other before I synthesise:

- **secrets leakage**: logs, crash paths, git, debug UI, fixtures
- **keychain correctness**: accessibility class, the delete-while-locked footgun, duplicate handling
- **protocol correctness**: timezone projection per adapter, the allowlist, the read-back check

Dependency order is real and not negotiable: **the RulesEngine and the DeviceAdapter protocol land
before any adapter, and adapters land before UI wiring.** Everything downstream of the protocol
depends on its shape, so changing it late invalidates work in three places at once.

---

## 5. Security plan

Most of this is section 4 of the research, so here is only what becomes a rule:

- `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, set on add only, plus
  `kSecAttrSynchronizable = false` on every query and add. Never the `WhenUnlocked` default, which
  fails every locked-device background read.
- **No `SecAccessControl` on credential items.** A biometric-gated item cannot be read by a
  background task at all. Gate the connections UI with `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`
  instead, which keeps passcode fallback.
- **`errSecInteractionNotAllowed` is its own error case and never triggers a delete.** This is the
  bug that silently destroys a credential, because `SecItemDelete` succeeds even when the item is
  inaccessible.
- **Eight Sleep has no refresh token**, so the plaintext password must be retained for the life of
  the app. That is forced by the API, not a design choice, and it raises the stakes on everything
  above.
- Refresh on foreground is the mechanism; `BGAppRefreshTask` is opportunistic gravy with no
  user-visible promise attached. Refresh runs behind an `actor` with single-flight coalescing, and
  the new token is written to the Keychain before the response is treated as successful.
- **Allowlist per adapter, never a blocklist.** Both bearer tokens reach genuinely dangerous
  surface: on Eight Sleep, running the pump and **moving the bed frame while someone may be in it**;
  on Whoop, account-lifecycle endpoints. An allowlist means an unlisted path cannot be called even
  by mistake.
- **Never retry `USER_PASSWORD_AUTH` in a loop.** One attempt, surface the error, stop. Repeated
  failures hit rate limiting and risk lockout.
- Never send Whoop's `smartalarm/wbl` telemetry endpoint. Not destructive, but it reports device and
  firmware state, and fabricated values there are the most fingerprintable thing we could do.
- `os.Logger` only, never `print`. Nothing credential-adjacent marked `.public`, remembering that
  numeric values are public **by default** and that the attached debugger renders `.private` values
  in full, which is what tempts people to mark them public and ship it.
- Preview-and-confirm gate on every device write in debug builds. `preview` is pure, so this is
  cheap and testable.
- `gitleaks` as a pre-commit hook, not only in CI. `git push` is the backup, so a committed secret
  is published permanently and rotation is the only remedy.

---

## 6. Sequencing, risk first

**Stage 0, on Alex's Mac, before anything else.** The spike, in TypeScript, run by him because the
hosts are blocked here. It logs in to Eight Sleep and does one `GET /v2/users/{id}/alarms`. That
single call confirms four things at once: the credentials work, the header set is right, the
**subscription is active**, and the true field names in the read shape. Then create one throwaway
alarm and diff the read-back against what was sent, which settles the `powerLevel` against `level`
and `thermal.level` against `thermal.temperature` contradiction that sits directly on our write
path. **If this stage fails, the Eight Sleep leg is dead and we find out in the first hour rather
than the last.** Whoop's equivalent depends on the answer to question 1.

**Stage 1, here, needs nothing from anyone.** RulesEngine and the DeviceAdapter protocol, written
test-first. This is the highest-value work I can do in this environment because it is pure logic,
has no dependency on the blocked hosts, and everything else depends on its shape.

**Stage 2, here.** Keychain layer, then the adapters written against the research spec, then the
preview gate. All unverified until a Mac exists.

**Stage 3, Alex's Mac.** Xcode project, build, fix whatever the compiler says about code that has
never been compiled, install on device, run the AlarmKit leg for real.

**Stage 4, his device.** End to end, one master time writing all three.

---

## 7. QA strategy

**TDD on the RulesEngine**, because it is the only component I can specify completely without a
device. The tests that matter are the edges, and three of them are genuine traps:

- **Midnight crossing.** Master at 00:05 with Eight Sleep at T minus 10 is 23:55 **on the previous
  day**, so the weekday set shifts back by one. A Monday master alarm becomes a Sunday Eight Sleep
  alarm. Get this wrong and the bed warms on the wrong night.
- **DST boundaries.** A wall-clock offset and an elapsed-time offset diverge across a transition,
  and Whoop's HTTP path carries a fixed offset string with **no DST handling at all**, so we own
  re-sending it. Tests for both spring-forward and fall-back.
- **Weekday subsets and per-device overrides**, including the empty set and the full week.

**Contract tests per adapter, against redacted captured fixtures**, asserting field-exact output so
upstream drift surfaces as a typed error rather than silent corruption. Fixtures are redacted before
they are committed and a test fails if any fixture contains a bearer-token-shaped string.

**One end-to-end smoke test**: set master time, assert three writes are attempted with the right
payloads, using stub adapters. This runs without any network and without any credential.

The gate: RulesEngine green, contract tests green, no secret findable by `gitleaks`,
`security-reviewer` signed off. Stated honestly, **none of these can run in this container**, since
running Swift tests needs a Swift toolchain. They are written here and run on his Mac.

---

## 8. Definition of done, revised

The brief's version is one bar. It is not reachable from this session, so here are two, and the
split is where the machine boundary falls rather than where the effort does.

**Track A, this session, code-complete and unverified.** Every one of these is real work I can
finish and hand over:

- `RESEARCH.md` and `PLAN.md`, done and committed
- RulesEngine and its full test suite, written test-first
- DeviceAdapter protocol, Keychain layer, all three adapters, the preview gate
- The spike CLI, ready to run, taking credentials from the environment and never from a file
- Review panel run over all of it, `security-reviewer` signed off
- `.claude/agents/` definitions, `CLAUDE.md`, `gitleaks` hook

**The honest label on Track A is "written, never compiled."** No Swift in it has been near a
compiler. Expect real compile errors on first build. That is not a failure of the work, it is the
unavoidable consequence of the environment, and pretending otherwise would be the exact thing the
brief warns against.

**Track B, Alex's Mac, and only he can call these done:**

- Spike proves the Eight Sleep auth flow and, if applicable, the Whoop one
- Xcode project builds, tests actually run and pass
- Installed on device, AlarmKit alarm fires through Silent and Focus
- One master time writes all available legs, offsets applied, read-back verified
- Secrets confirmed Keychain-only

**I will not describe the demo as working at any point.** The most I can ever say is that Track A is
complete and Track B is ready to attempt.

---

## 9. Phase 3 and later, explicitly not today

Hardening and error-state polish. The generic webhook and Home Assistant output, so Hatch, Hue and
smart plugs can subscribe. Snooze, which is not free: it requires a countdown presentation, which
makes a **widget extension mandatory**, and omitting it causes alarms to be silently dismissed and
fail to alert. Biometric lock on the connections screen. Onboarding for the Whoop SMS refresh
cadence, if the HTTP path is chosen. Fitbit stays deprioritised, its legacy Web API deprecates in
September 2026 and alarms only work on older hardware.

---

## 10. What I recommend

Approve the architecture and the roster, answer question 1, and let me build Track A while Alex runs
the Stage 0 spike on his Mac. Those two are genuinely parallel: the spike needs his machine and his
credentials, and the RulesEngine needs neither.

If the answer to question 1 is **WHOOP 4.0**, I would drop the Whoop HTTP path entirely rather than
build both. It stores no credentials, carries no ToS risk, is already Swift, and is the only Whoop
alarm path anyone has verified actually makes a strap buzz.
