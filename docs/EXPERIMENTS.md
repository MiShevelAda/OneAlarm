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

## Completed

| | Question | Answer | Date |
|---|---|---|---|
| ✅ | Does the iPhone alarm ring through Silent and Focus, locked? | **Yes** | 16 Aug |
| ✅ | Does Eight Sleep accept and hold a written time? | **Yes**, verified against an absolute instant | 15 Aug |
| ✅ | Does the Whoop write work? | **Yes**, six-key body, confirmed in the Whoop app | 16 Aug |
| ✅ | Is `latest_wake_time` on the write a display string? | **No.** Canonical `"HH:mm:ss"` | 16 Aug |
| ✅ | Do `day_of_week_list`, `enabled`, `time_zone_offset`, `sleep_goal` exist? | **Yes**, on the resource. They are absent from the screen response, which is what caused the confusion | 16 Aug |
