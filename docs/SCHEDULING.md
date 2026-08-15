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
| Eight Sleep | Smart alarm on | fires in the **30 minutes before**, on light sleep. Confirmed in their UI: *"Alarm will go off between 06:30-07:00"* for an 07:00 alarm |
| Whoop | `EXACT_TIME` | fires **at** the time |
| Whoop | `IN_THE_GREEN`, `EXACT_TIME_PEAK` | fires **before** the ceiling, window length unknown `[to confirm]` |
| Whoop | `SLEEP_GOAL` | Whoop **derives** the time. Nothing to write. See below |

So a row shows `10:30` when the leg is exact, and `by 10:30` with a range when it is not. Whoop's
window length has never been observed, so it renders as "can ring earlier" with no invented width
until someone reads a real number off the Whoop app.

**`SLEEP_GOAL` inverts the direction.** Whoop calculates the wake time from sleep need, so pushing a
time into it argues with the feature. The right handling is to let Whoop be the **anchor**: read the
time it computed and set the phone and the bed around it. That is the same mechanism as choosing
which device is the main alarm, which Alex asked for separately. It needs a re-read before the alarm
rather than at button-press, because the value changes nightly.

## What each service supports natively, which decides what we must emulate

| | Recurring | One-off | Notes |
|---|---|---|---|
| iPhone (AlarmKit) | `.weekly` | yes | both native |
| Eight Sleep | `repeat.weekDays` | yes, `Repeat: Never` | also carries per-alarm temperature and vibration, which we preserve untouched |
| Whoop | `day_of_week_list` | **no** | a schedule is days-based with no one-shot form |

**Whoop has no one-off.** Faking one means editing the recurring schedule's days and restoring them
afterwards, and a restore that fails leaves his real alarm wrong on days he never touched. So an
override drives the iPhone and the bed, and **leaves Whoop on its routine**, saying so on screen.
A wrist buzz five minutes early is the least consequential of the three legs to skip, and a silent
half-applied override is the most dangerous thing in this document.

## Order of work

1. Routines and next-alarm derivation. Removes the daily settings trip, which is the actual complaint.
2. Override with automatic expiry.
3. Per-device wake mode, and ranges rendered as ranges.
4. Anchor device, including Whoop-anchored `SLEEP_GOAL`.

One and two are the ones that change how the app feels to use. Three is the one that stops it
misleading you.
