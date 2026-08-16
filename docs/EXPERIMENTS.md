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

## E14 ✅ No, and carrying the tag is what hid it. **Fix confirmed on his bed, 17 Aug 14:21.**

> **CONFIRMED IN HIS OWN APP.** After `clone` stopped copying `tags`, the Eight Sleep app lists:
>
> ```
> EVERY WEEKDAY   05:51    36C  Heavy
> EVERY WEEKEND   09:55    36C  Heavy
> ```
>
> The weekend alarm is the first alarm OneAlarm has ever created that Alex can see. His temperature
> and vibration came across untouched, which is the other half of the result: stripping `tags` did not
> cost him any setting he chose.
>
> This is the layer that counts. Two weeks of green rows, matching read-backs and verified absolute
> instants never once meant the feature worked.

**The answer, from Alex's own bed.** No alarm on his account carries a `routine-` tag **now**. One did
on 16 August, printed in the E3 follow-up above as
`tags = ( "routine-94b49169-0ef4-4739-ae95-124e45473c97" )`, on an alarm that no longer exists. So
routine tags are real on this account, and this entry must not be read as saying they are not.

What it says is narrower and sharper: **a routine tag is not what decides whether their app shows an
alarm.** The alarm his app lists today has no tags at all. The two it hides carry a nap tag. If
routine membership were the qualification, the listed one would be the tagged one.

| time | days | `tags` | listed in the Eight Sleep app |
|---|---|---|---|
| 05:57 | weekdays | `()` | **yes**, he made this one by hand |
| 05:55 | weekdays | `temporary-mode`, `oneOff-napMode` | no |
| 09:56 | Sa Su | `temporary-mode`, `oneOff-napMode` | no |

So keeping `tags` was not neutral cargo. It stamped "this is a nap timer" onto a real alarm, their app
filtered it out of the Alarms list, and the next clone inherited the stamp from the clone before it.
One hidden alarm became two by exactly that route, and it would have continued to the cap of eight.

`clone` now strips `tags`, and `template(from:)` prefers an alarm he can see, so the settings copied
are ones he actually chose. Both are covered by tests, including the case where the hidden alarm is
returned first, which is what happened on his account.

**Why the prediction was wrong, which is the part worth keeping.** The `routine-<uuid>` in `tags` came
from a public capture of somebody else's account and was treated as a fact about the API. It is not
present here at all. The standing rule already says never infer absence from an object you did not
look at; this is its mirror, and it needs saying too: **never infer presence from an object you did
not look at either.** One read of his account settled in ten seconds what two days of reasoning got
backwards.

---

## E14-old 🔴 Does a cloned alarm carrying another alarm's `routine-` tag show up in their app?

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

## E15 ✅ Yes, and the difference is `tags`, but not the tag anyone predicted

**Answered 17 August, 12:10, from Alex's own account.** The first hard data this project has had about
why an alarm exists on the API and not in his app. It confirms E15's prediction and **refutes the
mechanism E14 and E17 were built on.**

What his bed returns, against what his app lists:

| time | days | `tags` | in the Eight Sleep app |
|---|---|---|---|
| 06:55 | weekdays | `()` **empty** | **yes** |
| 10:55 | Sa Su | `("temporary-mode", "oneOff-napMode")` | no |
| 06:55 | weekdays | `("temporary-mode", "oneOff-napMode")` | no |

Three alarms on the API, one in the app. So E15's prediction holds: invisible alarms exist and the
difference is in `tags`.

**But it runs the opposite way from the theory.** E14 and E17 both assume `tags` carries a
`routine-<uuid>` and that routine membership is what makes an alarm visible. **Not one alarm on this
account carries a routine tag**, and the alarm that IS visible is the one with no tags at all. If
routine membership were the qualification, the visible alarm would be the tagged one. It is the
reverse.

**What the data supports instead.** The two hidden alarms are tagged `oneOff-napMode` and
`temporary-mode`. `docs/RESEARCH.md` §1.5 documents `POST /v1/users/{id}/alarms` under the heading
"Create a one-off". That is the endpoint OneAlarm used to create both of them. So the most economical
reading is that **the create endpoint produces one-off nap alarms, and their app deliberately does not
list nap timers among alarms.** The create was never refused and never silently failed. It did
exactly what that endpoint does, and that turns out not to be the thing wanted.

It also explains the duplicate: a second 06:55 weekday alarm is an earlier clone of his real one,
made the same way, hidden the same way.

**What this does not tell us**, and the honest limit of it: it does not say how their app creates a
**recurring** alarm, and it does not say whether this account has routines at all. The routines panel
has still never been opened. Until it is, the routine write in `authorRoutine` is aimed at an object
nobody has confirmed exists here.

**Consequence to fix, and it is a harm this app caused.** Those two alarms cannot be seen in the Eight
Sleep app, so Alex cannot delete them there, and OneAlarm has no delete on any service by design. The
account is capped at 8. Every further create through this endpoint adds another one he cannot see or
remove. **The create path must not run again until the routines question is answered.**

---

## E15-old 🟠 Are some alarms on this account invisible in the Eight Sleep app?

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

## E17 ❌ Refuted on his account. He has no routines at all.

**17 August, 14:05.** "Your Eight Sleep routines, raw" printed:

> This account returned no routines, and the read itself succeeded.

That sentence is deliberately two facts, because they mean opposite things and look identical from
outside. `GET /v2/users/{id}/routines` answered **200 with an empty list**. The address is right, the
token works, the subscription is fine, and there are no routines.

So the theory below is dead for this account. Their app is not rendering his alarms through routines,
because he has none, and it still shows one of his three alarms. The thing that decides visibility is
`tags`, which is `E14`.

**What survives.** The routine read stays: it is a read, it costs one request, and it is the only
thing that can tell a future session that this is still true. The routine write in `authorRoutine` is
now unreachable on his account and stays unexecuted rather than deleted, because the code is correct
for an account that has routines and deleting it would only mean rebuilding it from the same captures
if he ever gets one. **It must not be described anywhere as the mechanism.**

**What it cost.** A night. The write-up it came from is not wrong about the API in general, it is
simply about a shape his account does not have, and nobody checked before building on it. `E14` says
the rest.

---

## E17-old 🔴 Eight Sleep has a **routines** object, and alarms live inside it

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


---

## E18 ✅ `dayOffset` is a string enum, and the first payload had it as a number

**Found before the test rather than by it**, which is the only entry in this file that can say so.

The routine `alarmsToCreate` shape was built from **one** public capture. A search for a second
implementation found `blacktop/clim8`, which spells the same request independently. They agree, and
they disagree with what this app was about to send:

| Field | Both sources | What OneAlarm had |
|---|---|---|
| `timeWithOffset.dayOffset` | `"Zero"`, a string | `0`, an integer |
| `bedtime.dayOffset` | `"MinusOne"` | echoed, so correct by accident |
| `dismissedUntil` | `"1970-01-01T00:00:00Z"` | absent |
| `snoozedUntil` | `"1970-01-01T00:00:00Z"` | absent |

**Why it matters more than it looks.** A type error in one field comes back as a bare 400 with an
empty body, which is indistinguishable from a wrong endpoint, a wrong version or a wrong object. That
is exactly the failure shape that has consumed this evening, and it would have been blamed on the
routines endpoint rather than on one integer.

**The rule this proves again.** Two sources, or it is not a capture. This project has now been burned
three times by a single write-up: the Whoop field names, the Whoop read shape, and this. The cost
each time was hours, and the fix each time was ten minutes of looking for a second implementation.

**Whose.** Fixed in the build, with a test asserting the string and asserting it is not an integer.
Still needs one real run to confirm the server agrees with both sources.


---

## E19 ✅ `v2`, and the prediction revised mid-flight was the right one.

`GET /v2/users/{id}/routines` returned **200 and an empty list** on 17 August. The v1 fallback had
already been removed for being the retired Routines feature, and the v1 probe was never reached
because it only runs after v2 fails, which v2 did not.

Worth noting what a 200-and-empty proves and what it does not. It proves the address, the token and
the subscription. It proves nothing about the shape of a routine, because none came back. Every field
in `RESEARCH.md` §1.5b is still somebody else's capture.

---

## E19-old 🔴 Which API version **reads** an Eight Sleep routine?

**Why.** The routine **write** is `PUT /v2/users/{id}/routines/{routineId}` in two independent
captures. An OpenAPI description of this API documents a routine **read** as
`GET /v1/users/{userId}/routines`. This service is already asymmetric in exactly this way: the alarm
list is `/v2` while the alarm update is `/v1`, confirmed on Alex's account.

**Why guessing is the worst option.** A 404 on the read makes `fetchRoutines` return empty. Empty is
indistinguishable from "this account has no routines", so the routine write would silently do nothing
and the receipt would report success on the alarm times. That is the precise failure shape this whole
evening has been spent removing, and it would have been the fourth "it still doesn't work".

**Test.** `fetchRoutines` reads **v2 only**. The version that answered is recorded in
`routinesVersion`, which the diagnostic panel prints. A failed read is named in the receipt with its
status, rather than passing as "no routines", and only then does `retiredRoutinesProbe` read v1 as a
labelled diagnostic whose answer is printed and dropped.

**Prediction.** `v2` answers. Written before the test, and **revised down from an earlier prediction
of `v1`**, which is worth recording because the revision came from the project's own notes rather
than from new evidence. `docs/RESEARCH.md` §1.1 says three times that Eight Sleep deleted the
Routines feature and that `/v1/users/{id}/routines` is obsolete for alarm control. The OpenAPI
description that pointed at v1 is a description of that retired object. Two things share the word
"routines" and only one of them is the object with `alarmsToCreate` in it.

**What the earlier design got wrong, and why it was worse than a wrong guess.** The first version of
this read tried v2, then fell back to v1, on the reasoning that whichever answered was the right one.
If v1 answers, that reasoning hands the caller the **retired** object, whose fields then get echoed
into a v2 write. Reading object A and writing it to endpoint B is the shape of the mistake that cost
five hours on the Whoop leg. A fallback is only safe when both branches return the same kind of
thing, and nobody checked that they did.

**Whose.** Alex, one Set and one look at the routines panel, which now prints which version answered.

**Why the session cannot answer this itself.** A 404 against a 401 would settle it with no
credentials at all: one says the path does not exist, the other says it exists and wants a token.
That probe was attempted on 16 August and `app-api.8slp.net` is refused by the session proxy at the
CONNECT stage, gateway 403, four requests, all identical. So the host is unreachable from here
whether authenticated or not, and this is checked rather than assumed. Do not spend the time again.

The same applies to `E16`. Neither version question can be resolved anywhere but on Alex's phone.


---

## E20 🔴 Does `DELETE /v1/users/{id}/alarms/{alarmId}` actually delete an Eight Sleep alarm?

**Why.** Alex overruled the blanket no-delete ban on 17 August, after ending up with three alarms on
his bed and clearing them by hand: *"the one alarm app should be able to delete alarms if there are
changes."* So OneAlarm now deletes an orphaned alarm **it created**. The address is the PUT path with
a different verb, which is a REST convention and **not a captured request**. Nothing public documents
a delete on this API.

**Why guessing was still the right call here, unusually for this project.** The failure mode is
bounded in a way the create's was not. A refused delete is reported with its status and the alarm is
switched off instead, which is exactly what happened before deleting existed. So a wrong guess costs
one wasted request and leaves him no worse off. Compare the create, where a wrong guess sat invisible
on his account for a fortnight.

**What cannot go wrong, and why it is two independent gates rather than care.** The alarm id must be
in `RemoteAlarmLink.created`, recorded at the moment OneAlarm posted it, **and** no live routine may
claim it. An alarm he made is not on that list. An alarm OneAlarm adopted for matching days is not on
that list either, because adoption is not authorship. `testAnAlarmHeMadeIsNeverDeleted` stubs the
delete endpoint to succeed and asserts it is never called.

**Test.** Delete a routine in OneAlarm that owns an alarm OneAlarm created, then Set all alarms. Read
the Eight Sleep row.

| What the row says | Means | Then |
|---|---|---|
| "Deleted 09:00, Sa Su from your bed" | the convention holds | remove this entry, record it in `RESEARCH.md` §1.5 |
| "Could not delete ... (HTTP 405). Switched it off instead." | wrong verb for this path | the alarm object may carry a soft-delete field; look at a full dump before guessing again |
| "... (HTTP 404)" | wrong path | treated as success today, since the alarm is gone either way. Worth a second look if the alarm is still on his bed afterwards |
| "... (HTTP 403)" | deletes need something the token does not have | stop. Switching off is the answer and this entry closes |

**Prediction, written before it runs.** 200 or 204, and the alarm disappears from the Eight Sleep
app. The API is otherwise conventional on this path: the alarm list is `/v2`, the update is `/v1` on
this exact URL, and a resource that accepts PUT at an id usually accepts DELETE there too. Confidence
is moderate, not high, and the fallback is why that is acceptable.

**Whose.** Alex, one routine deletion and one Set.

**Why the session cannot answer it.** `app-api.8slp.net` is refused by the proxy at CONNECT, gateway
403, checked on 16 August with four unauthenticated GETs. A 404-against-405 probe would settle it with
no credentials and cannot be run here.



---

## E21 🟠 Do `delete_label_display` and `edit_label_display` name a Whoop action?

**Why.** Alex deleted every Whoop schedule on 17 August and neither OneAlarm nor Whoop's own
`CREATE SCHEDULE` button could make one. The six field write body is confirmed; what is missing is the
address and verb for a create, and nothing public documents it.

His schedule row carries `delete_label_display` and `edit_label_display`, which are not in this
project's record and not in the reference work. They are **rendered labels**, so most likely they hold
the words "Delete" and "Edit" and nothing more. But this endpoint is a screen description, and screen
descriptions sometimes carry the action alongside the label.

**Test.** The raw envelope panel already prints one level into each nested object. Read the **values**
of those two keys, not just their names. Zero requests: the panel is already built and the data is
already on his phone.

**Predictions, written before it runs.**

| Value | Means | Then |
|---|---|---|
| `"Delete"` and `"Edit"`, plain strings | labels only, as expected | dead end, close this and look at `schedule_button_component` instead |
| an object carrying a path, method or action name | the screen names its own actions | that is the create and delete contract, taken from the server rather than guessed |
| absent from the panel | the values are nested deeper than one level | print two levels |

**Most likely the first**, and it is still worth one screenshot he is already taking, because the
alternative is inventing a request against a private API and that has cost this project five hours
once already.

**Whose.** Alex, one screenshot of the Whoop raw panel.



## Completed

| | Question | Answer | Date |
|---|---|---|---|
| ✅ | Does the iPhone alarm ring through Silent and Focus, locked? | **Yes** | 16 Aug |
| ✅ | Does Eight Sleep accept and hold a written time? | **Yes**, verified against an absolute instant | 15 Aug |
| ✅ | Does the Whoop write work? | **Yes**, six-key body, confirmed in the Whoop app | 16 Aug |
| ✅ | Is `latest_wake_time` on the write a display string? | **No.** Canonical `"HH:mm:ss"` | 16 Aug |
| ✅ | Do `day_of_week_list`, `enabled`, `time_zone_offset`, `sleep_goal` exist? | **Yes**, on the resource. They are absent from the screen response, which is what caused the confusion | 16 Aug |
