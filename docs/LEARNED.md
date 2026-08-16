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
