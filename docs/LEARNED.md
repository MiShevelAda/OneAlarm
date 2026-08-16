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
