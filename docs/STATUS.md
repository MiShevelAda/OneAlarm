# Status

Updated 2026-08-16, after the first night of real use.

## Where this is

The app is installed on Alex's iPhone and rings. One leg of three is confirmed at the layer he sees.

| Leg | State | How it was verified |
|---|---|---|
| iPhone | **working** | rang through Silent, through Focus, phone locked and face down |
| Eight Sleep | **unconfirmed at the layer he sees** | written and read back at the API, absolute instant compared. Never once confirmed in the Eight Sleep app, and on 16 Aug he reported it not showing there. See `E13` and `E17` |
| Whoop | **working** | written, and the new time confirmed in the Whoop app |

**This header used to say "It works. All three legs were verified", directly above a table saying one
of them was not.** It was written on the morning of 16 August and was already contradicted by its own
table by that evening. Kept as a correction rather than a silent edit, because a status file that
overstates is worse than none: it is the thing you read to decide whether to go looking.

The evening of 16 August is a further step back. Everything written after 18:00, the routine
ownership model, the routine write and the create, is **committed and never executed**. There is no
Swift toolchain in the session environment and `download.swift.org`, `github.com` releases and
`objects.githubusercontent.com` are all refused by the proxy, checked rather than assumed. Four
defects were found by hand and by grep in that code, two of them compile errors, which is a good
argument for how much is likely still in there.

## What the app actually does today

Routines, one per day set, each with its own time. Eight Sleep is written at master minus 10, Whoop
at master minus 5, the iPhone at master. Each row reports what happened, and the two remote legs are
read back rather than trusted.

**The phone holds one alarm per routine** as of 17 August. It held exactly one before that, built
from the single resolved target, whose days were those of the routine covering the **next** morning.
So a Friday night sync armed Saturday and Sunday and left Monday with no phone alarm at all: a silent
missed morning on the leg that exists because it needs no account, no network and no server. The
decision of what to hold and what to cancel is `AlarmKitReconciler`, which is pure and has eight
tests; `AlarmManager.shared` is an Apple singleton with no seam, so the adapter is a shell that
schedules what it is told. A bend still arms one weekday and stands the routines down, because
AlarmKit offers `.never` and `.weekly` and nothing between.

**OneAlarm writes Eight Sleep routines, not just alarms** as of 16 August, evening. Their app models
alarms **inside** routines, and the routine carries the `days`. So a OneAlarm routine now drives both:
the alarm's time through `PUT /v1/users/{id}/alarms/{alarmId}`, and the routine's days and switch
through `PUT /v2/users/{id}/routines/{routineId}`. A routine with no alarm gets one added **inside** a
routine whose days already match, through `alarmsToCreate`, rather than as a standalone alarm that
belongs to no routine and that their app appears never to list. His `bedtime` is read and sent back
untouched, and a routine unrelated to any OneAlarm routine is never opened.

**OneAlarm is the source of truth for the Eight Sleep schedule** as of 16 August. Each routine owns
one alarm on the bed, recorded in `RemoteAlarmLink` rather than re-guessed from days each time.
OneAlarm authors that alarm's `time`, its `repeat.weekDays` and its `enabled`. A routine with no
alarm gets one created, cloned from an existing alarm so no field is composed. A routine deleted in
OneAlarm switches its alarm off, never deletes it. A skip switches it off for one morning. An alarm
OneAlarm has never owned is never touched, and temperature, vibration, level and pattern are read
from Eight Sleep and handed straight back on every write.

The cost, stated: switching an owned alarm off inside the Eight Sleep app is undone by the next sync.
Turn the routine off in OneAlarm instead.

**The home screen is one morning; routines live on their own screen** as of 16 August. The master
wheel is gone from home: the big time is tomorrow's, tapping it opens a sheet that bends tomorrow and
says so, and the three verbs under it sit beneath the words "This morning only". Every routine is
visible on home as a read only line, and `RoutinesView` is the only place any of them can be edited,
added or deleted.

**Nothing is picked by hand.** What Alex confirms is the bed. A routine with no alarm gets one
created rather than a instruction to go and build it, an alarm no routine describes is named and
never touched, and a write where any routine had no home reports as a **warning**, not as done.

> **A paragraph here used to say Eight Sleep gets "only that alarm's `time`", with days and `enabled`
> echoed back.** That was true between roughly 09:00 and 13:00 on 16 August and was left standing
> after the ownership model replaced it, two paragraphs below the text that contradicts it. Removed
> rather than quietly overwritten, because this is the second contradiction found in this file in one
> day and the first one nearly sent somebody looking in the wrong place.

Everything under "designed, not built" below is on paper.

## What is designed and not built

| Document | What it holds |
|---|---|
| `docs/SETTINGS.md` | the full settings and scheduling spec from a 39 agent design round |
| `docs/USER-CASES.md` | Alex's own words on who uses this and how, plus the cases they expose |
| `docs/SCHEDULING.md` | the routines and override design, with its corrections |
| `design/prototype-v2.html` | a clickable prototype of the redesigned screen and its failure states |

The spec **did not reach consensus**: nineteen of twenty one persona votes were no across three
rounds, and eight disagreements are recorded at the end of it, unresolved on purpose. A second run
is attacking it now, with an adversary at every stage.

## Known problems, worst first

1. 🔴 **The phone leg creates a second alarm.** OneAlarm's alarm sits beside the iOS Sleep Schedule
   alarm, which still fires at its own time. iOS exposes no way to read or change a Clock alarm or a
   sleep schedule, so this cannot be fixed in code. The remedy is to turn the **Alarm** toggle off
   inside the Sleep Schedule, keeping the schedule itself, and for the app to say so permanently.
2. 🔴 **Alex's Whoop schedule was rewritten by our own test.** Turning on all seven days for the ring
   test collapsed his Monday to Friday schedule into every day, because the Whoop write replaces
   rather than merges. Whether his Saturday and Sunday schedule survived is **unconfirmed**.
3. 🔴 **Whoop still has its days rewritten, and structurally so.** Whoop holds one schedule per
   account, so it cannot express two routines the way Eight Sleep can. OneAlarm therefore writes the
   day list of whichever routine covers tonight, which means a Friday sync replaces a Monday to
   Friday list with Saturday and Sunday. Same shape as problem 2, but by design rather than by
   accident, and not yet fixed. Filed as `E12`.
4. 🟠 **A bend anywhere ahead puts the phone back to one alarm.** `AlarmKitReconciler` treats "any
   routine has a bend" as "arm the single target", so bending next Saturday from a Monday stands
   every routine alarm down for the rest of the week. Not a regression, it is what this leg did for
   every morning before 17 August, and the nightly Set covers it. The fix is for the plan to carry
   whether the override lands on the **next** morning rather than merely somewhere ahead.
5. 🟠 **`sleep_goal` is hardcoded to `""`.** Harmless in `EXACT_TIME`, but if he ever selects Sleep
   Goal mode, the next write wipes his 100/85/70 percentage.
6. 🟠 **The strap may not know.** `PUT /smart-alarm-service/v1/strap-status` is what pushes a time
   into strap firmware and the Whoop app sends it after an edit. We do not, and it is outside the
   allowlist. Whoop's server holding the new time and the wrist buzzing at the new time are still two
   different claims, and only the first is verified.
7. 🟠 **The Whoop write sends up to three body shapes** and stops at the first accepted. Which one was
   accepted is printed in the green text on the row and has not been read back yet. Pinning it drops
   the write from three requests to one.
8. 🟡 **No snooze.** Apple's sleep alarm has a nine minute snooze; ours has none. Needs a widget
   extension.
9. 🟡 **The test suite has never run.** No Swift toolchain here, and `download.swift.org`,
   `github.com` releases and `objects.githubusercontent.com` are all refused by the proxy. Seventeen
   tests are written and are code shaped text until `Cmd+U` says otherwise. What **has** run is
   `npm run check`: the project structure, the secret scan, and a real tree-sitter parse of all 31
   Swift files. A parse is not a type check and cannot see a wrong type or a missing argument label.

## Next, in order

**Everything below this line is Alex's.** Nothing in the session can do any of it: there is no Swift
compiler here, `app-api.8slp.net` is refused by the proxy, and his password lives in his iPhone
Keychain where it belongs. All three were checked on 16 August rather than assumed.

### 1. The one blocking step, and it is ten seconds

Paste this on the Mac, in Terminal:

```
cd ~/OneAlarm-build && git stash && git pull --rebase && git stash pop
```

Then in Xcode press **Cmd+U**.

**What should happen:** seventeen tests run and go green, in about ten seconds. No phone, no bed, no
waiting for morning.

**If they go red, or Xcode shows errors instead:** that is the answer, and it is the useful kind.
Nothing in this repo has ever been compiled by a session, so a compile error is expected rather than
surprising, and the session can fix a pasted error in one pass. Do not try to work around it.

**Why this before anything else:** it is the only check that costs nothing. Everything after it costs
a real write to a live account.

### 2. Then run it once and look at the bed

**Cmd+R**, then **Set all alarms**, then open the Eight Sleep app.

**What should happen:** a weekend alarm appears inside a routine, with the vibration and thermal
settings copied from the alarm he already had, and his bedtime unchanged.

**What to send back, whichever appears:**

- the Eight Sleep row's text on the home screen. It now says which of four things happened: added
  inside a routine, created standalone, refused with the server's own words, or the routines read
  itself failed and with what status
- the panel at Connections, Eight Sleep, "Your Eight Sleep routines, raw". It prints which API
  version answered, which settles `E16` and `E19` in one look

**If something wrong appears on the bed:** delete it in the Eight Sleep app. OneAlarm has no delete
on either service and is not getting one, so cleanup there is manual by design.

### 3. Two things still owed from 15 August

- **Whoop:** check whether the Saturday and Sunday schedule survived the seven-day test, and put the
  weekday one back to Monday to Friday. Nothing here can see it.
- **iPhone:** Health, Sleep, Change Wake Up, the `Alarm` toggle, off. Keep the schedule and the sleep
  goal. Until this is done a bend in OneAlarm cannot work, because Apple's own alarm fires regardless.

### 4. What the build does next, once step 1 and 2 have answered

| | Why |
|---|---|
| Pin the accepted create shape and delete the ladder | it currently sends up to six requests to find one that works |
| Pin the routines read version and drop the fallback | two requests where one will do, once `E19` is answered |
| `skipNext` instead of `enabled` for a one-morning skip | `E11`. The current skip works but leaves an alarm off until the next sync |
| Foreign change detection | compare against what was last written, adopt or ask, never overwrite silently |
| Ranges instead of points | a row reading 07:55 for a leg that may fire at 07:25 is lying |

Snooze, and Diary mode, come after those.

## What is genuinely uncertain

- Whether the strap fires at the new time, as opposed to Whoop's server holding it.
- Whether OneAlarm's alarm plays on a paired Apple Watch, and what happens when it does. Apple's own
  alarm moves to the watch when `Always Play on iPhone` is off, which is Alex's current setting.
- Whether an Eight Sleep account can expose both sides of one bed under one user id.
- Whether omitting the `repeat` key on an Eight Sleep PUT produces a one-off or silently leaves the
  recurrence unchanged. The spec depends on the first and has never tested it.
