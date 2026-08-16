# Experiments

Everything this project does not know, written as a test rather than a worry.

An entry earns its place only if it has all five: the question, why it matters, the cheapest thing
that answers it, **what each possible result would mean**, and whose job it is. The fourth is the
one that gets skipped, and skipping it is how six rounds of Whoop debugging happened: each result
was interpreted after the fact, so every result confirmed the current theory.

Rules:

- **One variable.** If a test changes two things, its result means nothing. This cost five hours.
- **Never test on a live account with settings that are not test settings.** Turning on all seven
  days to test the ring rewrote a real Whoop schedule. Restore before, or test on a value that is
  already correct.
- **Write the prediction before running it.** A prediction recorded afterwards is a rationalisation.
- Results go in `docs/LEARNED.md` with an evidence marker, whichever way they fall.

Status: 🔴 blocking · 🟠 shapes the build · 🟡 good to know

---

## E1 🔴 Does the strap actually buzz at the new time?

**Why.** Everything the Whoop leg does is worthless if the answer is no, and every current signal
says yes when it might be no. Whoop's server holds the value, the Whoop app displays it, and the
strap is a third thing. The Whoop app sends `PUT /smart-alarm-service/v1/strap-status` after an edit
and OneAlarm does not, deliberately, because that whole service prefix is outside the allowlist.

**Test.** Set a wake time through OneAlarm only. Do **not** open the Whoop app afterwards, since
opening it is what syncs the strap and would confound the result. Wear the strap. Observe.

**Predictions.**

| Result | Means | Then |
|---|---|---|
| Buzzes at the new time | the strap syncs without the app in the loop | nothing to build |
| Buzzes at the old time | the schedule write alone does not reach firmware | either send `strap-status`, which needs an allowlist entry and a deliberate decision, or tell the user to open the Whoop app after every change |
| Does not buzz at all | the master switch or a sync path is off | check `schedule_enabled`, then E7 |

**Whose.** Alex, one night. Nothing here can observe a wrist.

---

## E2 🟠 Which Whoop body shape does the server accept?

**Why.** The write currently tries up to three shapes and stops at the first that works. Pinning it
takes the write from three requests to one, which matters against a private API with rate discipline.

**Test.** Read the green text on the Whoop row after a successful Set. It names the accepted shape.
Zero requests: the fact is already on screen.

**Predictions.** `domain` means the six-key body is right and the retry can be deleted.
`domain/IN_THE_GREEN` means the enum was the problem **and OneAlarm changed his wake mode**, which is
a bug to fix rather than a result to keep. `viewmodel` would overturn the whole 16 August conclusion
and needs the research doc rewritten again.

**Whose.** Alex, one screenshot.

---

## E3 🟠 Does Eight Sleep name its pods?

**Why.** Two alarms at the same time on two pods are indistinguishable in the picker, and picking
wrong moves the wrong bed with no symptom until somebody does not wake up.

**Test.** Already built and shipped. Open Connections, Eight Sleep. The picker now prints either a
heading per bed, or "This account did not name its beds" followed by the real field list. The
diagnostic fires on a **successful** parse, which is the change that makes the question answerable
at all.

**Predictions.** A heading means grouping works and the same labels belong on the main screen. The
field list means the name is somewhere else, most likely a separate devices endpoint, which is a new
allowlist entry and a deliberate decision rather than a guess.

**Whose.** Alex, one screenshot. Already possible.

---

## E4 🟠 Does omitting `repeat` on an Eight Sleep PUT create a one-off?

**Why.** The whole dated-override design rests on it. `docs/SETTINGS.md` flags it as untested and
keeps the feature **on by default**, which is the wrong way round for an untested assumption.

**Test.** On a **disposable** alarm, not his real one: create a second alarm in the Eight Sleep app,
point OneAlarm at it, write with `repeat` omitted, then re-read.

**Predictions.** If the returned object shows the recurrence cleared, one-offs work. If it comes back
**unchanged**, then omission means "leave alone", and a dated item would silently become a recurring
alarm at the wrong time, which is the worst failure this app can produce. In that case the override
must set `repeat.enabled = false` explicitly and restore it after.

**Whose.** Alex sets up the disposable alarm; the app does the rest. **Do not run this on his real
alarm.**

---

## E5 🟠 What happens on a paired Apple Watch?

**Why.** His iOS setting `Always Play on iPhone` is **off**, so Apple's own sleep alarm moves to the
watch when he wears it to bed. Whether OneAlarm's AlarmKit alarm does the same is unknown, and
"the phone rings" and "something on your body rings" are different guarantees. The ring test on
16 August was run without the watch.

**Test.** Repeat the ring test wearing the watch. Two minutes ahead, Silent on, Focus on, phone
locked and face down, watch on the wrist.

**Predictions.** Watch only, phone only, both, or neither. **Neither** is the dangerous one and is
not far-fetched, because the alarm may route to a device that is asleep on a charger.

**Whose.** Alex, two minutes.

---

> **E3 ANSWERED, 2026-08-16.** The account returned three alarms and this field list:
> `audio, dismissedUntil, enabled, id, repeat, skipNext, skippedUntil, smart, snoozedUntil,
> snoozing, tags, thermal, time, vibration`.
>
> **No name, no label, no side, no deviceId.** Eight Sleep alarms are account level, not bed level,
> so grouping by bed cannot come from this object. Whether `tags` carries one is the only thread
> left, and its value has never been printed.
>
> Three fields nobody had looked at, and two of them change the design:
>
> - **`skipNext`** and `skippedUntil`. Eight Sleep has a **native skip next occurrence**. That is
>   the third verb, built in, with no restore task and no risk of a failed restore leaving a real
>   alarm wrong. The whole "disable then re-enable" hazard may not apply to this leg at all.
> - **`smart`**. The thirty minute window is a **readable field** rather than a number taken from a
>   sentence in their UI. Read it instead of assuming it.
> - `audio` and `tags`, unexamined.

> **E3 FOLLOW UP, 2026-08-16, and it reopens the question.** `tags` was printed and it is not
> decoration:
>
> ```
> tags  = ( "routine-94b49169-0ef4-4739-ae95-124e45473c97" )
> smart = { lightSleepEnabled = 1; sleepCapEnabled = 0; sleepCapMinutes = 480 }
> audio = { enabled = 0; level = 30 }
> skipNext = 0
> skippedUntil = 2026-08-16T22:19:00Z
> ```
>
> **Every alarm is stamped with a routine id.** If routines are per bed or per side, that is the
> link from an alarm to a Pod, and the earlier conclusion that alarms are irreducibly account level
> was wrong. It was drawn from the absence of a `deviceId`, which is the same reasoning that was
> wrong about Whoop's field names and wrong about Eight Sleep's bed names: **absence in one object
> is not absence everywhere.** Three times now.
>
> Also: **`smart` carries no window length.** `sleepCapMinutes` is 480, which is eight hours, so it
> is a sleep cap and not a wake window. The 30 minute figure in this project came from a sentence in
> the Eight Sleep UI and is still `[to confirm]`, not confirmed by this.
>
> And `skippedUntil` holds a real timestamp while `skipNext` is 0, so the two are not a simple pair
> and the native skip is not yet understood well enough to use.

> **E3 AND E6 ANSWERED, 2026-08-16. The question was wrong, not just unanswered.**
>
> **Eight Sleep alarms are user scoped.** One alarm list per account, and it fires on whichever Pod
> the account is currently assigned to. So an alarm does not belong to a bed, has never belonged to
> a bed, and "which bed does this alarm control" has no answer because it is not a property that
> exists. The `routine-` tag links an alarm to a **bedtime pairing**, a day of week grouping of a
> bedtime schedule with an alarm, not to a Pod. A captured routines response carries no `deviceId`,
> no `side` and no name.
>
> **The answerable question is "which bed am I on", and the Pod's name does exist.** Two reads:
>
> | | Gives |
> |---|---|
> | `GET https://client-api.8slp.net/v1/users/me` | `currentDevice.{id, side, timeZone}` and `devices[]`. Side is `left`, `right`, `solo` or `away` |
> | `GET https://app-api.8slp.net/v1/household/users/{id}/summary` | `deviceName` per Pod. **The only place in the whole API a user visible Pod name exists.** `/v1/devices/{id}` has a model, a serial and a firmware version, and no name |
>
> Both are now in the allowlist and the picker states the answer once, at account level, rather than
> badging each row with a bed it cannot know.
>
> **Do not write to `tags`.** It is generic cross object glue, present on alarms, on bedtime
> schedules and on temperature state. Overwriting it very likely detaches the alarm from its
> routine and silently breaks the bedtime pairing.
>
> **Correction, same day, from his own screenshots.** The Eight Sleep app shows `23:49 - 00:19` and
> `08:30 - 09:00` on his two live alarms. Both are exactly **30 minutes**, on two different alarms,
> on his account. So the number is right and the earlier line below is too strong: it is not
> invented, it is **UI derived and corroborated twice**, which is better evidence than a single
> sentence in marketing copy and still not a field in the API.
>
> **The 30 minute smart window is not in the API.** No window length field exists anywhere in this API.
> The figure came from a sentence in Eight Sleep's own UI. A real window can be derived, but only
> when the alarm is scheduled: `startTimestamp` to `nextTimestamp`. Until then the app should print
> no number. **This means every range the bed's row has ever drawn was invented.**

## E6 🟡 Can one Eight Sleep account expose both sides of one bed?

**Why.** It decides whether the couple case is a real product case or out of scope. The spec
currently caps the picker copy rather than answering it.

**Test.** E3's field list answers it for free if a `side` field appears.

**Whose.** Falls out of E3.

---

## E7 🟡 Does Whoop's `IN_THE_GREEN` accept a written time?

**Why.** It is the mode that gives smart wake while leaving the time ours to set, and it is probably
the setting Alex should live on. `EXACT_TIME` works today, and `SLEEP_GOAL` also takes a ceiling.

**Test.** Set `IN_THE_GREEN` in the Whoop app, then Set all alarms in OneAlarm.

**Prediction.** Success means the mode control is a three-way and the app can offer smart wake
properly. Failure with a 422 means `EXACT_TIME` is the only writable mode, which is a real product
limitation and belongs on the screen.

**Whose.** Alex, one minute, after E1 and E2.

---

## E8 🟡 Does removing a weekday from an armed AlarmKit weekly alarm work, in the foreground, within seconds?

**Why.** It is the mechanism the entire override design rests on. `docs/SETTINGS.md` calls it
"synchronous suppression" and requires it to be read back before the screen says the alarm is
silenced. It has never been run.

**Test.** Arm a weekly alarm, remove one weekday, read back, time it.

**Predictions.** If it is reliable and fast, overrides work as specified. If it is slow or
unreliable, the screen has to say "your routine alarm is still armed for Tuesday", which the spec
already anticipates but nobody has seen.

**Whose.** The build. Needs Xcode.

---

## E9 🟡 Is Whoop's 60 minute window the same in every mode?

**Why.** The number came from one UI string on one account in one mode. The row draws a range from
it, and a wrong range is a wrong claim about when he will be woken.

**Test.** Read the range sentence in the Whoop app under `IN_THE_GREEN` and under `SLEEP_GOAL` and
compare.

**Whose.** Alex, two screenshots. Costs nothing and closes a `[to confirm]`.

---

## E10 🔴 Does the app still work after the iOS sleep alarm is switched off?

**Why.** The remedy for the duplicate alarm is to turn off the `Alarm` toggle inside his Sleep
Schedule. Whether that also disturbs the sleep tracking, the Sleep Focus, or the wind-down that he
values has not been checked, and the instruction was given without checking.

**Test.** Turn it off. The next morning, look at whether Health still recorded the night.

**Prediction.** Expected to be fine: the schedule and the alarm are separate toggles on that screen.
Expected is not observed, and this one was recommended to him already.

**Whose.** Alex, one night.

---

---

## E11 🔴 Does Eight Sleep's `skipNext` do what its name says?

**Why.** A skip is one of Alex's three verbs: *"maybe to don't use the routine today."* On the phone
it is expressible. On Eight Sleep the only candidate is `skipNext`, a field on every alarm object
that this app reads, echoes, and has never written. Its behaviour is known from its name and nothing
else, and reasoning about a field name is what cost five hours on Whoop. So a skip is currently
**stated on screen and not propagated**, which means the bed still warms and vibrates on a morning
Alex asked to skip.

**Test.** Switch one alarm's skip on inside the Eight Sleep app. Read `GET /v2/users/{id}/alarms`
before and after and diff the object. Then look at whether `skippedUntil` moves with it, and whether
it clears itself after the skipped morning.

**Prediction.** `skipNext` goes true and `skippedUntil` is set to the instant of the occurrence being
skipped, and both clear once it passes. If that holds, a skip becomes one boolean on one matched
alarm and needs no new endpoint. Written before the test, on purpose.

**Whose.** Alex, one toggle in their app, then one tap of Set in OneAlarm to capture the diff.

---

## E12 🟠 Does Whoop's single schedule mean his weekend days get overwritten?

**Why.** Eight Sleep holds one alarm per day set, so OneAlarm can now drive a whole week there
without ever writing days. Whoop holds **one** schedule. Its `day_of_week_list` therefore has to be
written, and it can only carry the routine covering tonight, which means a Friday night sync writes
`SATURDAY, SUNDAY` over a Monday to Friday list. That is the same shape as the damage already done
on 15 August, and this time it is structural rather than accidental.

**Test.** With a Monday to Friday routine and a weekend routine both set, sync on a Thursday and read
the Whoop app, then sync on a Friday and read it again.

**Prediction.** The Friday sync leaves Whoop showing Saturday and Sunday only, and Monday morning has
no Whoop alarm. If so, the honest options are: write the routine covering tonight and say on screen
that Whoop holds one schedule, or stop writing Whoop days at all and only ever move its time.

**Whose.** The build, plus two screenshots from Alex.


---

## E13 🔴 Does the Eight Sleep app read the alarm object we write, or something else?

**Why.** On 16 August the write landed on the API and Alex reported his Eight Sleep app still showing
the old time. Those are two different claims and only one of them is ours. The bed screen, reading
live from `GET /v2/users/{id}/alarms`, showed `08:55` for the weekday alarm, which is exactly what
OneAlarm sent. So the object we can reach agrees with us.

**The lead.** Every alarm on this account carries `tags: ["routine-<uuid>"]`. Their current app puts
alarms **inside routines**, and nobody here has ever looked at a routine object. If their app renders
the time from the routine rather than from the alarm, the alarm's `time` is a mirror their UI never
reads, and every write so far has been landing in a field nothing displays.

**Note what this exposes.** Eight Sleep has only ever been verified at the API layer, against
`nextTimestamp`. It was never once confirmed in their app, unlike Whoop, which was. `docs/STATUS.md`
called this leg **working** on the strength of a check that could not have caught this.

**Test, in order, cheapest first.**
1. Force quit the Eight Sleep app and reopen. Their app caches. If the new time appears, there is no
   bug and the answer is a stale view.
2. If not: open OneAlarm, Connections, Eight Sleep, and read "What Eight Sleep returns right now".
   Compare its `time` and `nextTimestamp` against what their app shows.
3. If the server holds our time and their app does not show it, find the routine object. Nothing may
   be written to it until it has been read and its shape captured.

**Prediction.** The server holds `08:55:00` and their app shows the old time, and the routine object
carries its own copy. Written before the test.

**Whose.** Step 1 and 2 are Alex, one minute. Step 3 is the build, and it is read only until there is
a capture.


---

## E14 🔴 Does a cloned alarm carrying another alarm's `routine-` tag show up in their app?

**Why.** OneAlarm now creates a missing alarm by cloning one Alex already has. The clone keeps the
template's `tags: ["routine-<uuid>"]`, which is a decision made by reasoning about a field name, and
this project has been wrong doing exactly that three times.

**The reasoning, stated so it can be shot down.** Their app appears to render alarms through bedtime
routines. An alarm created with **no** tag may be an alarm their app never lists, which is precisely
the failure being fixed. Carrying the template's tag puts the new alarm wherever the template lives.

**The counter-case, which is why this is red.** If the tag identifies a routine that already owns a
weekday alarm, a weekend clone carrying that same tag may be rejected, may replace it, or may appear
under the wrong routine.

**Test.** Let OneAlarm create the weekend alarm. Open the Eight Sleep app. Look for a Saturday and
Sunday alarm at the expected time, and check the weekday one is still there and unchanged.

**Prediction.** The clone appears and the template is untouched. If it does not appear, the next
thing to try is posting with `tags` removed, and the one after that is reading a routine object
before writing anything near one.

**Whose.** Alex, one tap of Set all alarms and one look at their app. Anything it creates is deleted
by hand there, because OneAlarm has no delete and is not getting one.

---

## E15 🟠 Are some alarms on this account invisible in the Eight Sleep app?

**Why.** On 16 Aug at 11:51 OneAlarm read a Monday to Friday alarm at 08:55 off the API. At 11:52 the
Eight Sleep app showed **no alarms at all**, only a greyed suggestion at 07:00. Then Alex created a
Monday to Friday alarm by hand and OneAlarm's next write moved its time, visibly, in their app.

That fits one explanation better than any other: the API returns alarms their app does not list, and
OneAlarm had been correctly updating one of those. It also explains three alarms against two, and it
explains why yesterday looked like it worked: yesterday the app moved whichever alarm was **picked**,
and a picked alarm that happens to be visible works while a picked alarm that happens to be orphaned
does not, with nothing on screen distinguishing them.

**Test.** In the bed screen, read "What Eight Sleep returns right now". Compare each alarm's `tags`
against the alarms visible in their app. If the invisible ones carry a `routine-` uuid that the
visible ones do not share, the tag is the link and an orphaned tag is the cause.

**Prediction.** At least one returned alarm is not in their app, and the difference is in `tags`.

**Whose.** Alex, one screenshot of each.


---

## E16 🔴 Which API version creates an Eight Sleep alarm?

**Why.** The create has been refused twice with no reason surfaced, and the path it was sent to is the
least evidenced thing in the adapter. This API is asymmetric where it has been observed: the list is
`GET /v2/users/{id}/alarms` and the update is `PUT /v1/users/{id}/alarms/{alarmId}`, both confirmed
against Alex's account. The create path was taken from a write-up, never a capture. A search of every
public Eight Sleep project on 16 August found the list documented and the create documented nowhere,
including in the two CLIs that expose an `alarm create` command.

**Why it matters more than the payload.** A wrong path refuses every payload shape identically. Three
rounds of dropping fields off the body would all fail the same way and would look exactly like a
payload problem, and the fix would be to discard settings of his chasing a phantom.

**Test.** The ladder now tries the full clone on `v1` and then on `v2` before dropping any field, and
names every attempt with the status and the server's body. Two requests separate path from payload.

**Prediction.** `v2` is the create, matching the list rather than the update, and `v1` returns 404 or
405. Written before the test. If both refuse the full clone identically, the path is not the problem
and the ladder's later rungs are the answer.

**Answered, 16 Aug, and the prediction was wrong.** Two independent public sources give the create as
`POST /v1/users/{id}/alarms`, which is what this app was already sending. So the path was never the
problem and the `v2` rung is dead weight, kept only until one run confirms it. The real finding came
out of the same search and is `E17`, below.

**Whose.** Alex, one tap of Set all alarms, then the Eight Sleep row's text.


---

## E17 🔴 Eight Sleep has a **routines** object, and alarms live inside it

**The find.** `PUT https://app-api.8slp.net/v2/users/{userId}/routines/{routineId}`, from a public
capture, carries:

```
id, enabled, days: ["monday", ...], bedtime: { time, dayOffset },
alarms: [], alarmsToCreate: [ { enabled, disabledIndividually,
  timeWithOffset: { time, dayOffset },
  settings: { vibration: {enabled, powerLevel, pattern}, thermal: {enabled, level} },
  dismissedUntil, snoozedUntil } ]
```

**Why this answers three open questions at once.**

1. It is what the `routine-<uuid>` in every alarm's `tags` points at. That tag sat in the diagnostic
   output for a day with nobody able to say what it referenced.
2. It explains `E15`. An alarm created through `POST /v1/users/{id}/alarms` belongs to no routine, and
   their app renders alarms through routines, so it exists on the API and appears nowhere. That is
   exactly what Alex saw: the API returned a Monday to Friday alarm at 08:55 and his app showed none.
3. **The days may live on the routine, not on the alarm.** The routine carries `days`. If their app
   reads days from there, then writing `repeat.weekDays` on the alarm changes a field their UI never
   displays, and "change Monday to Friday into Monday to Wednesday" cannot work through the alarm
   object at all.

**Same lesson, fourth time.** Absence in one object is not absence anywhere. The alarm object has no
routine and no days their app respects because the **routine** carries both, and nobody had called
that endpoint.

**Test, and it is a read.** `GET /v2/users/{id}/routines` is allowlisted now and its output is printed
verbatim on the bed screen under "Your Eight Sleep routines, raw". Nothing is written to a routine
until a real one off Alex's account has been seen: the shape above is somebody else's capture, which
is evidence about what the endpoint is and none about what his holds.

**Prediction.** His account returns at least one routine, each with a `days` array and an `alarms`
array containing ids OneAlarm has been writing to, and the weekday routine's `days` will match what
his app shows rather than what the alarm's `repeat.weekDays` says.

**Whose.** Alex, one screenshot of that panel. Then the build, against his shape.


## Completed

| | Question | Answer | Date |
|---|---|---|---|
| ✅ | Does the iPhone alarm ring through Silent and Focus, locked? | **Yes** | 16 Aug |
| ✅ | Does Eight Sleep accept and hold a written time? | **Yes**, verified against an absolute instant | 15 Aug |
| ✅ | Does the Whoop write work? | **Yes**, six-key body, confirmed in the Whoop app | 16 Aug |
| ✅ | Is `latest_wake_time` on the write a display string? | **No.** Canonical `"HH:mm:ss"` | 16 Aug |
| ✅ | Do `day_of_week_list`, `enabled`, `time_zone_offset`, `sleep_goal` exist? | **Yes**, on the resource. They are absent from the screen response, which is what caused the confusion | 16 Aug |
