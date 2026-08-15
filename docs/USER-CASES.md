# User cases, in Alex's words

Captured 2026-08-16 at 03:00, during the first night of real use. His words are the source of truth;
the analysis under each is mine and can be wrong.

> *"One of the edge cases is somebody actually has routines and alarm set, but then changes them
> because she wants to wake up instead of usually Monday to Friday seven forty five AM at one day.
> She wants to wake a little bit later and sets the alarm to eight AM. And then maybe she had this
> set on the whoop because she had an early travel, but only didn't want to change the entire
> routine, but only had to change it for this day. And then the next day she can actually sleep
> again until eight."*

> *"So think about people who have routines and also who just do it day by day. So there are also
> some people who don't set alarms at all or set it from one day to another. They don't care if it's
> a Monday, Friday, Tuesday. On the evening they suggest the alarm for the next day."*

## Three relationships to routine, not one

The design so far assumed everybody has routines. That is one of three populations, and possibly not
the largest.

| | How they think | What the app must be |
|---|---|---|
| **Routine led** | "I wake at 07:45 on weekdays" | a statement they rarely touch, plus a way to bend one day |
| **Day by day** | "What time do I need to get up tomorrow?" | an evening question, asked and answered in one gesture |
| **No alarm** | "Tell me when to sleep, don't wake me" | recommendations with nothing armed |

**Day by day is not a degraded routine user.** For them a weekday and weekend split is noise, and a
screen built around routines makes them navigate past a concept they will never use. Both remote
services support this population explicitly: Whoop offers a one night alarm and a
`DON'T USE AN ALARM` option that still gives bed and wake recommendations, and Eight Sleep offers
`Repeat: Never`.

**No alarm at all is a real setting, not an empty state.** Whoop's own words: *"Get bed and wake time
recommendations without being woken up by an alarm."* An app that treats zero alarms as a
misconfiguration to be fixed is wrong about these users.

## The one day override, and why it is harder than it looks

Her routine says 07:45 Monday to Friday. On Tuesday she wants 08:00. On Wednesday she is back to
07:45 **without doing anything**.

Three properties, and the third is the one that gets skipped:

1. It applies to one date only.
2. It does not modify the routine.
3. **It reverts by itself.** An override that must be cancelled is an override that eventually
   fires on a morning nobody chose. This is the failure mode that turns a convenience into an
   oversleep.

## The case that changes the architecture

> *"maybe she had this set on the whoop because she had an early travel"*

**She made the change in Whoop's own app, not in OneAlarm.**

This is the sharpest thing in his message and nothing in the current design handles it. Today
OneAlarm treats itself as the sole author of every alarm: it reads, edits and writes, and anything a
user changed elsewhere is overwritten on the next press of Set all alarms.

That is not hypothetical. **It already happened on the first night.** Turning on all seven days for a
test rewrote his real Whoop schedule from Monday-to-Friday into every day, because the Whoop write
replaces rather than merges. The app destroyed a setting its user had made, silently, and he found
out by looking at the Whoop app for an unrelated reason.

So the model has to change from **owner** to **participant**:

- Before writing, compare what is on the device against what OneAlarm last wrote there.
- If they differ, somebody else changed it. That is information, not an error.
- Never silently overwrite a difference. Either adopt it, or ask, and say which alarm and which
  value.
- Adopting is often correct: if she set 05:00 on Whoop for a flight, the honest reading is that
  05:00 is what she wants tomorrow, and the phone and the bed should follow it rather than fight it.

Which points at a stronger idea than either the routine or the override: **any device can be the one
that gets changed, and the others follow.** She sets 05:00 in the Whoop app; OneAlarm notices, and
offers to move the bed and the phone to match. That is the same mechanism Alex asked for when he said
he wanted to pick which device is the main alarm, arriving from a completely different direction,
which is usually a sign the mechanism is the right one.

## What this means for the team

Questions the design must answer, and the current spec does not:

1. What does the app look like for a user who has never created a routine and never will?
2. How is "just tomorrow" expressed so that a day by day user never sees the word routine, and a
   routine user gets the exception without editing the rule?
3. What happens on the morning after an override, with no user action, on every leg?
4. How does the app detect that a device was changed elsewhere, and what does it do about it?
5. On Whoop specifically, where a one night alarm requires disabling the recurring schedule, what is
   the safe sequence, and what happens if the app dies between the disable and the re-enable?
6. What does "no alarm" look like as a chosen state rather than an unconfigured one?
