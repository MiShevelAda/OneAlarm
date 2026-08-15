# Connecting your three devices

Read this once the app is on your phone. `BUILD.md` covers getting it there.

**Do the prep in each device's own app first.** OneAlarm **moves an alarm you already have**, it
does not create one. That is deliberate: creating an alarm means guessing at settings nobody has
confirmed, and moving one means your vibration, thermal and smart wake choices stay exactly as you
set them. If there is no alarm to move, the app says so and tells you what to do.

---

## Prep, five minutes, before you open OneAlarm

| Device | Do this first |
|---|---|
| **iPhone** | Nothing. |
| **Eight Sleep** | Open the Eight Sleep app and make sure **one alarm exists**. Any time, it gets overwritten. Also check your subscription is active, since their alarms stop working without it. |
| **Whoop** | Open the Whoop app, create a **smart alarm**, and make sure the alarm schedule is **switched on**, not just created. |
| **Apple Watch** | Nothing. It mirrors the iPhone alarm automatically. |

---

## 1. iPhone, and the Apple Watch that comes with it

This is the one that needs no account and no internet.

1. Open OneAlarm, tap the **key icon**, top right.
2. Under **iPhone**, tap **Request permission**. Allow it. This happens once.
3. Close the sheet. Set a wake time on the wheel. Pick your days.
4. Tap **Set all alarms**. The iPhone row turns green.

**Test it properly before trusting it.** Set the time two minutes ahead, turn on Silent mode, turn
on a Focus, lock the phone, put it face down, and wait. It should ring anyway. That is the whole
point and it is the only thing about this app that no amount of checking on my side could confirm.

Your Apple Watch will show and sound the same alarm if it is paired and on your wrist. There is
nothing to set up and nothing to connect.

---

## 2. Eight Sleep

1. Key icon, scroll to **Eight Sleep**.
2. Enter the email and password you use for the Eight Sleep app itself.
3. Tap **Connect**.

**What you should see.** Not just "connected". The app signs in, then immediately goes and looks at
your actual alarm, and tells you what it found:

> Connected. Found your alarm, currently 07:00.

That sentence is the useful one. It means the password worked, the subscription is active, and there
is a real alarm sitting there to move. If you have several alarms it says how many and which one it
will move.

**What can go wrong, and what it means:**

| Message | What it actually means |
|---|---|
| "Eight Sleep says this account needs an active subscription to use alarms." | Your password is fine. Their alarm service is gated behind a live subscription and yours is not currently active. Nothing in this app can work around that. |
| "No alarm found to move. Create one alarm in the device's own app first." | Exactly what it says. Open the Eight Sleep app, make one alarm, come back, tap Connect again. |
| "Sign in failed." | Wrong email or password. It does **not** overwrite your saved password on a failed attempt, so a typo cannot lock you out. |
| "Too many requests." | You tried too often. Wait a minute. The app deliberately refuses to keep retrying, because repeated failed sign ins are how accounts get locked. |

**Your bed settings are safe.** The app reads your existing alarm, changes only the time, the days
and the on switch, and sends everything else back exactly as it arrived. It has no way to change
your temperature, run the pump, or move the bed frame. Those requests are blocked before they are
sent, and there are tests that fail the build if that ever stops being true.

---

## 3. Whoop

Whoop is the fiddliest of the three, and it is worth knowing why before you start.

1. Key icon, scroll to **Whoop**.
2. Enter your Whoop email and password. Tap **Connect**.
3. **Whoop texts you a code.** The screen changes to ask for it. Type it in and tap **Confirm code**.
   The code expires after about three minutes, so do it straight away.
4. You should then see something like:

> Connected. Found your smart alarm, currently 07:30 on IN_THE_GREEN.

`IN_THE_GREEN` is Whoop's own name for waking you at the best moment before your set time. Whatever
mode you chose in their app is preserved, OneAlarm only moves the time.

**Three things about Whoop you should know up front, none of which are avoidable:**

**You will have to sign in again roughly once a month.** Whoop's login expires after about thirty
days and there is no way to read the expiry in advance, so the app cannot warn you before it
happens. It shows an orange "sign in again" state when it does. Re-connecting takes a minute.

**Keep the Whoop app installed and open it now and then.** OneAlarm changes the alarm on Whoop's
servers. Their own app is what carries that down to the band on your wrist. Whether the band updates
without the Whoop app ever running is genuinely unknown, so do not delete it.

**Whoop does not offer this officially.** There is no public alarm API, so this uses the same
internal service their own app uses. That is a personal account only arrangement. Their terms
technically allow them to act against an account using an unsupported integration, and in practice
the worst case is your Whoop membership. Your call, and worth knowing before you connect rather than
after.

---

## Checking what will be sent, before it is sent

Long press any device row, or tap **Preview**, and you get the exact outbound request: the address,
the method, and the full body. Nothing is sent while that sheet is open. It is built by the same code
that builds the real request, so it is not an approximation.

Worth doing once per device the first time, particularly for Whoop.

---

## Reading the main screen

- **Grey "Not connected"** means that device has no account details yet. It is skipped rather than
  failed, and it does not paint a red cross at you on first launch.
- **Green with a time** means the write happened **and** was read back and confirmed. Not just
  "accepted".
- **Orange** means it was accepted but could not be confirmed, or it came back set to a different
  time than asked for. Worth a look.
- **Red** means it failed, with the reason.
- **"previous day"** under a time is not a bug. If your wake time is just after midnight, a device
  set ten minutes earlier genuinely fires the night before, and the app shifts that device's days
  back by one so the bed warms on the right night.

---

## The rule the whole thing is built around

**The iPhone alarm never depends on the other two.** If Whoop's login has expired, if Eight Sleep's
subscription lapsed, if the wifi is off, if both services are down, the iPhone alarm still rings.
The legs are written so a failure in one cannot stop another, and a credential problem is never
allowed to become a missed alarm.

If you ever switch the iPhone row off, the app warns you on the main screen, because that is the
only one that rings without a connection.
