# OneAlarm settings specification

> Spine: **Tomorrow, Stated**. Grafted: the partitioned routines and the dated, self-expiring exception from **Tonight**; the projection step, the `Fidelity` sentences and device-owned location from **Plan and Projection**. Every blocking objection from the consensus round is resolved below or named as out of scope with what the user sees. Repo paths are absolute under `/home/user/Alex_personal_brand/alarm-app/`.

## 1. Three laws

1. **The primary leg is the iPhone, it is armed locally before any network call, and it is the only leg that may be primary.** AlarmKit needs no account, no network and no server. A remote leg cannot be armed locally, so it cannot carry the guarantee. The loud alarm may be switched off; that produces a named, dated, acknowledged state, not a promoted bed.
2. **Nothing that moves the intended instant is written to a live account without a tap.** Two classes of write may go out unattended: an **encoding repair** (the instant is unchanged, the wire form is stale) and a **routine handover** (the value was authored by the user in this app and the diff is confined to time and days). Everything else waits.
3. **Every claim is typed to its evidence.** Copy is a `switch` over `Confidence`. Only the phone may say "will ring". Only an absolute instant returned by a server may say "confirmed". Whoop's ceiling is "saved", forever, with the strap sentence on the row every night.

## 2. Model

Stored in App Group `group.de.trucora.onealarm`: `plan.json` (atomic replace), `ledger.jsonl` (append only, entry written **before** the network call), `restores.json`, `learned.json`. Credentials only in Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `kSecAttrSynchronizable = false`, add only, no `SecAccessControl`; `errSecInteractionNotAllowed` is its own case and never triggers a delete.

```
Plan { revision: Int, mode: .routines | .diary, homeZoneID: String,
       routines: [Routine], items: [PlanItem], quiet: Quiet?, ack: Acknowledgements }

Routine { id, name, days: Set<Weekday>, time: WallClockTime, isOn: Bool }
   One to four. Two by default. The editor enforces a partition: a day toggled into one
   routine leaves the other. A day may belong to none, which means no alarm, printed by name.

PlanItem { id, date: YearMonthDay, kind: .moveTo(WallClockTime) | .skip | .extra(WallClockTime,label)
           | .countdown(seconds, startedAt), devices: Set<DeviceID>?, crossesZones: Bool,
           armState: .armed(Date) | .storedNotArmed(armAfter: Date) | .refused(String) }
   Keyed by date, never by weekday. Deleted at intendedInstant + 6h. Any number may exist.
   .extra ADDS an alarm. .moveTo and .skip REPLACE the routine on that date.

Quiet { until: YearMonthDay, reason: String }        // the pause. Always dated. Max 60 days.
DeviceProfile { device, isManaged: Bool, role: .primary | .quiet, leadMinutes: Int (-120...120),
                anchorEdge: .latest | .earliest, location: .travelsWithMe | .staysIn(zoneID),
                clockAnchor: .followsPhone | .fixed(zoneID, until: YearMonthDay?),
                followsDatedItems: Bool, chosenRemoteAlarmID: String?,
                lastSnapshot, lastAttempt, lastConfirmed }

RemoteSnapshot { readAt, rawObject: Data, wallClock, days, enabledAtService, mode, sleepGoal,
                 windowMinutes, extras: [String:String], siblingAlarms: [String], nextTimestampUTC }

Confidence = .notArmed | .armedOnDevice(at:) | .armedStale(armedFor: Date)
           | .confirmedInstant(Date) | .saved(at:) | .mismatch(expected:actual:)
           | .refused(reason:stillHolds:) | .stale(writtenOffset:currentOffset:) | .unmanaged(stillHolds:)
```

`.armedStale` is the case the critics found missing: the phone holds a real alarm, at a time that is not the plan (`maximumLimitReached` on a silent local arm). It prints "your phone will ring at 06:00, not the 07:30 you set".

## 3. Resolution, projection, arming

**Resolve.** For each date D from today to today + 60 in the plan's display zone: a `.skip` gives no event, a `.moveTo` gives its time, otherwise the routine whose `days` contains D, or none. `.extra` and `.countdown` add events. Intended instant uses `Calendar.nextDate(matchingPolicy: .nextTime, repeatedTimePolicy: .first)`, so the spring-forward hole resolves to the first real instant. **The screen always prints the resolved instant, never the typed wall clock.**

**Project.** Per managed device: `deviceInstant = intendedInstant + leadMinutes * 60`. Wall clock, weekday and `dayShift` are all computed in that device's `clockAnchor` zone, not `Calendar.current`. `time_zone_offset` is recomputed at every projection and never cached. `windowMinutes` comes from `lastSnapshot`, never a guess: 30 for Eight Sleep smart wake, 60 for Whoop `SLEEP_GOAL`, 60 marked presumed for `IN_THE_GREEN`, 0 otherwise. Windowed legs render as ranges, never points, and any summary of the run-up uses the earliest possible fire.

**Arm. The seven day rule, which is the correctness fix the critics forced.** `AlarmKitAdapter.swift` offers exactly two recurrences, `.never` and `.weekly([Weekday])`, and `.fixed(Date)` is banned. `.weekly` has no start date, so a dated item created more than seven days out would ring on every intervening same weekday. Therefore:

| Distance | Encoding | State |
|---|---|---|
| Routine | `.relative(time, repeats: .weekly(days))`, indefinite | armed forever, survives reboot |
| Dated item within 24h | `.relative(time, repeats: .never)` | armed |
| Dated item 1 to 7 days | `.relative(time, repeats: .weekly([thatWeekday]))`, cancelled on fire | armed, the first occurrence IS the target date |
| Dated item beyond 7 days | nothing scheduled | `storedNotArmed(armAfter:)`, printed as such |

Not-yet-armed items are armed by any foreground, any background run, and are guaranteed by a local notification at 18:00 the previous evening. Every screen that lists a dated item prints `armed` or `stored, arms on Friday`. The app never says "armed at any distance".

**Reconcile, every foreground.** Read `AlarmManager.shared.alarms`, compare each alarm's **schedule content** against the plan, cancel anything the plan does not claim, re-arm anything missing. AlarmKit `verify()` compares time and recurrence, not UUID presence. Orphans from a crash between `schedule()` and persisting the id are cleaned here.

**Suppression is synchronous.** For a `.skip` or `.moveTo` inside 48 hours, the routine's weekly alarm is rewritten to omit that weekday, in the foreground, and read back before any screen prints silence. If it cannot be done, the screen says "your 07:00 routine alarm is still armed for Tuesday" in the tomorrow block. Beyond 48 hours suppression is deferred and the item shows `arms Friday`. Deleting the item restores the omitted weekday immediately and cancels its restore task.

**Cap.** On `maximumLimitReached`: never cancel a working alarm, shed second chance first, then refuse the furthest item, mark it `.refused`, show a red band and fire a notification. Nothing is ever dropped silently and the screen never states an alarm that was shed.

## 4. Writes

```
read -> build (read-modify-write) -> diff -> [gate] -> write -> verify -> ledger
```

Three classes:

| Class | Example | Consent |
|---|---|---|
| Encoding repair | DST moved `time_zone_offset`; weekday set shifted in the device's own zone | automatic, logged, notified once |
| Routine handover | Friday night, the bed and strap move from Weekdays to Weekend | automatic, logged, one line on the row |
| Intent change | plan edited, phone changed country, foreign value found on the service | tap only, through the diff sheet |

Routine handover is the answer to the "two routines, one remote object" fatal flaw. Eight Sleep holds one alarm and Whoop holds one schedule, so with two routines the days must change twice a week. Pinning each leg to one routine leaves the other routine with no quiet leg; requiring a tap trains the user to dismiss a modal twice a week. Handover is safe because the value was authored by the user in this app, the diff is confined to `time` plus the day set, and the leg has been confirmed at least once. If the read shows anything OneAlarm did not author, handover is suspended and the diff sheet fires.

**Eight Sleep.** `GET /v2/users/{id}/alarms`, take the bound object, change only `time`, `repeat.enabled`, `repeat.weekDays` and (only on explicit user action) `enabled`; strip `nextTimestamp`, `startTimestamp`, `endTimestamp`, `dismissedUntil`, `snoozedUntil`; `PUT /v1/users/{id}/alarms/{alarmId}`. `thermal` and `vibration` echoed byte for byte, displayed on the row, never authored. Verify by re-reading `nextTimestamp` twice 1.5s apart, 60s tolerance, compared in the bed's own zone. Derive `learnedBedZone` from `nextTimestamp` minus the wall clock we sent: stored as a **dated candidate zone identifier**, display only, never fed back into send arithmetic, and re-derived after every DST transition.

**Whoop.** Read `GET /smart-alarm-bff/v1/schedule/components/populated/{id}?apiVersion=7` for `wake_mode`, `sleep_goal`, `repeat_days`, `wake_time`. Write exactly six keys to `PUT /smart-alarm-bff/v1/schedule/{id}?apiVersion=7`: `sleep_goal`, `alarm_mode`, `enabled` carried verbatim from that read, plus `day_of_week_list`, `latest_wake_time` ("07:45:00") and `time_zone_offset` from the projection. `variants()` and the `IN_THE_GREEN` retry are deleted; a refused write is reported as refused. `sleep_goal` absent from the read blocks the write; `sleep_goal` present and empty is echoed as empty, because an empty string is a legitimate value outside `SLEEP_GOAL` mode. **One narrow exception to the ban on `/schedule/all`:** `assertMasterSwitchOn()` at `WhoopAdapter.swift:670` keeps reading `schedule_enabled`, because that is a feature flag and not a view-model label, and without it a 200 is printed over a strap that will never buzz. `scheduled_days`, `alarm_on` and `"7:45 am"` never enter logic or a doc comment. Whoop can never exceed `.saved`.

**Restore tasks.** Written before the temporary write, executed as **re-read, apply only the stored `repeat`/`time`/`enabled` intent, write**, never as a wholesale PUT of a stored object. Each carries a hard `deadline` (the evening before the next routine day it affects). Run on every foreground, every background pass and every apply. If still outstanding at the deadline, a local notification fires: "your bed's Monday to Friday alarm has not been put back yet". Abandoned, with a line on the row, if the object changed outside OneAlarm since the snapshot.

## 5. Screens

**Onboarding, four steps.** (1) What OneAlarm does: moves alarms you already have, never creates or deletes. (2) Weekday time, weekend time or "no alarm at weekends", and "my week is not the same every week" which selects Diary. (3) **Home zone, asked, never sniffed.** (4) Alarm permission explained, then the system sheet, then **the notification permission**, explained as "this is how OneAlarm reaches you when it is closed: clock changes, unarmed alarms, a device that needs putting back". Refusal on either is a first class state, not silence.

**Tonight.** Header, always: `SATURDAY 16 AUGUST`, `10:30`, `in 10h 48m, Weekend routine`, plus a fourth line when clocks differ: `10:30 Zurich, 04:30 Sat here`. Both clocks always carry **both dates**. The words TODAY, LATER TODAY, TOMORROW and a dated weekday are derived from the resolved instant. Negative states are first class: `No alarm tomorrow, Sunday 17 August. Next alarm Monday 18 August, 07:45.`

Rail, one row per managed leg, ordered by fire time, each a sentence:
```
10:00 to 10:30  Eight Sleep   confirmed for Sat 10:00 Zurich, read back 23:41
                              vibration level 3, thermal rise on. Change these in the Eight Sleep app.
by 10:25        Whoop         saved 23:41. Holds Zurich time. Your strap takes it at its next sync.
10:30           iPhone  LOUD  armed on this phone. Rings through Silent and Focus.
```
**Different about tomorrow**, present only when non-empty, and containing only what differs from the standing situation: an un-suppressed routine alarm, a stopped device, a not-yet-armed item, a sibling alarm that collides with tomorrow. Permanent structural facts (the Whoop routine, the sibling Eight Sleep alarms) live on the device rows and in Devices, so this block is not furniture.

Four thumb targets, 64pt, on the root screen, in this order: **[Skip tomorrow] [-15] [+15] [Nap]**. Skip is one tap because it is the most frequent night action and the alternative is switching a routine off and forgetting. Nap is one tap to a phone-only absolute countdown with a default of 90 minutes and a wheel behind it. Every one of the four names the date it touched in a three second undo toast whose undo issues a real restore write, not a local revert. Today's skip stays on Tonight as `No alarm today, you skipped it at 05:04 [Undo]` until the date passes, so un-skip has the same reach as skip.

Buttons: `Check devices` (GET only, always safe, and for Eight Sleep it uses a cached token and **refuses rather than running the password grant**, because that grant is one attempt only), and `Send changes (n)`, which appears only when a leg's projection differs from its last confirmed state.

**Change sheet**, titled with the full date. `-15/+15`, exact wheel, then `Just Saturday 16 August` (primary) and, below a divider, `Every weekend`, which names the days it overwrites. A peer option `In N hours`, absolute by construction, offered on every dated item and defaulted on when `crossesZones` is set or the phone changed zone in the last seven days. Honesty footer changes with the highlighted option and always names the wrist.

**My week / Diary.** Routines as cards with the partition control. Diary is a dated list with a pattern generator (four on, three off, N days forward) that materialises real editable dated entries out to 60 days, each showing `armed` or `arms on <date>`.

**Devices.** Per device: what it holds now (read, timestamped), what OneAlarm wants it to hold, `Manage this device` (off means OneAlarm stops writing, it disarms nothing, and the row immediately reads `Not managed. Still holds 04:20 Zurich, written 12 July`), lead stepper with the sentence spelled out, anchor edge for windowed legs, location, clock anchor, `Stop this device until <date>`, the allowlist in plain words, and the last ten ledger lines.

**Diff sheet**, only for foreign changes and destructive fields, with `Replace`, `Adopt what the service has`, `Skip this one`, no default button. **Adopt** inverts the device's lead and shows the resulting master time before committing: "Whoop holds 08:00. Your wrist runs 5 minutes early, so this sets your Weekdays routine to 08:05 and your phone will ring at 08:05. Continue?" Destructive diffs re-prompt on every change of destructive content, not once ever.

**Closing statement**, chosen by the worst outcome. GREEN requires the primary armed **and** every managed leg confirmed, saved or fully explained. `.saved` alone with no armed primary is never green. AMBER: primary armed, a quiet leg not, naming what that leg still really holds. RED, full screen, not swipe dismissible: `NOTHING WILL WAKE YOU ON SATURDAY 16 AUGUST`, the reason in one line, `[Fix it]`, and `[I know, let me past]` which is written to the ledger.

## 6. Failure states

| State | Row | Screen |
|---|---|---|
| Device offline / no network | `Refused: no network. Still holds 06:25, so your wrist will buzz at 06:25.` | amber close, primary unaffected |
| Whoop token lapsed | `Refused: sign in again. Still holds 06:25.` No password field at night, by any path. | amber, banner "OneAlarm has not reached Whoop since 12 July" |
| Eight Sleep 403 subscription | its own state, never `needsReauth`, never a password field. Auto-pauses the leg after three consecutive occurrences with a standing notice. | amber |
| 429 on either grant | `.rateLimited` with a cooldown timestamp printed. One attempt only, never a loop, never diagnosed as expiry. | amber, no password field until the cooldown passes |
| Write half applied | ledger entry exists with no verification; row reads `Sent, not confirmed`. The remedy offered is `Check devices`, never another PUT. | amber |
| Verify mismatch | `mismatch: we asked for Sat 06:05, your bed reports Sat 12:50` with the zone named | amber, `[Fix the bed's zone]` |
| Whoop master switch off | write refused before it is sent, `Turn your alarm schedule on in the Whoop app` | amber |
| Clock change | encoding repair sent automatically; if it fails, notification at 18:00 the day before naming the stored offset and what it becomes | banner |
| Phone changed country | intent change, never automatic. Banner with both clocks and both dates, plus a notification on first detection whenever any managed leg is `travelsWithMe`. Escalates to a notification again after 24 hours unanswered. | banner |
| Alarm permission denied | red screen, three numbered Settings steps | red |
| Notification permission denied | standing amber band: "OneAlarm cannot warn you when it is closed. Clock changes and unarmed alarms will not reach you." | band, and the affected lines in Cannot Do are struck through |
| Nothing armed in 24h | notification at **20:00 daily**, a fixed fallback that does not depend on a planned wake existing | red screen if opened |
| Paused | red, un-dismissible card: `Alarms are off until 26 August. Nothing will wake you.` Nightly 20:00 notification that cannot be acknowledged away, only ended by setting a new end date or turning alarms back on. | red |
| Off on purpose, dated | amber, not red: `No alarms until 26 August, you chose this.` Self-expiring. | amber |

## 7. Defaults

Two routines from the two onboarding answers, Weekdays 07:00 Mo to Fr and Weekend 09:00 Sa Su. Mode `.routines`. Home zone asked. iPhone: managed, role primary, lead 0, `followsPhone`, loud on, **snooze on at 9 minutes** (legal, a widget extension ships), **second chance off**. No Eight Sleep row, no Whoop row, no offsets, no chips, no wake-window graphic until a device is connected. When connected: Eight Sleep managed, quiet, lead -10, `staysIn(homeZone)`, clock anchor `fixed(homeZone)`, `followsDatedItems` on, restore on. Whoop managed, quiet, lead -5, `location .travelsWithMe` but **clock anchor `fixed(homeZone)`**, `followsDatedItems` structurally off. Handover on. Encoding repairs on. All four notifications on. Advanced off, per-device days off, webhook absent. Resolution horizon 60 days, arming horizon 7 days, both printed on screen.

Alex on a normal Tuesday does nothing. On Friday night he does nothing, because the weekend routine already exists and handover moves the bed and the strap for him. For a lie-in on one Saturday he taps the time once and taps `Just Saturday`.

## 8. What the app must never do

Never `POST /v1/users/{id}/alarms` or `DELETE /v1/users/{id}/alarms/{alarmId}`. Never port `_bootstrap_alarm_discovery()`. Never touch bed angle, temperature, pump priming, away mode, audio, `current-device` or `bedtime`. Never send `POST /smart-alarm-service/v1/smartalarm/wbl` or `PUT /smart-alarm-service/v1/strap-status`; the whole `smart-alarm-service` prefix stays outside the Whoop allowlist, which is why the master switch and the disable/set/re-enable override are unreachable by construction. Never force `enabled: true`. Never author Eight Sleep `vibration` or `thermal` while `powerLevel` vs `level` and `thermal.level` vs `thermal.temperature` are unresolved. Never write without a read-modify-write against the object the server just returned. Never retry `USER_PASSWORD_AUTH` or the Eight Sleep password grant. Never diagnose a 429 as expiry. Never delete a Keychain item on `errSecInteractionNotAllowed`. Never add `com.apple.developer.alarmkit`; ship a non-empty `NSAlarmKitUsageDescription`. Never use `.fixed(Date)`. Never cancel an alarm before its replacement is confirmed scheduled. Never fall back to the first alarm the server lists; throw `alarmChoiceNeeded` and route to the picker. Allowlists stay verb-plus-URL regexes, never blocklists.

## 9. Scenarios

Handled: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 20, 22, 23, 24, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57.

Out of scope, with what the user sees:

| Scenario | Not supported | What you see |
|---|---|---|
| 18, 21, 25 | Whoop cannot express a non-weekly plan, cannot do one-offs, cannot be switched off | In Diary the Whoop leg is set `unmanaged` by default with the row `Not managed. Still holds 07:45 Mo to Fr and will buzz then. Switch it off in the Whoop app.` Same sentence for a silent stretch. |
| 19 | Two remote alarms in one date. The bed holds one object, Whoop holds one schedule | Both sleeps exist on the phone as `.extra` items. The bed row says `follows your main sleep only`, and the nap row says `phone only`. |
| 47 | Two people, per bed side | Devices and Cannot Do both say one account, one alarm, one person. The Connect picker states that **the service does not label which side an alarm belongs to** and asks the user to confirm the time and days match their own. The old "your own side of the bed" copy is deleted. |
| 58 | Webhook and Home Assistant push | Removed from settings entirely. `next-alarm.json` in the App Group plus `OneAlarmNextWake`, `SkipTomorrow` and `SetWakeToday` App Intents, documented as the latest known plan, polled not pushed. |
| 59 | Per-device days | Off by default and absent from the main screen. Behind Advanced, and turning it on switches Tonight permanently into advanced layout with every row printing its own days. |
| n/a | Bed-primary with the loud alarm off | Refused, with the reason on screen: a remote leg cannot be armed locally, so it cannot carry the guarantee. Turning the loud alarm off gives a dated, acknowledged quiet-only state that is amber every night, and second chance and snooze are turned off with it so the phone cannot scream next to a partner. |
| n/a | Apple Watch | Named on the iPhone row and in Cannot Do: the alarm relays to a paired Watch by system behaviour, OneAlarm has no watch code and cannot verify it, and out-of-range and Theater Mode behaviour is undocumented. |
| n/a | Proving the strap holds the time | Whoop capped at `.saved` forever, strap sentence on the row every night. |

## Open disagreements

- Bed-primary is refused outright. The couple sharing a Pod asked for it explicitly and this spec answers no, on the grounds that a remote leg cannot be armed locally and so cannot carry Law 1. They get a dated quiet-only state with second chance and snooze forced off instead, which does not give them a guaranteed wake. If that trade is wrong, Law 1 has to be rewritten before anything else is.
- The seven day arming horizon is a hard cap forced by AlarmKit having only .never and .weekly (confirmed at OneAlarm/Adapters/AlarmKitAdapter.swift:106-109). The shift worker wants a five week roster armed in one sitting and cannot have it. Items beyond seven days are stored and armed later, guaranteed only by a local notification. If notification permission is denied, that guarantee is gone and the app says so, which is honest but not sufficient for someone on nights.
- Routine handover is a new class of automatic write to a live account. It is defended as safe because the value was authored in this app and the diff is time plus days only, but it is still an unattended PUT to Eight Sleep and Whoop twice a week, which contradicts the plain reading of 'nothing is written without a tap'. The alternative, pinning each remote leg to one routine, leaves the other routine with no quiet leg. One of these two has to be accepted.
- Whoop is defaulted to clock anchor fixed(homeZone) while its location is travelsWithMe. This makes the row honest and stable but means the frequent flyer's wrist stays on home time until he taps. Defaulting the other way would mean an unattended write on every landing.
- The Eight Sleep one-off, written by omitting the repeat key on a PUT, is still untested. RESEARCH.md documents that shape for the create call only. If the server treats an absent key as unchanged, a dated item silently becomes a recurring alarm at the wrong time. This spec keeps the feature on by default and guards it with read-back plus a restore task with a deadline, but the underlying question is open and should be answered before followsDatedItems ships on.
- Whether an Eight Sleep account can expose both sides of one bed under a single userId is unanswered. The picker copy is capped rather than the question resolved.
- The stale comment at OneAlarmTests/AdapterMutationTests.swift line ~128 claiming day_of_week_list, enabled, time_zone_offset and sleep_goal do not exist still needs deleting; it contradicts the confirmed six-key write body.
- No agent in this workflow compiled anything; every Swift claim in this document is code-shaped text reviewed against a spec. The app itself does build and run: it was installed on a real iPhone on 2026-08-15 and all three legs were verified against live accounts that night, the phone by a ring test through Silent and Focus.
