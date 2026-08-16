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

## Three verbs, and they must never be confused with each other

> *"So even if they would switch to use only one alarm, they still maybe want to have routines and
> then maybe want to deviate from routines. So maybe to don't use the routine today, or maybe they
> want to change the routine. So they used to wake up on Saturday, Sundays, they had a wake up alarm
> for nine AM, but then they went out on Friday, and they want to wake up on Saturday instead of
> nine AM. They want to sleep in until ten, but Sunday shouldn't be touched."*

| Verb | Scope | Lasts | Sunday, in his example |
|---|---|---|---|
| **Change the routine** | every day the routine covers | until changed again | also moves to 10:00. Wrong here |
| **Bend one date** | that date only | reverts by itself | stays 09:00. Correct |
| **Skip one date** | that date only, no alarm at all | reverts by itself | stays 09:00 |

**The override is keyed by a date, not by a weekday.** This is the distinction his example exists to
make. A weekend routine covers Saturday and Sunday; he wants Saturday the 16th at 10:00 and Sunday
untouched. Keyed by weekday, "change Saturday" would move every Saturday forever, which is the
routine, not a deviation from it. Keyed by date, next Saturday is 09:00 again with no action.

**Skip is a third verb, not an override to zero.** *"Don't use the routine today"* is a distinct
intent: no alarm tomorrow, routine intact, back to normal the day after. It is what a day off looks
like, and it needs to be one gesture from the main screen, because the alternative is disabling the
routine and forgetting to re-enable it, which is the oversleep this whole document keeps circling.

## Adopt Apple's model, which is the same idea with one concept instead of three

> *"What about doing it like Apple is doing? So we just have their routine. And then if we change the
> alarm, it will prompt, show we changed the entire routine or just for the next day. And this way we
> can keep the screen clean and still have it in the background working. And of course displayed in
> the main screen that this routine was not changed, only the one day alarm."*

Alex, 2026-08-16, after sending screenshots of iOS Health, Sleep, Change Wake Up. Apple's own prompt:

> **Would you like to apply this change to all weekdays in this schedule?**
> **Change Next Alarm Only** · **Change This Schedule**

**Adopt it.** It is the same design the team arrived at, with one concept instead of three, from the
most tested alarm interface in existence. He already knows the gesture. There is no screen to teach.

Three amendments, each small:

**Name the date.** Apple's weak spot is "Next Alarm Only", which does not say which morning. That
exact ambiguity cost a ring test at 01:00 on a Sunday, when a weekday alarm correctly did not fire
and read as a broken app. Ours says `Just tomorrow, Saturday 16 August` and `Every weekend, from now
on`.

**Put the same prompt on the off switch.** Apple has none, so skipping a day means turning the alarm
off and remembering to turn it back on, which is the oversleep this project keeps designing against.
The same question on the toggle covers the third verb and removes a button from the main screen.

**The standing line, which is his and is load bearing.** While an override is live the main screen
says what it did and **when it ends**: `Tomorrow only, 10:00. Your weekend routine is still 10:30 and
returns on Sunday.` Without it a bent day and a changed routine look identical, and the difference is
discovered on Sunday.

### What this costs, stated rather than glossed

**The surface simplifies; the machinery does not.** Apple can offer "next alarm only" cheaply because
it owns the alarm. One night on the bed means change it, then put it back after it fires, so the
restore tasks survive intact behind a cleaner screen.

**Whoop cannot do it at all.** Its one-off requires disabling the recurring schedule, and a failed
re-enable leaves the real alarm silently off. So the override moves the phone and the bed and leaves
the strap on its routine, saying so on that line. One missed early wrist buzz is the cheapest failure
available here.

**The shape is borrowed, not the data.** OneAlarm cannot read the iOS sleep schedule, so he keeps two:
Apple's with its alarm switched off, and this one. Matching the model at least stops them being two
different ideas.

## The phone is the one leg OneAlarm does not move, and the app claims otherwise

> *"Right now, what rings whenever I set an iPhone is an additional alarm and not the actual
> routine. So I still have my sleep schedule and my alarm for the sleep schedule even on the iPhone
> setup and not the routine."*

Observed on the device, 2026-08-16. He is right and the consequence is larger than it sounds.

**AlarmKit alarms belong to the app that created them.** iOS exposes no API to read, change or delete
a Clock app alarm or the Health sleep schedule. So:

| Leg | What OneAlarm does |
|---|---|
| Eight Sleep | reads the existing alarm, changes the time, writes it back |
| Whoop | reads the existing schedule, changes the time, writes it back |
| iPhone | **creates a second alarm beside whatever the phone already has** |

Onboarding step one says OneAlarm *"moves alarms you already have, never creates or deletes"*. True
for two legs, **false for the third**, and stated as though it were universal.

**It defeats the override outright.** Suppress the routine for Saturday, set 10:30, and the Sleep
Schedule alarm still fires at 07:45. The suppression worked perfectly and he is awake at 07:45
regardless. Every mechanism in the spec sits downstream of an alarm the app cannot see.

There is no code fix. The phone can hold one master and OneAlarm cannot become the existing one, so
**the native alarm has to be off**. Since it cannot be detected either, saying so is the entire
remedy, which means it has to be said properly:

- Onboarding, its own step, before permission is requested, with the exact taps to turn off both a
  Clock alarm and a Sleep Schedule wake alarm.
- A permanent line on the iPhone row, not a dismissible banner: `Your phone's own alarms still ring.
  OneAlarm cannot see or change them.`
- The line stays forever. It is not a setup task that can be completed, because he can create a
  Clock alarm at any time and nothing will notice.

## Editing the anchor should mean editing the plan

> *"If I have a fixed routine and I change one of the dominant, let's say the iPhone is the dominant,
> the first hierarchy thing, it rings at eight AM, and I change it to eight ten, then the entire
> routine needs to be changed, and then also updated inside the apps."*

He does not think in terms of a master time that devices derive from. He thinks in terms of **the
alarm that wakes him**, which is the phone, with the others arranged around it. The spec's master is
already the phone's time, since the primary leg has a lead of zero, so the model agrees with him. The
screen does not: the header is editable and the rows are not.

So the anchor device's row should be editable and mean the same thing as the header. Same sheet, same
three verbs. A row that displays the number he thinks of as his alarm, and cannot be tapped, teaches
him that the header is a separate concept, which it is not.

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

Alex on what the goal actually is:

> *"It would be great that one alarm would be the sole author, but I think we need to also remember
> that people will be using other apps."*

So sole authorship is the **aim**, not the assumption. The app should be the place these alarms are
set, and should behave as though it is, right up to the moment the evidence says otherwise. What it
must never do is assume it was the last one to write and act on that assumption without checking.
That is a cheap check: one read, which both legs already perform before every write.

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
7. How are the three verbs offered without a menu? Changing the routine, bending one date and
   skipping one date are different intents that all begin with the user looking at the same number
   and wanting it to be different.
8. A user moves between populations over time: day by day for a month, then routines, then back.
   Nothing should have to be deleted or migrated for that to work.
