# CLAUDE.md: OneAlarm

A personal iOS app. One wake time, propagated to every device that can wake Alex: his iPhone, his
Eight Sleep Pod, his Whoop strap. It **moves alarms that already exist** rather than creating them,
on two of its three legs.

This is Alex's own project and is deliberately separate from the repo it currently sits inside. It
will move to its own repository. Nothing in the parent repo's instructions applies here, except by
coincidence of good sense.

## Read these first, in this order

1. **`docs/LEARNED.md`**: what worked, what did not, what Alex decided and why, in his words. Thirty
   seconds, and it is the difference between repeating a mistake and not.
2. **`docs/EXPERIMENTS.md`**: everything unknown, written as a test with a prediction. Before
   forming a theory about a service, check whether the answer is already there or already scheduled.
3. **`docs/STATUS.md`**: where the build actually is, and what is broken today.
4. **`docs/RESEARCH.md`**: the API record, including a long account of how earlier conclusions were
   wrong. Read section 2.3 before touching the Whoop adapter.
5. `docs/SETTINGS.md` and `docs/USER-CASES.md` when working on the design.

## The rules that were paid for

Each of these cost something. The cost is named so nobody optimises it away.

- **When stuck, dump the response. Do not reason.** Both Whoop breakthroughs came from printing what
  the server sent. Six rounds of reasoning produced six wrong answers. Cost: five hours.
- **Change one thing per test.** Four changes then a conclusion is not a result.
- **A diagnostic that only fires on failure answers nothing.** Two questions went unanswered for
  weeks because the parse succeeded and the diagnostic was gated on failure.
- **Never infer absence from an object you did not look at.** Whoop's field names and Eight Sleep's
  bed names were both declared not to exist on this reasoning. Both exist.
- **A test that mutates a live account is a change.** Turning on all seven days to test the ring
  rewrote Alex's real Whoop schedule. Restore first, or test on a value already correct.
- **Read modify write, always.** Both remote legs replace. Echo back everything not being changed,
  including fields with no known meaning.
- **A 200 is not a moved alarm.** Verify against an absolute instant where one exists. Whoop returns
  none, so its best state is `saved`, permanently.
- **Never silently change a setting Alex chose.** A retry once flipped his Whoop wake mode to get
  past a suspected error. Adopt, or ask, never overwrite.
- **Say what a thing is.** An AI agent is not an expert. He noticed.

## Voice

Direct and simple. No filler, no inflated significance. **No em-dashes anywhere**: commas, colons,
semicolons, periods.

Say who does what, every time. Alex is not a coder and should never have to infer whether a step is
his or the session's. One pasteable line, or numbered taps, and what he should see when it worked.

Three genuinely different options when something goes out in his name, not one answer presented as
finished.

## Do not

- Send anything to `smart-alarm-service`, including `strap-status` and `wbl`. The whole prefix is
  outside the Whoop allowlist on purpose.
- **Create** an alarm on Whoop. Alex deleted every Whoop schedule on 2026-08-17 and neither OneAlarm
  nor Whoop's own `CREATE SCHEDULE` button could make one, so this is being reopened, but **only
  against a captured request**. The six-field body is confirmed; the address and verb for a create
  are not, and guessing on this service already cost five hours. See the raw envelope panel.
- **Delete an Eight Sleep alarm OneAlarm did not create.** Deleting is otherwise allowed as of
  2026-08-17, when Alex overruled the blanket ban: *"the one alarm app should be able to delete
  alarms if there are changes because right now for whatever reason I had three alarms in my sleep
  app and I had to delete all the alarms in the eight sleep app and set all alarms again from the
  one alarm app."*

  What makes it safe is not care, it is provenance. `RemoteAlarmLink` records the id of every alarm
  OneAlarm creates, and **only an id on that list may ever be deleted**, and only once no live
  routine claims it. An alarm he made by hand, or one OneAlarm adopted because its days matched, is
  never deleted whatever state it is in: adoption means the alarm was already his. Switching one off
  is the most that may happen to it, and that is reversible.
- Create an Eight Sleep alarm by composing a payload. Alex overruled the create ban on 2026-08-16:
  *"the OneAlarm app should also write the new alarm sequence into the Eight Sleep app, and I
  shouldn't do it manually."* What makes it safe is not care, it is that `clone` copies an alarm the
  account already has and changes two fields. No field is ever guessed, the account is capped at 8
  alarms, and nothing here can delete what it makes.
- Author Eight Sleep `vibration`, `thermal`, `audio`, level or pattern. Echo them; they are his, and
  he set the line himself: *"only the modifications of temperature, vibration etc should be done in
  the respective app."* OneAlarm authors exactly three fields on an alarm it owns: `time`,
  `repeat.weekDays`, `enabled`.
- Author a routine's `bedtime`, or any routine field other than `days` and `enabled`. When he goes to
  bed is not an alarm setting. The routine object is read, two fields are replaced, and the whole
  rest of it is sent back exactly as it came, unknown fields included.
- Open a routine OneAlarm has no relationship with. Only a routine that owns an alarm a OneAlarm
  routine owns is ever written to.
- Write anything at all to an alarm OneAlarm does not own. Ownership means a `RemoteAlarmLink` entry
  or an exact day set adoption recorded in the same run. Writing days to an unowned alarm is what
  turned a real Monday to Friday schedule into every day.
- Retry `USER_PASSWORD_AUTH` or the Eight Sleep password grant. One attempt, surface the error, stop.
- Delete a Keychain item on `errSecInteractionNotAllowed`. That is a locked device, not a missing
  credential.
- Add `com.apple.developer.alarmkit`. It does not exist. Ship a non-empty
  `NSAlarmKitUsageDescription` in `Config/Info.plist`, which exists because `INFOPLIST_KEY_` silently
  drops that key.

## Verify before saying done

```bash
npm install                           # once, for the syntax checker
npm run check                         # structure and secrets, then a real Swift parse
```

No Swift **compiler** exists in the session environment. `download.swift.org`, `github.com` releases
and `objects.githubusercontent.com` are all refused by the proxy, checked rather than assumed. But
`registry.npmjs.org` bypasses the proxy, so `tools/parse_swift.js` runs tree-sitter's Swift grammar
over every file and catches real syntax errors. Read its header before trusting or doubting it: three
false positives are documented there, each confirmed rather than guessed, so nobody re-investigates
them.

**A parse is not a type check.** It cannot see a wrong type, a missing argument label, or the two
things that actually shipped broken on 16 August: an unannotated heterogeneous dictionary literal,
and eleven empty collection literals in `Any` position. Both were caught by grep, and the greps that
find them are worth running by hand on new code:

```bash
grep -rn ': \[\s*\]\|: \[\s*:\s*\]' --include=*.swift OneAlarm OneAlarmTests   # empty literal in an Any position
```

**The three services are unreachable from a session too.** `app-api.8slp.net` is refused by the proxy
at the CONNECT stage, gateway 403, checked on 16 August with four unauthenticated GETs. So even a 404
against 401 probe, which needs no credentials and would settle which API version an endpoint lives
at, cannot be run here. Every question about what their server accepts is answerable only on Alex's
phone. Do not spend the time re-discovering that.

And never ask him for a password to work around it. Credentials live in his iPhone Keychain, that is
the whole design, and a session holding one would be worse than the delay it saves.

Nothing here has been compiled by a session; the app is built by Alex in Xcode. **Say "not compiled"
rather than implying otherwise**, and never call something done that only a compiler could confirm.

## Capture as you go

When Alex corrects something, chooses between options, or says what he likes, it goes in
`docs/LEARNED.md` in the same session, **in his words**. When something is unknown, it goes in
`docs/EXPERIMENTS.md` as a test with a prediction written **before** it runs, not as a note to
worry about later.
