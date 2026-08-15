# Wake Cascade, the browser preview

Open `wake-cascade.html` in any browser, including the phone.

It runs the **same offset, midnight and daylight-saving arithmetic as `RulesEngine.swift`** and shows
what each device would be sent. Use it to settle the offsets before building, so the app is right the
first time rather than after three mornings of tuning.

## What it cannot do, and why

**It cannot ring an alarm.** A browser tab cannot play audio when the phone is locked and cannot
break through Silent mode or a Focus. That is exactly why the app uses AlarmKit.

**It cannot set the Eight Sleep or Whoop alarm.** Neither API sends CORS headers, so the browser
blocks the request before it leaves the page. The only way around that is a server in the middle
holding the account passwords, which is precisely the thing this project refuses to build: the
credentials stay in the iPhone Keychain and go nowhere else.

So this is a calculator with the real logic in it, not a smaller version of the app. Treat any number
it shows as what the app will do, and nothing it shows as something that has happened.

## Keeping it honest

If `RulesEngine.swift` changes, change this too. Two implementations of one rule is how the two
quietly stop agreeing. The parts that must match: the `floor` day-shift division, the weekday shift
when an offset crosses midnight, and the fixed-offset string Whoop wants.
