# OneAlarm: the complete flow

Every screen and every state, so the prototype covers the whole thing rather than the happy path.
Built in HTML first, then translated to SwiftUI.

## The spine

```
Launch
  └─ First run?  ──yes──▶  1. Welcome
                              └─▶ 2. Alarm permission
                                     └─▶ 3. Connect devices (hub)
                                            ├─▶ Eight Sleep link flow
                                            ├─▶ Whoop link flow
                                            └─▶ Skip ──┐
  └─ Returning ────────────────────────────────────────┴─▶ 4. Cascade (home)
                                                              ├─▶ 5. Preview sheet
                                                              ├─▶ 6. Applying / result
                                                              └─▶ 3. Connect devices
```

## Screens

### 1. Welcome
The problem in one line: three alarms, three apps, every time the time moves. What it does. What it
needs. One button. No account, no signup, nothing to create.

### 2. Alarm permission
Explains before the system prompt appears, because a prompt you did not expect is a prompt you deny.
Says plainly that this is the one alarm that rings through Silent and Focus, and that it also lands
on the Apple Watch. Then the system sheet.

**States:** not asked, granted, denied. Denied is recoverable and says exactly which Settings path.

### 3. Connect devices, the hub
Three rows, each with a state. This is also reachable later from the home screen, so it is a hub not
a wizard step.

**Row states:** not connected, connecting, connected with detail, needs attention, unavailable.

The iPhone row is never "not connected" once permission is granted, and it carries a line making
clear it works with no account at all.

### 4. Eight Sleep link flow
1. **Prerequisite** screen. You must already have one alarm in the Eight Sleep app. Explains why:
   OneAlarm moves your alarm rather than creating one, so your thermal and vibration settings survive.
2. **Credentials.** Email, password. A line saying the password stays in the iPhone Keychain and that
   Eight Sleep issues no refresh token, which is why the password has to be kept at all.
3. **Working.** Signing in, then looking for the alarm. Two steps, shown as two.
4. **Result.** Success names the alarm found: "Found your alarm, currently 07:00."

**Failure states, each with its own copy and its own recovery:**
- Wrong password. Notes the saved one was not overwritten.
- **Subscription required.** Sign in worked, alarms are gated. Nothing the app can do.
- **No alarm to move.** Go make one, come back.
- Rate limited. Wait, and why it will not retry on its own.

### 5. Whoop link flow
1. **Prerequisite.** A smart alarm must exist and the schedule must be switched on.
2. **The honest warning.** No official API, personal account only, their terms allow them to act
   against the account. Accept or back out. This is a decision, so it gets a screen.
3. **Credentials.**
4. **The texted code.** Six digits, expires in about three minutes.
5. **Working, then result** naming the schedule and its wake mode.
6. **Aftercare.** Sign in again about monthly. Keep the Whoop app installed, because it is what
   carries the change to the band.

**Failure states:** wrong password, wrong or expired code, rate limited, schedule off, no schedule,
unreadable schedule shape.

### 6. Cascade, the home screen
The one screen that matters.

- Master wake time, editable in place.
- Day selector.
- The cascade: one row per device, ordered by when it fires, each with its resolved time, its offset
  control and its state.
- The apply button.
- Footer state: last set, changed since last set, or nothing was set.

**Row states:** idle, writing, verifying, set and confirmed, accepted but unconfirmed, failed, not
connected, disabled.

**Warnings that appear inline:** an offset crossing midnight, the iPhone leg switched off, alarms
straddling a daylight saving change.

### 7. Preview sheet
Reached by long press or the preview control. The resolved values, then the literal outbound request.
States plainly that nothing has been sent.

### 8. Applying
Not a spinner over the whole screen. Each row moves independently, because the legs are independent
and one failing must not look like all failing.

### 9. Result
Per row. Green is written and read back and confirmed. Orange is accepted but not confirmed, or
confirmed at a different time than asked for, which is the timezone case. Red is failed, with cause.

## States inventory

Everything the prototype must be able to show.

| Area | States |
|---|---|
| Alarm permission | not asked, granted, denied |
| Eight Sleep | not connected, connecting, connected, wrong password, no subscription, no alarm, rate limited, needs reauth |
| Whoop | not connected, awaiting code, connecting, connected, wrong password, bad code, schedule off, no schedule, rate limited, needs reauth |
| Cascade row | idle, writing, verifying, confirmed, unconfirmed, mismatch, failed, not connected, off |
| Home footer | never applied, last set at, changed since, nothing set |
| Whole app | first run, configured, nothing connected but iPhone |

## Rules the design must carry

- **The iPhone leg is visually distinct from the other two.** It needs no account and it is the only
  one that rings regardless. Switching it off warns.
- **Nothing claims success it has not verified.** "Set" and "accepted but unconfirmed" are different
  states and must look different.
- **Every failure says what to do next**, and failures that are not the user's fault say so.
- **Nothing is sent from the preview.** That has to be unmissable.
