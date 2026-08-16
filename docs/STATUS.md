# Status

Updated 2026-08-16, after the first night of real use.

## Where this is

**It works.** The app is installed on Alex's iPhone and all three legs were verified against live
accounts on the night of 15 to 16 August.

| Leg | State | How it was verified |
|---|---|---|
| iPhone | **working** | rang through Silent, through Focus, phone locked and face down |
| Eight Sleep | **unconfirmed at the layer he sees** | written and read back at the API, absolute instant compared. Never once confirmed in the Eight Sleep app, and on 16 Aug he reported it not showing there. See `E13` |
| Whoop | **working** | written, and the new time confirmed in the Whoop app |

The previous version of this file said "never compiled". That stopped being true on 15 August. It
builds, installs, and rings.

## What the app actually does today

Routines, one per day set, each with its own time. Eight Sleep is written at master minus 10, Whoop
at master minus 5, the iPhone at master. Each row reports what happened, and the two remote legs are
read back rather than trusted.

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

**Eight Sleep is driven by day set, not by a chosen alarm** as of 16 August. Each routine finds the
alarm on the account that already runs on its days and changes **only that alarm's `time`**. Days,
`enabled`, vibration and thermal are echoed back exactly as the server sent them. Nothing is picked
by hand: what Alex confirms is the bed. A routine with no matching alarm is named on screen and
written nowhere, and an alarm no routine describes is named and never touched. A write where any
routine had no home reports as a **warning**, not as done.

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
4. 🟠 **`sleep_goal` is hardcoded to `""`.** Harmless in `EXACT_TIME`, but if he ever selects Sleep
   Goal mode, the next write wipes his 100/85/70 percentage.
5. 🟠 **The strap may not know.** `PUT /smart-alarm-service/v1/strap-status` is what pushes a time
   into strap firmware and the Whoop app sends it after an edit. We do not, and it is outside the
   allowlist. Whoop's server holding the new time and the wrist buzzing at the new time are still two
   different claims, and only the first is verified.
6. 🟠 **The Whoop write sends up to three body shapes** and stops at the first accepted. Which one was
   accepted is printed in the green text on the row and has not been read back yet. Pinning it drops
   the write from three requests to one.
7. 🟡 **No snooze.** Apple's sleep alarm has a nine minute snooze; ours has none. Needs a widget
   extension.
8. 🟡 **The test suite has never run.** No Swift toolchain here. The tests are written and are code
   shaped text until Xcode says otherwise.

## Next, in order

**1. Confirm the damage from item 2.** Open Whoop, check whether the Saturday and Sunday schedule
still exists, and put the weekday one back to Monday to Friday. Alex only; nothing here can see it.

**2. Turn off the iOS Sleep Schedule alarm.** Health, Sleep, Change Wake Up, the `Alarm` toggle. Keep
the schedule, keep the sleep goal, stop the second alarm. Until this is done, an override in OneAlarm
cannot work, because Apple's alarm fires regardless.

**3. Read the Whoop row's green text once** and pin the write to the shape that was accepted.

**4. Let the red team land**, feed it the three findings it has not seen (the phone leg creating
rather than moving, the anchor row being the plan, and Apple's own two-verb prompt), and run a third
pass.

**5. Then build, in this order:**

| | Why it is first |
|---|---|
| Routines and derived next alarm | removes the daily settings trip, which is the actual complaint |
| Skip one date | one tap, expires by itself, replaces "turn the routine off and forget" |
| Bend one date | keyed by date, suppresses the routine's weekday, restores it after |
| Ranges instead of points | a row reading 07:55 for a leg that may fire at 07:25 is lying |
| Foreign change detection | compare against what we last wrote, adopt or ask, never overwrite silently |

Snooze, the anchor device, and Diary mode come after those five.

## What is genuinely uncertain

- Whether the strap fires at the new time, as opposed to Whoop's server holding it.
- Whether OneAlarm's alarm plays on a paired Apple Watch, and what happens when it does. Apple's own
  alarm moves to the watch when `Always Play on iPhone` is off, which is Alex's current setting.
- Whether an Eight Sleep account can expose both sides of one bed under one user id.
- Whether omitting the `repeat` key on an Eight Sleep PUT produces a one-off or silently leaves the
  recurrence unchanged. The spec depends on the first and has never tested it.
