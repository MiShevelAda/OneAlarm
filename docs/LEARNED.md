# Learned

Everything this project has found out, why, and what it cost. Newest first inside each section.

Rules for this file:

- **Evidence or nothing.** Every claim carries how it was established: `[observed]` on a real
  account or device, `[documented]` written down by somebody else, `[inferred]` reasoned to.
- **Alex's words are quoted, never paraphrased.** The paraphrase is where the meaning goes.
- **Wrong entries are corrected in place, with the wrong version kept.** A record that hides its
  mistakes teaches nothing, and this project has already re-made one deleted mistake.
- Written the same day. A week later it is reconstruction.

---

## 1. Method: what actually worked

**Three failed handoffs are an instruction problem, not a user problem.** `[18 August]` Alex was asked
for "the weekday alarm's raw block" three times. He sent the weekend alarm once and a switched-off
ghost twice. Each round cost him a trip through two apps, and each time his Eight Sleep app was
plainly showing `UPCOMING ALARM ONLY 09:45` with `07:45` struck through, so the fact was never in
doubt. Only the retrieval was.

That is not him misreading. **Following the instruction required reading sixteen fields across four
blocks and knowing which `repeat.weekDays` combination counts as weekdays.** An instruction whose
first step is "parse this" is a bad instruction however clearly it is worded, and rewording it a
fourth time would have been the fourth failure.

So the panel names the answer at the top instead: `OVERRIDDEN: 07:45, weekdays`. One line, no hunting.

**The rule this project keeps rediscovering in new costumes:** when a step fails repeatedly, do not
improve the step, **remove it**. The build marker exists because "which build are you on" kept being
unanswerable. The `OVERRIDE CHECK` line exists because three dumps could not distinguish "never set"
from "not on this object". This is the same move again, one level up.


**When three dumps in a row answer nothing, stop asking for a fourth and compute the answer.**
`[18 August]` Alex sent three raw Eight Sleep alarm dumps hunting for the field behind
`UPCOMING ALARM ONLY`. All three came back with the same sixteen keys and no override field, which
left two explanations that **reading cannot separate**: he never had one set at that moment, or it is
not on the alarm object.

The answer was already in the data and not in the field names. `time` is the weekly wall clock,
`nextTimestamp` is the absolute instant it next fires. **An override necessarily makes those two
disagree**, whatever field carries it and wherever it lives. His last dump had `07:45:00` against an
instant that is 07:45 in Zurich, so nothing was overriding it.

So the panel computes that comparison now and prints `OVERRIDE CHECK` at the top. The next dump
answers the question either way, which none of the previous three could.

**The transferable form:** "dump the response, do not reason" is this project's oldest rule and it has
a blind spot, which is a response that keeps coming back the same. When that happens the missing thing
is not another dump, it is a **derived** value: something computed from two fields that is impossible
unless the state you are hunting for exists. Three round trips through a person, replaced by four
lines of arithmetic.


**The setup guide works, all five steps.** `[observed, Alex, 18 August]` *"step 1-5 worked"*, meaning: two alarms on the bed, two Whoop schedules with the master switch on, and two matching
routines in OneAlarm. From that state every routine finds its alarm on the first pass and the whole
fan out is green.

**`E11`, the native skip, is NOT confirmed by this.** He was asked which of two tests passed and named
the setup. So the skip through `skipNext` remains built, tested against a fake server, and never run
against his bed. Written here explicitly because the alternative was assuming, and an assumed
confirmation in this file is worse than an open question: the next session cannot tell one from the
other and will build on it.

**Which makes his diagnosis exactly the finding.** The setup working is not a small result, it is the
proof of his sentence: *"if you set it up this way to match the actual settings in the apps, then it
usually works."* The app is reliable from a matched starting state and fragile across a change. That
is the whole remaining problem stated in one observation, by the person using it.


**Alex's diagnosis of the remaining weakness, 18 August, and it is sharper than anything in this
file:** *"if you set it up this way to match the actual settings in the apps, then it usually works
because then it gets the right data. The problem is when something changes, if one alarm would change
the entire thing then it usually doesn't work."*

That is exactly right and it names the shape of every failure on this leg. OneAlarm reconciles by
**exact day set equality**, which is a good rule for a first meeting and a poor one for a lifetime.
It works perfectly when his routines already mirror the alarms on the device, because then every
routine finds its alarm on the first pass. The moment a routine's days change, the alarm it owned
stops matching, and the app has no way back to it except the recorded link, which is dropped precisely
when he edits the thing the link describes.

The failures all have this one cause:

| What he changed | What happened |
|---|---|
| merged Weekdays and Weekend into "Every day" | both real alarms orphaned, still ringing, and a third about to be created |
| a Sa-only Whoop schedule against a Sa-Su routine | routine stranded, no adoption possible, no create possible |
| deleted a routine | its alarm left behind, switched off rather than removed, until provenance shipped |

**The rule underneath, which the outside review reached independently:** content similarity is a fine
way to **propose** a pairing and a bad way to **maintain** one. Mature sync systems use it once, at
adoption, with an explicit confirmation, and never again as identity. OneAlarm has the id mapping and
does the adoption silently, so a change that breaks the day match silently breaks the mapping too.

Nothing here is fixed by better matching. It is fixed by **noticing when a change has orphaned
something and saying so before the write**, which is why the week coverage diff is now the highest
value thing left on this leg.


**Half the one-off problem was fixable from data already on the table.** `[18 August]` The bend needs
a field nobody has seen yet, so it is blocked on a capture. The **skip** did not: `skipNext` and
`skippedUntil` are in every raw dump Alex has sent, sitting unused, while OneAlarm expressed a skip by
switching his weekly alarm off and repairing it later.

Normally this project bans acting on a field whose behaviour is known only from its name, and that ban
is why `E11` sat open since 16 August. What changed is not the confidence, it is **the check**:
`nextTimestamp` is an absolute instant, so "did this morning actually get skipped" is answerable
without trusting the name at all. If the instant moves, it worked. If it does not, the old behaviour
runs and the row says so.

**The general form, which is more useful than the fix:** a rule against guessing is really a rule
against *unfalsifiable* guessing. When a guess can be checked against something the server cannot fake,
it stops being a guess and becomes a test with a fallback. Two things had to be true here and both were
already available: a way to express the intent, and an instant that proves it landed.


**A one-off overwrote the Whoop week too, and the fix there is a refusal rather than a write.**
`[observed, 17 August]` Alex: *"Tomorrow only also overwrite the routine in whoop."*

Same symptom as the bed, different cause and different answer. Eight Sleep **has** a native one-off,
`UPCOMING ALARM ONLY`, and OneAlarm simply is not using it yet, so that one is a fixable bug. **A
Whoop schedule is days plus one time and nothing else.** There is no one-off to reach for. Writing a
bent time necessarily writes it to every day that routine covers.

So the choice is between two harms, and naming both is what makes it a decision instead of a default:

| | Mornings wrong | Direction |
|---|---|---|
| Write the bend | **four**, Tue to Fri | **late**, on a `+15` |
| Skip the bend | **one**, tomorrow | **early** |

One beats four, and early beats late when the job is waking somebody up. The phone and the bed still
carry the one-off, so nothing is lost, and the strap has always been the least authoritative leg here.

**The general rule this settles:** when a device cannot express what the user asked for, the honest
move is to **do less and say so**, not to approximate it across days he did not ask about. An
approximation that touches four mornings to satisfy one is not a partial success, it is three new
failures wearing the same green tick.


**"OneAlarm never touches it" was true and left out the part that decides whether he wakes up.**
`[observed, 17 August 17:14]` He consolidated his week to a single **Every day** routine. His two real
alarms, `09:30 weekdays` and `10:55 Sa Su`, instantly matched no routine, and the bed screen said
OneAlarm never touches them.

Correct, and one Set all alarms away from **three alarms on one morning**: a new Every day alarm plus
both of those, still ringing. Which is precisely the state he cleaned up by hand hours earlier and
asked never to have again.

Not touching an unowned alarm is right and stays. **Saying so without saying it still rings is the
third instance today of the same failure**, after the routine "still 06:01" above a list showing
07:01, and the bed screen giving the wrong reason for the alarms it skipped. The pattern is now
nameable:

> **A screen that is accurate about what the app did, and silent about what the device will do, is
> read as a claim about the device.** He does not care what OneAlarm touched. He cares what wakes him.

Every row that says OneAlarm left something alone now also says whether that something rings.


**The one-off write to Eight Sleep is confirmed broken on his bed, and the display half is confirmed
right.** `[observed, 17 August 17:02 and 17:03]` He bent one Monday to 09:40 against a 09:05 routine.

OneAlarm showed exactly what was asked for:

```
TOMORROW ONLY
09:40  0̶9̶:̶0̶5̶
```

His Eight Sleep app, one minute later:

```
EVERY WEEKDAY   09:30      <- the whole series
EVERY WEEKEND   10:55
```

Alex: *"even though this displays correctly on the OneAlarm app, instead of changing it for one time,
it changes the entire Monday to Friday routine on Eight Sleep."*

**The screen was right and the write was wrong, which is the most dangerous combination this app can
produce** and the reason a green row has never been allowed to count as evidence here. Everything
OneAlarm could check said the bend worked. Only his bed disagreed, and only because he looked.

The cause is `E23`: Eight Sleep has a native `UPCOMING ALARM ONLY` and OneAlarm writes `time` on the
recurring alarm instead. Until that is fixed the screen says so, rather than continuing to promise
"nothing about it changed" above a bed where something did.

**A Swift type checker that gives up tells you nothing, and the shape that does it is worth knowing.**
`[observed]` A multi-line ternary choosing between two heterogeneous `(Int, Any)` tuple literals
produced "Failed to produce diagnostic for expression; please submit a bug report". Not an error about
the code, an error about being unable to describe the code. Splitting it into plain statements fixed
it in one edit. Third distinct member of the family this project has now hit, after the oversized view
body and the extracted generic return type: **when the compiler stops making sense, stop reading the
error and start making the expression smaller.**


**A test suite goes stale in the same way copy does, and it is more dangerous.** `[observed,
17 August]` Alex's first full `Cmd+U` after the day's work returned five failures. One was a real
compile error, actor isolation on a pure function. **The other four were tests asserting rules this
project had deliberately replaced**, each still carrying a confident comment explaining why the old
rule was right:

| Test asserted | Replaced by | When |
|---|---|---|
| the Whoop write mirrors the read's `"12:30 am"` format | canonical `"00:30:00"`, confirmed live | 16 Aug, after five hours |
| the Eight Sleep preview never shows days | days are written to an alarm a routine owns | 16 Aug evening |
| every alarm with matching days is moved | one owner per routine, the twin left alone | 16 Aug evening |
| uncovered days read `"Sat"` | `shortLabel` is two letters, `"Sa"` | earlier |

Three of those four were **not merely out of date, they asserted the exact behaviour that caused a
real incident.** "Every alarm with matching days is moved" is the rule that turned his Monday to
Friday Whoop schedule into every day. A green suite containing it would have defended the bug.

The same rot had already been found twice that day in **user-facing copy**, five stale strings and a
preview gate describing a request the app no longer sends. So the rule generalises past tests:
**when a rule changes, the things that assert it are part of the change.** Not a follow-up, not a
cleanup task. The same commit.


**Eight Sleep has a native one-off and OneAlarm has been faking it.** `[observed, 17 August, Alex's own
screenshot]` Their home screen shows `UPCOMING ALARM ONLY  09:10  0̶9̶:̶3̶0̶`: the next occurrence moved,
the routine struck through beside it, the weekly series untouched.

Alex: *"right now, if I only change the alarm for Monday, Eight Sleep changes the entire Monday to
Friday series and not only the Monday alarm."*

OneAlarm implements a bend by writing `time` on the recurring alarm and putting it back afterwards.
That is not a one-off. It is an edit to his real schedule with a repair scheduled behind it, and every
risk it carries exists only because the wrong mechanism was used. `E23`.

**How it stayed hidden, which is the transferable part.** The raw panel printed values for **fourteen
named keys**, every one of them a field somebody already knew to look for. A field that appears only
while an override is active would have shown its **name** and hidden its **value**. `CLAUDE.md`
already says a diagnostic that only fires on failure answers nothing; this is its twin, and it is now
written down: **a diagnostic that only reports fields you already knew about answers nothing either.**
Print everything.


**Research before guessing, and it changed the answer.** `[17 August]` Alex asked why the Whoop leg
cannot behave like the Eight Sleep one and told me to find out or bring in help. I had already written
a create ladder of three POST paths I reasoned my way to. A search of every public Whoop reverse
engineering project found that **none of those three exists anywhere**, and found something better:
every published capture of the Whoop app records a schedule **update** and no create and no delete,
including one whose author deliberately exercised Smart Alarm CRUD. So the update is probably an
**upsert**, and a PUT to a client minted id went to the top of the ladder, ahead of everything I had
invented. Confirmed address, confirmed body, only the id is new.

Thirty minutes of searching beat an hour of reasoning, again, and the lesson is the same one this
project keeps paying for in a new costume: **absence in a thorough capture is evidence, and it points
somewhere.** "Nobody has ever seen this app POST" is not a dead end, it is a fact that narrows the
search.

⚠️ **And one caution worth more than the finding.** During that search, a summarising fetch of a
source file **fabricated** a clean create endpoint and a matching delete, neither of which is in the
file. It was caught by downloading the raw source and reading it. A confident, well formatted, plausible
endpoint invented by a summariser is exactly the shape of thing this project would have built on. **Read
the raw source, not a summary of it**, whenever the answer is going to become code.


**The Whoop assignment picker works and is the wrong design. Alex, 17 August, after it succeeded:**
*"Now it worked, but this is not how it's supposed to work as the functionality of the app. Right? We
need to find a better solution, because intuitively I think I'm selecting one alarm, and I'm only
changing the Sunday alarm. This is not user friendly, and this is not gonna be understood by the
user."*

He is right, and the tell is that he could describe what he expected to happen and it was not what
happened. The screen shows a **list of alarms** with a radio button and "Use this alarm", which is the
old one-schedule model wearing new words. What the tap actually does is hand a schedule to a
**routine**, and nothing on that screen names the routine, says its days will be rewritten, or
explains why one schedule needed picking when the other did not.

**The rule underneath, which is bigger than this screen:** this app's premise is that routines are the
source of truth and devices follow. **Every screen should read in that direction.** A screen that asks
him to start from the device's list and work backwards to a routine is inverted, whatever its words
say, and it will keep being confusing however the copy is rewritten.

**And the deeper point: he should never be asked at all.** Assignment only exists because Whoop cannot
create a schedule. On Eight Sleep the same situation needs no screen, because a routine with no alarm
gets one made. Fixing the create removes the question rather than wording it better.


**Whoop holds MORE THAN ONE schedule per account. The opposite was written down as structural and it
was wrong.** `[observed, 17 August, on his account]` He made a Monday to Thursday schedule in the
Whoop app, OneAlarm extended it to Friday on the next Set, and then he made a **second** schedule for
Saturday. His account now carries two at once, and `alarm_schedule_list` is a list because it is one.

`docs/STATUS.md` problem 5 and `E12` both say *"Whoop holds one schedule per account, so it cannot
express two routines the way Eight Sleep can"*, and the whole design of that leg follows from it: a
single chosen schedule, `RemoteAlarmSelection` to pick which, and `alarmChoiceNeeded` thrown when
there is more than one. **Every line of that is built on a premise his own account disproves.**

What he saw, and it is the direct consequence: *"I created a new schedule only for Saturday, and then
I clicked again in the one alarm app for the weekend, Saturday and Sunday, but now it did not update
Sunday inside whoop."* OneAlarm writes exactly one Whoop schedule, the one covering the next morning,
so his weekend routine never reaches that leg at all.

**Fourth time on the same reasoning error, and worth naming as such.** Whoop's field names, Eight
Sleep's bed names, Eight Sleep's routine tags, and now Whoop's schedule count. Each was a fact about
one object read as a fact about the service. The rule is already in `CLAUDE.md` twice, once in each
direction, and it still cost this leg its whole design:
**a list that has only ever had one item in it is not a list that can only have one item.**


**Eight Sleep now follows a routine being split and merged, both ways, confirmed on his bed.**
`[observed, 17 August 15:42 and 15:44, in his own Eight Sleep app]` He split Weekend into two
routines and then merged them back, and the bed tracked both:

| In OneAlarm | In the Eight Sleep app, minus the 10 minute lead |
|---|---|
| Weekdays 07:00, Sas 09:00 (Sa), Sus 10:00 (Su) | `EVERY WEEKDAY 06:50`, `EVERY SAT 08:50`, `EVERY SUN 09:50` |
| Weekdays 07:00, Weekend 10:45 | `EVERY WEEKDAY 06:50`, `EVERY WEEKEND 10:35` |

That is the whole loop, not just a time write: a routine that did not exist got an alarm created for
it, two routines collapsing into one left a single alarm behind rather than two, and the lead was
applied correctly on every row. His vibration setting came through on each one.

**Alex's own summary:** *"in Eight Sleep, it got updated correctly. So there, it worked perfectly."*


**OneAlarm must be able to delete, and the no-delete rule is overruled.** `[Alex, 17 August]`
*"the one alarm app should be able to delete alarms if there are changes because right now for
whatever reason I had three alarms in my sleep app and I had to delete all the alarms in the eight
sleep app and set all alarms again from the one alarm app."*

The rule it replaces was written for a good reason and the reason still holds for **his** alarms: a
delete cannot be undone, and an ownership bug that writes the wrong time is a bad morning while one
that deletes the wrong alarm is a lost one. What changed is that refusing to delete did not avoid
that cost, it moved it onto him. He ended up cleaning the account by hand, which is the exact chore
this app exists to remove.

So the ban narrows rather than disappears. **Only an alarm OneAlarm created may be deleted**, tracked
by id at the moment of creation, and only once no live routine claims it. Never one he made, never
one adopted for matching days: adoption means it was already his.


**"A test that mutates a live account is a change" applies to his phone, not only to his accounts.**
`[observed, 17 August]` A new test for override expiry constructed a real `ScheduleStore`. Its `init`
calls `recompute`, which purges an expired override and then **persists** to
`UserDefaults.standard` under `OneAlarm.schedule.v2`. XCTest runs inside the app, so that is the same
store the real app reads. Pressing `Cmd+U` would have replaced Alex's Weekdays 06:05 and Weekend 10:05
with the shipped defaults, 07:00 and 09:00, on his own phone, silently.

Caught before it shipped, by asking what the test writes rather than what it asserts. The rule was
already in this file, learned when a Whoop ring test rewrote his real schedule to every day, and it
was written as being about **accounts**. It is about any shared store, and the phone is one. Tests in
that class now snapshot the key in `setUp` and put it back in `tearDown`, including removing it when
there was nothing there.

**The general form: ask what a test writes, not only what it asserts.** An assertion is the part
somebody reviews. Persistence is the part nobody looks at, and it is where the damage is.


**The Eight Sleep leg works. Settled by Alex, 17 August:** *"Ok eightsleep is save remember the
changes and write them down as working."* Not to be reopened without evidence, and the one line that
must never come back is `clone` copying `tags`. `testACreatedAlarmCarriesNoTags` fails if it does.

**The cause of two weeks of failure was one copied field.**
`[observed, 17 August 14:21, in his own Eight Sleep app]` His app now lists `EVERY WEEKDAY 05:51` and
`EVERY WEEKEND 09:55`. The weekend alarm is the first one OneAlarm has ever created that he can see.

The chain of wrong explanations is worth keeping, because each was reasonable and each was wrong:

1. *"It only moves alarms that exist, and he has no weekend alarm."* True, and fixed by adding a
   create. The create worked. Nothing appeared.
2. *"The create is being refused."* It was not. It returned success every time.
3. *"Their app renders alarms through routines, so an alarm in no routine is invisible."* Built a
   whole routine read and write on this. His account has **no routines at all**.
4. The actual cause: `clone` copied the template's `tags`, which carried `temporary-mode` and
   `oneOff-napMode`. Their app does not list nap timers under Alarms. Every alarm OneAlarm created
   was marked a nap timer at birth, and each new clone inherited the mark from the last.

**One line removed it.** `payload.removeValue(forKey: "tags")`.

Three lessons, and the third is the one that would have saved the fortnight:

- **Never infer presence from an object you did not look at, either.** The rule already ran the other
  way, do not infer absence. The `routine-<uuid>` that theory 3 rested on came from a stranger's
  capture. One read of his own account settled it in ten seconds.
- **"Echo what you do not understand" has a limit, and the limit is fields the server owns.**
  Echoing unknown fields is right for an **update**, where dropping one destroys a setting of his. On
  a **create** it copies bookkeeping that describes the old object, not the new one. `tags` was never
  a setting Alex chose. Vibration, thermal and audio are, and they are still echoed untouched.
- **The layer he sees is the only layer that counts.** The write returned 200, the read-back matched
  the exact instant, and the row was green, for two weeks, while his app showed nothing. Every one of
  those checks was true and the feature did not work. `CLAUDE.md` already says a 200 is not a moved
  alarm; this says the same about a verified read-back.


**Extracting an inline `let` into a function can break the build, because the annotation loses its
inference.** `[observed]` 17 August. `AlarmManager.AlarmConfiguration` is generic over
`Metadata: AlarmMetadata`. As a `let` inside `write`, Swift inferred `Metadata` from the `attributes`
argument. Pulling the same six lines into `configuration(for:)` turned that into a return type, where
there is nothing to infer from, and the build failed with two errors that are really one:
"Reference to generic type ... requires arguments in <..>" and "Generic parameter 'Metadata' could
not be inferred". The body was byte-identical to the version that compiled. Nothing was wrong with
the code that moved; the failure was created by the act of moving it.

Two things follow. **A refactor of working code is a change and needs the same suspicion as new
code.** And `npm run check` cannot see this at all: the file is syntactically perfect, the parse is
clean, and only a compiler finds it. Which is the standing rule restated with a fourth example: a
green check has never meant it builds, and this project has now shipped four different kinds of
error that a parse structurally cannot catch. The first three were an unannotated heterogeneous
dictionary literal, eleven empty collection literals in `Any` position, and a member landing at file
scope. **When a session refactors without a compiler, the diff to read is the one against the
version that last built on Alex's Mac.** That is what found this in two minutes after four rounds of
reading the new code found nothing.

**A checker that has never failed has not been tested.** `[observed]` 17 August. `check_arg_order.js`
was written to catch the argument order error Alex's build had just found, ran clean, and reported
"argument order agrees everywhere". It was reading the wrong node type for an argument label, so it
had silently skipped all but 3 of the 143 call sites, including the broken one. Reintroducing the bug
was the only thing that revealed it: the checker failed its own negative control and did not notice.

The general rule, and this project keeps paying for it: **a green check across zero items is not a
pass.** `CLAUDE.md` already says a glob matching nothing is a failure, learned when the page list
twice pointed at a moved directory. This is the same mistake in a different shape, so the practice is
now: write the checker, **break the code on purpose, watch it fail**, fix the code, watch it pass.
Both directions, every time. It took two minutes and would otherwise have shipped a checker that
enforced nothing while reporting that it did.

**Ask for the error text rather than reasoning about the failure.** `[observed]` "Build fail" with
no text produced one round of guessing, one wrong theory about the Xcode project file, and a hand
audit of initialiser call sites that found nothing. A screenshot of the Issue navigator named the
cause in one line. This is the dump-the-response rule again, on a different surface: the compiler is
a server that sends a response, and reasoning about it instead of reading it fails the same way.

**Dump the response, do not reason about it.** `[observed, twice]` The Whoop write failed six times
across five hours. Every fix derived by reasoning was wrong. Both breakthroughs came from printing
what the server actually sent: the field names on 15 August, and the envelope keys on 16 August,
which revealed the endpoint returns a rendered screen rather than a resource. Nothing else worked at
all. **When stuck, the next action is a dump, not a hypothesis.**

**Status codes are evidence, but only in a controlled comparison.** `[observed]` 400 versus 422 did
turn out to carry information. But the two requests differed in three ways at once and the
conclusion drawn from them was over-stated and written into two doc comments as settled fact. Change
one thing.

**Read modify write, always.** `[observed]` Both remote legs replace rather than merge. Every field
not sent is destroyed. This is why the adapters echo objects they do not understand.

**Verify against an absolute instant, never a status code.** `[observed]` Eight Sleep returns
`nextTimestamp`, so the write can be checked against the moment intended rather than against a 200.
Whoop returns no such thing, which is why its best possible state is `saved` and not `confirmed`.

**A method-aware allowlist.** `[inferred, held up]` `"PUT https://..."` rather than a URL, because a
path allowlisted for GET is otherwise open to DELETE, and on these two APIs that is the difference
between reading an alarm and destroying it.

**Adversarial review finds what self-review does not.** `[observed]` Two outside reviews on 16 August
demolished a conclusion held for six rounds, in one pass. The second one's most useful output was a
single sentence: the response was invariant across wildly variant inputs, so the failure was not
where the work was.

**Test at the layer the user sees.** `[observed]` A written file is not a scheduled alarm. A 200 is
not a moved alarm. A moved alarm on a server is not a buzzing strap. Each of those gaps was real.

**Reading code back finds what writing it did not.** `[observed, five times in one night]` On 16 to 17
August, tracing freshly written code found: a create loop that would have put eight alarms on his
bed while reporting success every time, a test that would have failed for a reason unrelated to the
code, a member that landed one line outside its own type, a refused alarm leaving untrackable alarms
on his phone, and a completely successful run reporting as a warning. None of these was found by
writing more carefully. All five were found by going back over it as a reader. **They are different
activities and the second one is not optional.**

**Grep finds a compile error that reading does not.** `[observed, twice]` An unannotated
heterogeneous dictionary literal, and eleven empty collection literals in an `Any` position. Both are
hard Swift errors, both survived several readings, and both fell out of a one line sweep. When there
is no compiler, the substitute is a pattern search for the specific shapes the compiler would reject,
not more attention.

**A blocked route is not the same as no route.** `[observed]` "There is no Swift toolchain here" was
true and was treated as the end of it for a whole day. `download.swift.org` is refused by the proxy;
`registry.npmjs.org` is in the proxy's own bypass list, and tree-sitter's Swift grammar is on it. A
real parse of every file followed, and it immediately paid for itself. **Ask what else is reachable
before accepting a limit.**

**When a probe is refused, say so and stop guessing.** `[observed]` Four unauthenticated GETs
established that `app-api.8slp.net` is unreachable from a session, which settles two open questions
about API versions as unanswerable here rather than leaving them to be re-attempted. A checked "no"
is worth as much as a "yes" and costs a minute.

**Two structural changes to the leg that must ring, in one night, with no compiler, is the limit.**
`[decided, 17 Aug]` A third was declined and written down instead: in the code, in `STATUS.md`, and
as a test that passes today so the next person knows the behaviour moved deliberately. The rule is
not "never change it", it is that a stated gap beats an unstated one and the count of unverified
changes to that leg is the thing to watch.

**Ask what the object is, not just what is in it.** `[16 Aug]` Three separate conclusions were
drawn from missing fields: Whoop's names did not exist, Eight Sleep did not name beds, alarms could
not be attributed to a Pod. All three were wrong, and all three were the same error: **absence in
one object is not absence anywhere.** The fix each time was to find the object that does carry the
fact, and twice it existed in an endpoint nobody had called. The third time the honest answer was
better still: the field was missing because the **relationship does not exist**, and the question
had to be rephrased rather than answered.

**"Now it sets the eight sleep alarm always to heavy", and then the fix for it was inert.** `[20
August]` Two failures in one hour on the same feature, and the second is the more instructive.

**First:** `Comfort.apply` took `[String: Any?]` and skipped nils with `guard let value`, which does
not skip. Putting an `Int?` into an `Any?` dictionary double wraps it, so the unwrap peels the outer
layer and succeeds. Every field he had left on `Leave` was written back as a boxed nil on every
sync, which is exactly what the three-way `Leave` design exists to prevent, reintroduced one layer
below the UI that prevents it. Now three concrete dictionaries, and the gate bans `Any?` collections.

**Second, found by a neutral review he asked for rather than by me:** `RoutinePlan.Entry.withoutBend()`
rebuilds the entry field by field and never listed `comfort`, so it silently defaulted back to
`.unchanged`. The adapter runs **every** planned entry through that, not only the bent ones. He could
set the options, watch them persist across launches, press Set all alarms, get a green receipt, and
the payload was byte identical to before. **The whole feature was inert and would have read as Eight
Sleep ignoring him.**

**The rule from the second one.** A memberwise rebuild is a hand maintained list, and this is the
second time one has quietly dropped a new field. Adding a stored property to a type means grepping
for every place that reconstructs it, in the same commit. Nothing in the compiler or the gates catches
it, because a defaulted parameter is exactly what makes it compile.

**And the rule from both together.** The first bug was mine and the second was mine, and the one that
would have wasted his week was found by asking for a review rather than by re-reading my own work.
When a change touches a field that flows through several types, the value of an outside pass is
higher than the value of another careful look.

**He reversed his own rule on temperature and vibration, and the reason behind it still shapes the
fix.** `[20 August]` On 16 August: *"only the modifications of temperature, vibration etc should be
done in the respective app."* On 20 August, with a screenshot of the Eight Sleep alarm screen: *"for
eight sleep please add following options when editing the routine."*

The old rule is kept in view rather than deleted, because **the danger it guarded against has not
gone away**. The reference documentation contradicts itself about these exact field names thirty
lines apart: `vibration.powerLevel` against `vibration.level`, `thermal.level` against
`thermal.temperature`. A guess there does not fail loudly, it warms his bed to the wrong temperature
or writes a setting his account ignores.

**So nothing is composed.** Every value is written into a key the server itself just sent, and a key
it did not send is never introduced. Whichever spelling his account uses is the one that gets
written, because it is the one that came back, and neither doc has to be right. Same principle that
makes `clone` safe for creating alarms.

**And every control is three-way, not two.** `Leave` is the default and means the field is not
touched. A plain on/off toggle has no way to express "as it is", so merely opening the routine screen
would start overwriting settings he made in Eight Sleep's app. That is exactly what the ban existed
to prevent, and a two state control would have reintroduced it through the UI rather than the wire.

**The rule.** When a rule is overruled, keep the reason. It usually still constrains **how** the new
thing is built, even when it no longer decides **whether**.

**OneAlarm's iPhone alarm is not the Clock app's alarm, and nothing can close that gap.** `[20
August]` He was woken an hour early and reported: *"Apple alarm doesn't change but an alarm rang this
morning according to set time, but the other apple alarm rang before and was not changed."* Both
halves true, neither a bug. OneAlarm's alarm fired at 09:30 exactly as set. His Clock app's
**Sleep | Wake Up** at 08:30 fired too.

AlarmKit hands an app its **own** alarms and nothing else. There is no API to read, edit or cancel an
alarm made in the Clock app, and the Sleep schedule is further away again, owned by Health. This is a
property of the platform, not a gap to close.

**So saying it is the only fix available, and it had never been said.** The failure mode is being
woken early by an alarm this app did not set and cannot see, which is the same class as the Whoop
strap buzzing early, and it cost him a morning before anything on screen mentioned it.

**The rule.** When a platform limit means the app cannot control something the user will reasonably
assume it controls, that assumption is the bug. Name it on the screen where they would form it, once,
dismissibly. Silence about a limit reads as absence of the limit.

**A diagnostic you can only reach while broken is a diagnostic nobody reaches.** `[20 August]` The
Whoop account level check shipped on the `blocked` screen, which appears when a write is refused.
That felt right: it answers the question the block raises. Alex went looking for it on the Whoop
screen he actually opens, the schedule list, and reported *"I don't see the why is it off button."*

Two things wrong with the placement. The picker is where somebody goes to ask what state a service is
in, whether or not anything has failed. And being blocked is precisely when you may not be able to
reach a screen that needs a successful read in the first place.

**The rule.** Put a diagnostic where the question gets asked, not where the failure gets reported.
Those are different screens, and the second one is often unreachable exactly when you need it.

**A feature request thread is not evidence the feature is missing.** `[20 August]` A research sweep
found WHOOP Community threads asking for "change alarm for tomorrow only", filed under Product
Feedback, and inferred the feature does not exist. That inference then cast doubt on a correct older
note in this project saying Whoop's one-off is mutually exclusive with the recurring schedule *"per
its own dialog"*.

Alex opened his app and the dialog was right there: **"Your schedule is currently on. Turn off your
schedule to set a new alarm for tomorrow."** The feature exists, it is exactly as the old note
described, and the doubt was manufactured from an absence of the wrong kind.

**The rule.** People ask for features that already exist, in the wrong words, on the wrong screen, or
for a variant of what shipped. A request thread tells you what somebody wanted, never what the
product does. This is the same error as **never infer absence from an object you did not look at**,
which this project already had written down, applied to a forum instead of a JSON body.

**And the thing that actually answered it was one person opening the app.** Two research sweeps and
several hours of reading other people's code were beaten by the owner tapping the button.

**A feature that can switch something off, on a leg that cannot switch it back on, is a one way
door.** `[20 August]` The Whoop silencing lived about four hours. It solved a real problem, a strap
buzzing two hours before a moved morning, and it was removed the moment `E30` showed OneAlarm cannot
turn a schedule back on. The trade it was actually making was one early buzz against a strap that
stays dead until he notices by hand.

**What made it look safe was a misread of the evidence.** The captured working PUT changed a **time**
on a schedule that was **already on**. That was taken as "the body works", when it only proved the
part that was exercised. Writing `enabled: false` was inside the same six keys, so it felt covered.
It was not.

**The rule.** Before shipping anything that puts a device into a state, prove the way **out** of that
state first, on the real account. Reversibility is not a property of the request, it is a property
you have observed.

**Direction decides whether silencing the strap is right, not the fact of a one time change.**
`[19 August]` He nudged a morning half an hour **earlier** and OneAlarm switched his Whoop schedule
off. His words: *"Changing the alarm plus fifteen minutes or setting it to just for the next morning
actually switches off the whoop."*

The silencing had been built an hour earlier from one real case: routine 07:55, moved to 09:41. There
the strap left alone buzzes two hours before he asked to wake, and losing the buzz is the better
trade. **The rule was then applied to every bend**, including the opposite one. Routine 08:55 moved to
08:25 leaves the strap firing at 08:50, which is after he is already up: harmless, and switching it
off cost him the wrist buzz for nothing.

Now it silences only when the bend is **later** than the routine by more than fifteen minutes. The
grace exists because the strap already sits five minutes ahead of the phone by design, so a small
nudge is inside the noise of a wrist alarm, and losing the buzz entirely is the worse outcome.

**The rule underneath, and it is the general one.** A trade-off measured on one real case is a
trade-off measured at one point. Before applying it everywhere, run the **opposite** case through it
and check the answer still holds. Here the opposite case inverted which side was harmful, and nothing
in the code or the comment noticed.

**A second thing this exposed.** Letting a small bend fall through to the ordinary write meant the
ordinary write now had to be safe with a bent entry, and it was not: it built its payload from
`Pair.time`, which is `bentTo ?? localTime`. That would have moved his whole week, the founding bug of
this leg, reached by a third route. **When you widen which inputs reach a path, re-check that path's
assumptions about them.**

**A two branch answer to a three case question, and it told him his days were gone.** `[19 August]`
His Whoop card read *"Switched off, and no days set"* directly above a dump listing
`scheduled_days = (MONDAY, TUESDAY, WEDNESDAY, THURSDAY, FRIDAY)`. The schedule was switched off and
its days were completely intact.

The line was a ternary on `isEnabled`, and `canFire` is `isEnabled && !weekdays.isEmpty`, false for
**either** reason alone. So whenever the switch was off the message asserted the days were missing
too, having never checked. Three cases, two branches.

**Why it mattered more than a wording slip:** he had just been asked to check whether the days on that
schedule survived a bad write. The app answered the exact question he was investigating, and answered
it wrong, with the same confidence as the half it got right.

**The rule.** When a boolean is an `&&` of two conditions, the message explaining why it is false has
to test them separately. A wrong reason is worse than no reason, because a reason is where somebody
goes to rule a cause out.

**The fix for a bug reintroduced the bug, one hour later, through the code that was preventing it.**
`[19 August]` The Whoop leg was switched from "leave the strap alone on a moved morning" to "switch
the strap off for that morning". An hour later his schedule read `MON TUE WED THU FRI 09:36 ALARM
OFF`. The switch off worked and **the one-off time went with it**, moving his whole weekday schedule
from 07:50 to 09:36. That is precisely what the refusal exists to prevent.

One line. The silencing call was built from `AlarmMatchReport.Pair.time`, which is
`bentTo ?? localTime`. That is correct for every ordinary write and wrong for the single place in the
codebase that deliberately does **not** want the bend.

**The rule.** When adding the one path that must not apply the override, check every value it inherits
for whether the override is already baked into it. A field named `time` on a pair that a bent routine
produced is not the routine's time, and nothing at the call site says so.

**And a second defect the same screenshot exposed.** His row read *"Accepted, but it reads back as
Mon 09:36 instead of Mon 09:36"*, the same time twice. The comparison had correctly moved to the
routine time while the message still rendered the bent target, so the two halves came from different
questions. **A mismatch that prints one time twice is worse than no mismatch**: it reads as a display
bug, so the real disagreement underneath gets dismissed.

**Refusing to act is an action, and on the Whoop leg it was waking him two hours early.**
`[19 August]` He bent Monday to 09:41. The bed took the one-shot, the phone split correctly, and the
Whoop adapter **deliberately** left the strap alone, reporting *"your phone and your bed have it"*.
His schedule was MON to FRI 07:50, enabled. So the strap would have buzzed at 07:50 on the one
morning he had asked to sleep until 09:41.

The refusal itself was right and stays: one Whoop schedule carries one time for **all** its days, so
writing 09:36 would have moved Tuesday to Friday with it. What was wrong was treating "we cannot
write the new time" as the end of the sentence. The schedule is now switched **off** for that
morning instead, through its own `enabled` field inside the confirmed six key body.

He found it in one glance at a screen that said everything had worked. His words: *"Important test 2,
whoop didn't change."*

**The rule.** When a leg refuses an instruction, ask what that leg then **does** on the morning in
question, not just what it failed to do. A refusal that leaves a device doing the old thing is only
safe when the old thing is harmless, and an alarm is never harmless: it either rings or it does not,
and both are answers.

**And the trade is stated rather than hidden.** If OneAlarm never runs again he loses the wrist buzz
and keeps the bed and the phone. The other failure, a strap going off two hours early, is the one
that actually costs him the morning. Recovery needs nobody to remember anything: every ordinary
write hardcodes `enabled: true`, so the next sync with no override restores it.

**A "broken" row that had been fixed for two days, and nobody re-checked it.** `[18 August]` Both
`LEARNED.md` and `STATUS.md` recorded that merging two routines *"orphans both alarms and leaves them
ringing"*, and that narrowing a routine's days *"strands the alarm that had served it for weeks"*.
That went into the handover document for external experts as a **BROKEN** row.

Tested rather than assumed, and it is stale. Once a routine owns an alarm through `RemoteAlarmLink`,
the link is consulted before the day sets are, so:

- merging keeps the survivor's alarm and rewrites its days to the merged set
- narrowing keeps the alarm and reshapes it
- the merged-away routine's alarm is an orphan, which provenance resolves: deleted if OneAlarm made
  it, switched off if he did

The notes described the world before ownership was recorded, and were never revisited after the fix.

**What is genuinely still open is narrower and worth stating precisely:** the gap is the **first**
adoption, not the lifetime. A routine with no link finds its alarm only by exact day set equality, so
a routine created after its alarm has drifted never adopts it, and an alarm nobody has adopted stays
unowned forever. That is Alex's own diagnosis, *"it works if you set it up to match"*, stated exactly.

**Two rules from this.** A defect note is a claim with a date on it, and it decays: re-test before
quoting it, especially into a document going to someone outside. And **a fix that closes a defect
must go back and edit every note that describes it**, or the project keeps paying for a bug it has
already fixed.

**Cutting a check before shipping it, because something else already said it.** `[18 August]` The
week check was written with two findings: a morning with no alarm on it, and an alarm ringing that
nothing asked for. The second was deleted before it ever ran, because the stranded-alarm line on the
same row already reports it, by alarm rather than by day, and names what to do about it. Two
sentences about one alarm in two vocabularies is how a row stops being read.

The kept half is the one nothing else covered: **a morning a routine covers with nothing on the bed
to ring on it**. That is the only failure on this leg whose next symptom is him not waking up. The
loud direction always had a witness. The silent one had none.

**The rule:** a new check earns its place by covering a case nothing else does, not by being correct.
Correct and redundant still costs attention, and attention on that row is what the dangerous finding
needs.

**"Known, written down, and deliberate" is not the same as "acceptable".** `[18 August]` The phone
leg collapsed to a single alarm whenever any routine had an override anywhere ahead, so bending next
Saturday from a Monday left Monday to Friday with no phone alarm at all. It carried a long comment
saying so, and a test pinning it, and both said the same thing: this is what the leg did before 17
August, so it is a narrowing rather than a regression. That was true.

It was also a silent missed morning on **the leg that exists because it needs no account, no network
and no server**, and it survived an extra day because it was documented. A comment explaining a
defect reads, to the next person, as a decision that has already been weighed.

The comment even named the missing piece: the plan had to carry which morning the override lands on.
That piece arrived the next day for an unrelated reason, the Eight Sleep one-off, and closing this
was then twenty lines.

**The rule:** when you write down a defect instead of fixing it, write down **what would unblock it**
in the same breath, and check that list whenever anything new lands. Otherwise the note becomes the
resting place rather than the queue.

**Trace the value to the pixel, not to the return statement.** `[18 August]` Four rounds of work went
into a `ONE TIME CHECK` line that could not be displayed. The Eight Sleep adapter computed it and put
it in the receipt correctly, and `ScheduleStore` discards `receipt.note` whenever the write is not
partial. A one time change that worked **perfectly** therefore printed "Set for 06:05" and nothing
else. Alex had been asked to read that exact line back and send it, and would have reported that
nothing happened, which would have read as the feature failing.

Nothing in the adapter or its tests could see this. The field was populated, the tests asserted it was
populated, and the value died one file away in a branch nobody had reason to open.

**This is the project's oldest rule wearing a new costume:** a file written on a server is not a post
published on LinkedIn; a receipt field populated is not a sentence on a screen. The fix is a
`highlights` list that survives a success, and the general form is: **when you add something a person
is meant to read, follow it all the way to the screen before writing the instruction that asks them
to read it.**

**Then the same trace, run deliberately, found two more in one pass.** `[18 August]` Having been
caught once, the whole one-off feature was walked from value to pixel rather than to return
statement. Two more:

- **The preview gate had started lying.** It read `timeToWrite`, which returns the bent time, while
  the write had stopped sending that to the routine's alarm hours earlier. So the safety screen said
  "Weekdays to 08:05" for a request carrying 06:05, and said "one PUT per routine" for a write about
  to POST a new alarm and PUT a skip. Two requests to a live account that the gate did not mention.
  Alex found the last version of this himself, and the rule it produced is already in this file: **a
  gate that lies is worse than no gate, because it is where you go to rule the thing out.**
- **The build stamp was not where the question is asked.** It was added to answer "is the code you
  are running the code I pushed", and it lived three taps into Connections while that question gets
  asked on the home screen before anything happens. An instruction had just told him to check "the
  footer", where it was not.

**The transferable part is the sweep, not the three bugs.** One found defect of a kind is evidence of
a **class**, and the cheapest moment to find the rest is immediately, while the shape is in your head.
Fixing the one you tripped over and moving on is how the other two ship.

**A fourth, from auditing rather than from a symptom.** `[18 August]` The override's own alarm is
owned through a key that is not a routine id, so the stranded-alarm check did not recognise it and
reported it every sync as "an alarm matching no routine that OneAlarm did not touch. It still rings.
Give a routine those days, or delete it in the Eight Sleep app." A warning telling him to delete the
alarm the feature had just made for him, on the row where the feature reports success.

Found by reading, not by a failure, and it would have been read as the one-off not working. **A new
kind of ownership needs every existing owner check taught about it**, and the way to find those is to
grep for the old one rather than to think about where it might matter.

**Also found by the same read:** a test whose stubbed request sequence was one short. That does not
fail loudly, it falls through to the default answers, the last request 404s, and the assertion that
would have caught something quietly never runs. The test goes on passing while testing less than it
says. **Count the requests against the code, never against the intention.**

**Sweeping the old suite is a technique, not a one off.** `[18 August]` After a three day old test
caught the day's worst bug, every pre-existing test that stubs a fixed sequence of reads was walked
against the new code, eight of them, plus every assertion about `isPartial`. No further defect, which
is worth recording: **a check that ran and found nothing is a result**, and without writing it down
the next session runs the same sweep again.

It did surface one design gap rather than a bug. Several of those tests now let the final read back
fall through to a 404, and when that read fails **both new checks simply do not run**. Their silence
is indistinguishable from "nothing to report", so on a build where `ONE TIME CHECK` is the line Alex
was told to look for, its absence would read as the feature not running. Named now, and only when
there was something to check: a diagnostic that speaks when there is nothing to say is one he stops
reading. This is `preflight`'s own rule, applied inside the app: **a skipped check is not a passed
check, and it gets named.**

**A three day old test caught the worst bug of the day, and it was testing something else.**
`[18 August]` The new week check read an alarm with every day flag false as covering no mornings. An
alarm created inside a routine through `alarmsToCreate` takes its days from the **routine**, so that
is exactly what one looks like. The first alarm OneAlarm ever creates that way would therefore have
produced "Nothing on your bed rings on Sa. You will not be woken" for every morning that routine
covers, on a bed that was working. And that sentence is a highlight, so it reaches the Good night
screen: the loudest false alarm this app is capable of, on the last screen he sees before sleeping.

Nothing in the new tests could find it, because they were all written by the same person who had the
same wrong idea about what an empty day set means. What found it was
`testAFullySuccessfulRunIsNotFlaggedAsPartial`, written three days earlier for an unrelated reason,
whose fixture happens to model exactly that alarm.

**Two things worth keeping.** First: **run the old tests against the new idea before trusting the new
tests.** New tests share the author's blind spot; old ones were written under different assumptions
and are the closest thing to an outside opinion available offline. Second, the fix is the project's
oldest rule again: **not knowing which mornings an alarm covers is not the same as knowing it covers
none.** Where absence is ambiguous, say nothing.

**Five delivery defects, zero logic defects.** `[18 August]` The one day override was written, tested
and correct, and then five separate things stopped it reaching Alex:

| Where it died | What he would have seen |
|---|---|
| `ScheduleStore` discards `note` on a clean write | "Set for 06:05" and nothing about the one time change |
| the preview gate read `timeToWrite` | a safety screen showing a time the write does not send |
| the build stamp lived three taps into Connections | no way to tell which build he was running |
| the stranded check did not know the new ownership | "delete it in the Eight Sleep app", about the alarm the feature just made |
| `verify` read back the routine's alarm, which had just been skipped | "Accepted, but it reads back as Wed 06:05 instead of Tue 08:05" |
| the Good night sheet covers the row every time | "All confirmed. Nothing left to do. Put the phone down" |

Not one was in the reasoning about alarms. **The writing was right and the path from it to a person
was where everything broke.** That is worth more than any of the six fixes: on this project the risk
has not been getting the logic wrong, it has been assuming a correct value is a delivered one. The
work is not done at the return statement, and it is not done at the receipt either. It is done at the
pixel he is looking at when he stops.

## 2. Method: what did not work

**Trusting a single source for a payload shape.** `[observed, three times]` The Whoop field names,
the Whoop read shape, and on 16 August the Eight Sleep routine payload, where `dayOffset` was read as
the number `0` off one capture and is a string enum, `"Zero"`, in both implementations that spell it.
Each time the cost was hours and the fix was ten minutes of looking for a second source. **Two
sources, or it is not a capture.**

**Trusting a write-up that claimed to be a capture.** `[observed, twice]` The reference project
described its PUT body as a captured request. Its field names were right and its read shape was
wrong, and both were believed at the wrong times. Cost: five hours.

**Inferring absence from the wrong object.** `[observed, twice]` Whoop's field names were declared
fiction because a GET did not contain them, when that GET returns a screen. Eight Sleep was declared
not to name its beds because the parser did not read a name, when nobody had looked at the object.
**Same mistake, two services, three weeks apart in the code and one day apart in reality.**

**Changing several things at once.** `[observed]` Four changes in one commit, then a conclusion drawn
from the result. When the next round also failed, the conclusion "it is not the body" was drawn from
two attempts that were the same shape twice.

**A safety screen that overstated itself.** `[observed]` The preview gate said "this is built by the
same code that builds the real request". It was a reconstruction, and it omitted `alarm_mode`, the
field most likely to be causing the refusal. Alex found this by opening the screen. A gate that lies
is worse than no gate, because it is where you go to rule the thing out.

**A retry that silently changed a setting he chose.** `[observed]` The Whoop write fell back to
`alarm_mode: IN_THE_GREEN` to get past a suspected enum error. That would overwrite the mode he set
by hand ten minutes earlier. It shipped, and had to be disclosed after the fact.

**Diagnosing from the wrong layer.** `[observed]` CI running zero jobs was diagnosed as a GitHub
billing problem, and Alex was walked through checking his spending limits and making the repository
public. The cause was invalid workflow YAML. **Validate the artefact before theorising about the
account.**

**Fixing a symptom instead of removing the dependency.** `[observed]` The Whoop MFA challenge was
lost between issuing and confirming. The first fix persisted it to the Keychain, and did not work.
The fix that worked was to stop the confirm step depending on the adapter having kept it.

**Testing with settings that are not test settings.** `[observed]` Turning on all seven days to test
the ring rewrote Alex's real Whoop schedule from Monday-to-Friday into every day. Silently, because
the write replaces. **A test that mutates a live account is not a test, it is a change.**

**A green test asserting the broken behaviour.** `[observed]` The Eight Sleep one-off had a test
called `testABendWritesTheOneOffTimeToTheBed`, and it passed, and what it asserted was the bug: that
the override's time lands on the routine's **own** alarm. An Eight Sleep alarm has one wall clock for
its whole day set, so that moves every morning the routine covers. Alex found it on his bed:
*"instead of changing it for one time, it changes the entire Monday to Friday routine on Eight
Sleep."* The test was written from what the code did rather than from what the feature is, and it is
worse than no test, because it is the reason nobody looked there. **Write the assertion from the
behaviour he asked for, before looking at the implementation.**

**Waiting on a capture when the fix needed no capture.** `[observed]` Three raw dumps of the alarm
object went out hunting for the field behind `UPCOMING ALARM ONLY`, and all three came back
identical. Meanwhile the override could be built out of two things already confirmed working on his
account: creating an alarm by cloning, and deleting one OneAlarm created. Four days of a broken
one-off were spent looking for a nicer answer to a question that did not have to be answered. **Ask
what can be built from what is already confirmed, before asking what still needs discovering.**

## 3. Product decisions, in Alex's words

> *"It's not feasible to go every time into the settings app before the weekend and select when I
> want to set up the time. It needs to be a better way, one setting on the main screen so it knows
> today it's Friday or Saturday."*

The main screen is an **editor** and should be a **statement**. It made him author a schedule on
every use, and left invisible state behind. `[2026-08-16]`

> *"They had a wake up alarm for nine AM, but then they went out on Friday, and they want to wake up
> on Saturday instead of nine AM. They want to sleep in until ten, but Sunday shouldn't be touched."*

**An override is keyed to a date, never to a weekday.** Keyed by weekday, changing Saturday changes
every Saturday, which is the routine and not a deviation from it. `[2026-08-16]`

> *"Maybe to don't use the routine today, or maybe they want to change the routine."*

**Three verbs, never confused:** change the routine, bend one date, skip one date. Skip is its own
verb and not an override to zero, because the alternative is switching the routine off and
forgetting. `[2026-08-16]`

> *"It would be great that one alarm would be the sole author, but we need to also remember that
> people will be using other apps."*

**Sole authorship is the aim, not the assumption.** Behave as the author until the evidence says
otherwise, and check, because checking is free: both legs already read before every write.
`[2026-08-16]`

> *"There are also some people who don't set alarms at all or set it from one day to another. They
> don't care if it's a Monday, Friday, Tuesday."*

**Three populations, not one.** Routine led, day by day, and no alarm at all. Day by day users are
not degraded routine users, and "no alarm" is a chosen setting rather than an empty state.
`[2026-08-16]`

> *"OneAlarm is my one single source of truth for alarm setting, and the main alarm setting should
> be done there. Only the modifications of temperature, vibration etc should be done in the
> respective app. So whenever I change something on the routine or one time off, it should be done
> in the OneAlarm app and should be written into the other apps."*

**The split is when against how.** OneAlarm owns the time, the days and whether an alarm is on.
Eight Sleep owns temperature, vibration, level and pattern. Every field on the alarm object falls on
one side of that line, and the adapter writes three of them and echoes the rest. `[2026-08-16]`

**Ownership has to be recorded, not inferred.** Matching a routine to an alarm by their days works
only while the days agree, and the whole point is that he changes days in OneAlarm. Change Monday to
Friday into Monday to Wednesday and the match evaporates, the bed keeps the old days forever, and
the app creates a second alarm beside the one it just lost. `RemoteAlarmLink` records the owner, so
the alarm is found by identity and its days follow the routine. `[2026-08-16]`

**A ban can be right for its reason and wrong as a rule.** Writing days was banned at 09:00 and
restored at 13:00 the same day. The ban was never about days being sacred: it was about writing them
to an alarm nobody had established was ours, where one hand-picked alarm served two routines and
every turn of the week reshaped it. Once ownership is recorded the ambiguity is gone and the same
write is safe. **Record why a rule exists, or the next session cannot tell when it has stopped
applying.** `[2026-08-16]`

**Being the source of truth has a cost, and it gets stated.** Switch a OneAlarm-owned alarm off in
the Eight Sleep app and the next sync switches it back on. That is what single source of truth
means. The routine's own switch is where to turn it off. `[2026-08-16]`

> *"I shouldn't actually pick routines. The routine should be updated accordingly. So if I'm
> updating a routine Monday to Friday, they should override the Eight Sleep routine Monday to
> Friday. And if I update the routine Friday, Saturday, it should update the Friday, Saturday
> routine automatically. This should be happening in the background. So the one app should override
> the routines I have in Eight Sleep, for instance, because picking one routine can break the entire
> thing. So what I should be able to pick is just the bed, and I should not pick a routine. This
> doesn't make sense to me."*

**Days are a key to match on, never a field to write.** He is right, and it also names damage that
had already happened. With one alarm chosen by hand, the app had no way to express two routines, so
each time the week turned over it rewrote the chosen alarm's **days**. That is how a real Monday to
Friday Whoop schedule became `EVERY DAY`. Matching by day set deletes the destructive operation
rather than guarding it: a routine drives the alarm that already has its days, and only the `time`
field is ever sent. What he picks is the **bed**, because that is the only thing on the account
genuinely ambiguous. `[2026-08-16]`

**A partial write is not a done write.** A leg holding one alarm per routine can half-succeed: two
routines match and a third has no alarm with its days. A green tick over that is a week with a hole
in it, and the hole is a morning nobody is woken on. `[2026-08-16]`

> *"The function is not very user friendly. We need to find a better way how to set up routines. We
> need to make it easier and make it more clear what is a routine and what is not a routine."*

**Confusion about scope is fixed by place, not by wording.** The home screen carried three controls
that all looked like "set the time": a wheel that bent tomorrow, a picker inside each routine card
that changed the routine, and steppers on each device row that moved a lead. Three identical
affordances, three different lifetimes, one scrolling column. No label survives that. The fix was to
split them by screen: home is **one morning**, `RoutinesView` is **the week**. `[2026-08-16]`

**Seeing and editing are different asks, and he made both.** He asked for routines to be *"directly
on my home screen"* and then said routines on the home screen were confusing. Both are right. The
home screen shows every routine read only, one line each, and one tap goes to the only place they
can be changed. `[2026-08-16]`

> *"Identify the eight sleep pod by name not only alarm times, group them by name in the setting."*

**Name the device, group by it.** Two alarms at the same time on two pods are indistinguishable, and
picking wrong moves the wrong bed with no symptom until somebody does not wake up. `[2026-08-16]`

> *"If I change the dominant, let's say the iPhone... to eight ten, then the entire routine needs to
> be changed."*

**He does not think in master times.** He thinks in terms of the alarm that wakes him, with the
others arranged around it. The model already agrees; the screen does not, because the header is
editable and the rows are not. `[2026-08-16]`

## 4. What he liked

- **The design.** *"Amazing I like the design."* The Whoop and Eight Sleep fusion, after two
  rejected attempts. What fixed it was working from his real screenshots rather than from a
  description of the two apps. `[2026-08-15]`
- **Being told who does what.** Every instruction says whether it is his job or the session's.
- **Plain steps.** *"Explain it to me like I'm eight years old, because I'm not a coder."*
- **Being shown the failure states, not just the happy path.** The clickable prototype leads with
  them.

## 5. What he disliked, and corrections he made

- **An AI agent described as an expert.** *"An ai agent."* Said flatly, after being told a team of
  "external experts" had been brought in. The word expert was doing work it had not earned. Say what
  a thing is. `[2026-08-16]`
- **Design that was not close enough to the source.** Two attempts rejected before he supplied real
  screenshots. `[2026-08-15]`
- **Being made to re-enter things.** Every rebuild loop that lost his signing team, every re-link.

## 6. Working style, stated

> *"Be autonomous. Be resourceful and be determined and take the decisions needed. We can always
> iterate afterwards."*

> *"When in doubt, start taking decisions and revert back to the orchestrator as he can take the
> decision on his own. Don't rely on my feedback."*

> *"I need a 100% proof, also have a team playing devil's advocate along every stage and let them be
> critical. They need to challenge the proposals."*

Writing: direct and simple, no filler, no inflated significance language. No em-dashes anywhere.

## 7. Facts about the three services

See `docs/RESEARCH.md` for the full record. The short version, with evidence markers:

| Fact | Evidence |
|---|---|
| Whoop write takes six keys: `sleep_goal`, `day_of_week_list`, `time_zone_offset`, `enabled`, `latest_wake_time`, `alarm_mode` | `[observed]` 16 Aug, live account |
| Whoop's `GET /schedule/all` returns a rendered screen, not the resource | `[observed]` its keys include `delete_error_modal`, `schedule_button_component` |
| Whoop's one-off and its recurring schedule are mutually exclusive | `[observed]` its own dialog says so |
| Whoop smart window is 60 minutes | `[observed]` from a UI string, not a capture |
| Eight Sleep smart window is 30 minutes | `[observed]` from a UI string, not a capture |
| Eight Sleep write replaces rather than merges | `[observed]` |
| AlarmKit offers only `.never` and `.weekly`, no start date | `[documented]` and relied on |
| AlarmKit alarms belong to the app; iOS Clock and Health sleep alarms are unreachable | `[observed]` two alarms ring on one phone |
| The iPhone alarm rings through Silent and Focus, locked | `[observed]` 16 Aug, 01:00 |
| Eight Sleep alarms are **user scoped**, not bed scoped. One list per account, firing on the Pod the account is currently assigned to | `[observed]` + `[code]`, 16 Aug |
| The Pod's name and the user's side come from `client-api/v1/users/me` and `app-api/v1/household/users/{id}/summary` | `[observed]` 16 Aug: returned "Züri, left side" on a live account |
| `/v1/devices/{id}` carries a model, a serial and a firmware version, and **no name** | `[observed]` in two public captures |
| An alarm's `tags` holds a `routine-<uuid>`, linking it to a bedtime pairing, **not to a Pod** | `[observed]` 16 Aug |
| Eight Sleep's smart alarm has **no window length field anywhere in the API** | `[observed]`. The 30 minutes came from a sentence in their UI |
| Eight Sleep holds one alarm **per day set**, so a week with two routines is two alarms | `[observed]` 16 Aug, live account |
| Eight Sleep's alarm API is **version asymmetric**: the list is `/v2/users/{id}/alarms`, the update is `/v1/users/{id}/alarms/{alarmId}` | `[observed]` both confirmed against the account |
| The create is `POST /v1/users/{id}/alarms` | `[documented]` two independent public sources, 16 Aug. An earlier line here called this unknown, and a prediction that it was `v2` was wrong |
| Eight Sleep's app models alarms **inside routines**: `PUT /v2/users/{id}/routines/{id}` carries `days`, `bedtime`, `alarms` and `alarmsToCreate` | `[documented]` public capture, 16 Aug. This is what every alarm's `routine-<uuid>` tag points at |
| An alarm created standalone belongs to no routine, and their app appears not to list it | `[inferred]`, and it fits the observation that the API returned a Mon-Fri alarm his app did not show |
| Whoop holds **one** schedule per account, so its days genuinely cannot express two routines | `[observed]` its own UI, and the mutually exclusive one-off dialog |

## 2026-08-18: the app compiles, and had been able to all along

`CI has never once compiled this app` (`90949e0`). Two weeks of every document in this repo saying
"built, never compiled" and treating that as an unavoidable property of writing Swift on Linux. It
was not. The macOS job existed, ran on every push, and died before the compiler every single time.

**The rule this is an instance of, and it already existed: a red check nobody reads is worse than no
check.** The workflow had been failing since the repo's first push. Nobody looked, because the
failure was assumed to be the known one, that macOS minutes cost money on a private repo. The actual
cause was `sudo xcodebuild -downloadPlatform iOS` returning `Unable to connect to simulator`,
exit 70, in a job whose own header comment said it builds for the **device** SDK specifically so that
no simulator runtime is needed. The step contradicted the design written six lines above it.

**And the new rule: check the CI history when you inherit a claim about what has never been tried.**
The move to a standalone repo was housekeeping. Reading the Actions tab while confirming it was
clean answered the project's oldest open question in ten minutes.

Second bug in the same job, found because the log was read rather than skimmed for the error: a step
named `Prefer Xcode 26` globbed `/Applications/Xcode_26*.app` and took the **first** match, which
sorts as 26.0.1, while the runner's default was already 26.6. A step written to raise the toolchain
lowered it on every run and nothing noticed, because nothing downstream of it ever ran.

**What this does not mean.** A clean compile says the types line up. Every claim about the three
device legs still rests on Alex's own hardware, and the two tests that matter, the Eight Sleep
comfort write and the Whoop seven day split, are still unrun.
