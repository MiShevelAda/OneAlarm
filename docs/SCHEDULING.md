# Scheduling: routines, one-offs, and wake modes

Written 2026-08-16 after the first night of real use, from Alex's own words:

> *"It's not feasible to go every time into the settings app before the weekend and select when I
> want to set up the time. It needs to be a better way, one setting on the main screen so it knows
> today it's Friday or Saturday."*

## The actual problem

The main screen is an **editor**. Seven day chips, a time, a Set button. Every use is an authoring
session, and the state it leaves behind is invisible: after tapping Set you cannot tell from the
screen whether it means tomorrow, or Monday, or never.

That already cost a night. A weekday alarm was tested at 01:00 on a Sunday, correctly did not ring,
and read as a broken app. The screen said `08:00` and nothing else.

The fix is not another control. It is an inversion: **the screen should state the next alarm and let
you override it**, rather than ask you to compose one from parts.

## The model

Three concepts, and no more, because a fourth is where this becomes a calendar app.

**Routine.** A set of days plus a time. Two exist by default and match what both services already
hold: **Weekdays** (Mo to Fr) and **Weekend** (Sa, Su). Edited rarely, and never as a step in
setting tomorrow's alarm.

**Next alarm.** Derived, never stored. Whichever routine covers the next day that has one.

**Override.** A single date and time that beats the routine for that date only, then expires. This
is the "just tomorrow" case: an early flight, a late night. It expires by itself because an override
you have to remember to cancel is an override that eventually wakes you at 05:00 on a Sunday.

Deliberately **not** included: multiple named routines beyond the two, per-day times, holiday
handling. Each is a real want and each turns a wake-up app into a scheduling app.

## The screen

```
        TOMORROW, SUNDAY
             10:30
       Weekend routine · smart

  [ Eight Sleep 10:00 ] [ Whoop by 10:25 ] [ iPhone 10:30 ]

        Change just tomorrow
        Edit my routines
```

The time is the headline and it is a **statement**, not an input. The day is spelled out, always,
because that is the fact that was missing.

**Tapping the time asks one question:** *just tomorrow, or every weekend?* Same gesture, both
outcomes, and the app never has to be told which mode you are in. That single question is the whole
design; everything else follows from it.

## Wake modes, now that both services are understood

Both remote legs fire in a **window**, not at a point, and the current screen renders both as points.
That is a correctness problem, not a cosmetic one: a row reading `07:55` for a device that may buzz
at 07:25 is lying about the thing the app exists to tell you.

| Device | Mode | What the offset means |
|---|---|---|
| iPhone | always exact | fires **at** the time |
| Eight Sleep | Smart alarm off | fires **at** the time |
| Eight Sleep | Smart alarm on | fires in the **30 minutes before**, on light sleep. Their UI: *"Alarm will go off between 06:30-07:00"* for an 07:00 alarm |
| Whoop | `EXACT_TIME` | fires **at** the time |
| Whoop | `SLEEP_GOAL` | fires in the **60 minutes before**, once the chosen share of sleep need is met. Their UI: *"Alarm will vibrate between 08:25 - 09:25"* for an 09:25 wake time |
| Whoop | `IN_THE_GREEN` | fires **before** the time, once recovery is green. Window presumed 60 as well `[to confirm]` |

So a row shows `10:30` when the leg is exact, and `by 10:30` with a range when it is not.

> **Correction, 2026-08-16.** An earlier version of this file said `SLEEP_GOAL` derives the wake
> time, that there was nothing to write, and that the fix was to invert the direction and let Whoop
> anchor the other devices. **Wrong, and the screenshots disprove it.** The `SLEEP_GOAL` flow ends
> on `SET YOUR WAKE TIME`. You set a time in that mode too; it is a ceiling, and Whoop wakes you
> earlier once the goal is met. All three modes take a time and the mode only decides how early it
> may fire, which is a much simpler model than the one I proposed. The anchor idea was solving a
> problem that does not exist.

**`sleep_goal` is not a vestigial empty string.** It is the `100% PEAK / 85% PERFORM / 70% GET BY`
picker, and it only applies in `SLEEP_GOAL` mode. The adapter currently sends `""` unconditionally,
so **choosing Sleep Goal and then pressing Set would wipe the percentage**. Must be carried through
like `alarm_mode`, not hardcoded.

## What each service supports natively, which decides what we must emulate

| | Recurring | One-off | Notes |
|---|---|---|---|
| iPhone (AlarmKit) | `.weekly` | yes | both native, independent |
| Eight Sleep | `repeat.weekDays` | yes, `Repeat: Never` | independent. Also carries per-alarm temperature and vibration, preserved untouched |
| Whoop | `day_of_week_list` | yes, **but only with the schedule off** | mutually exclusive, see below |

**Whoop's one-off and its recurring schedule cannot coexist.** Its own dialog, verbatim:

> *"Your schedule is currently on. Turn off your schedule to set a new alarm for tomorrow."*

That is what `schedule_enabled` at the top of the list response means, and it is also the source of
the *"alarm schedule is switched off"* failure this app hit on its first night.

So applying an override to Whoop means: disable his schedule, set a one-night alarm, and re-enable
the schedule afterwards. **Three writes where two can fail, and the failure is silent and lasting.**
If the re-enable does not happen, his recurring alarm stays off, and he finds out by not waking up,
on a morning he never touched the app.

So the override drives the **iPhone and the bed**, and **leaves Whoop on its routine**, saying so on
screen. That was already the conclusion when this was thought to be a missing feature; it is a
stronger conclusion now that it is a present feature with a destructive edge. A wrist buzz at the
routine time instead of the override time is the cheapest of the three legs to get wrong. A
recurring alarm silently disabled is the most expensive thing this app could do.

Revisit only with a way to guarantee the re-enable, which means persisting the intent and retrying
until it is confirmed, not a `defer` block.

## Order of work

1. Routines and next-alarm derivation. Removes the daily settings trip, which is the actual complaint.
2. Override with automatic expiry.
3. Per-device wake mode, and ranges rendered as ranges.
4. Anchor device, including Whoop-anchored `SLEEP_GOAL`.

One and two are the ones that change how the app feels to use. Three is the one that stops it
misleading you.
