# Getting OneAlarm onto your iPhone

Written for someone who does not write code. Start with "Which route" and follow only that one.

## The one unavoidable fact

**An iPhone app has to be compiled by Xcode, and Xcode only runs on macOS.** There is no exception,
no web service that does it properly, and no way to do it on the phone itself. Every route below is
a different way of getting access to a Mac, not a way of avoiding one.

## Which route

| | You have | Cost | App expires | Cable needed |
|---|---|---|---|---|
| **A** | A Mac | free | **every 7 days** | yes, first time |
| **B** | A Mac, and you want it to stick | 99 USD a year | 1 year | yes, first time |
| **C** | No Mac | 99 USD a year, plus a few USD of rented Mac | 1 year | **no** |

**Route A is the one to start with if you can borrow a Mac for twenty minutes**, even someone
else's. The seven day expiry is annoying but it costs nothing and proves the whole thing works.

**Route C is the real answer if you have no Mac at all.** It ends with the app arriving on your
phone through TestFlight, over the air, with no cable ever.

---

## Route A: a Mac, free

### 1. Get the code

Open Terminal on the Mac and paste this one line:

```
git clone https://github.com/MiShevelAda/OneAlarm.git ~/OneAlarm-repo && cd ~/OneAlarm-repo && open OneAlarm.xcodeproj
```

Xcode opens. If it asks whether to trust the project, say yes.

### 2. Tell Xcode who you are

1. Left sidebar, click the blue **OneAlarm** icon at the very top.
2. Main panel, click **Signing & Capabilities**.
3. Tick **Automatically manage signing**.
4. Next to **Team**, choose your Apple ID. If the list is empty: **Add an Account**, sign in with
   your normal Apple ID, come back, choose it.
5. If Xcode says the bundle identifier is taken, change `de.trucora.OneAlarm` to
   `de.trucora.OneAlarm.alex`.

Repeat for the **OneAlarmTests** target if it shows a red signing error.

### 3. Run it

1. Plug the iPhone in, unlock it, tap **Trust This Computer** if asked.
2. Top of the Xcode window, in the device dropdown, choose **your iPhone**, not a simulator.
   **The simulator is not good enough for this app.** Since iOS 26.1 it does not fire alerts on a
   locked screen and the sound behaves oddly, so a simulator test would tell you nothing.
3. Press the **play triangle**, top left.

### 4. The step that trips everyone up

The first launch fails with a message about an untrusted developer. That is normal.

On the **iPhone**: Settings, General, VPN & Device Management, tap your Apple ID under
**Developer App**, tap **Trust**. Now open OneAlarm from the home screen.

### 5. The seven day thing

With a free Apple ID the app stops opening after 7 days. Plug in, press play again, and it works
for another 7. Route B removes this.

---

## Route B: a Mac, 99 USD a year

Everything in Route A, plus: join the Apple Developer Program at
[developer.apple.com/programs](https://developer.apple.com/programs/). Once your Apple ID is a paid
member, Xcode issues a one year provisioning profile instead of a seven day one, and nothing else
changes. This is the least effort per year if you have a Mac.

---

## Route C: no Mac at all

The shape of this route: **rent a Mac by the hour, build there, send the app to TestFlight, and
TestFlight installs it on your phone over the air.** You never touch a cable and you never own a Mac.

### What it needs

- **The Apple Developer Program, 99 USD a year.** Not optional on this route. TestFlight does not
  exist without it. Sign up at [developer.apple.com/programs](https://developer.apple.com/programs/)
  and expect up to 48 hours for approval.
- **A rented Mac, for about an hour.** Options, cheapest first:
  - **Scaleway Mac mini**, billed by the hour, roughly 0.10 to 0.20 EUR an hour, minimum 24 hours.
  - **MacinCloud**, from about 1 USD an hour or ~30 USD a month, and it is the most beginner
    friendly because you get a plain remote desktop with Xcode already installed.
  - **AWS EC2 Mac**, powerful and expensive, with a 24 hour minimum. Only if you already use AWS.

### The steps

1. **Join the Apple Developer Program** and wait for approval.
2. **Rent the Mac** and connect to it. You get a normal macOS desktop in a window.
3. **Install Xcode** from the Mac App Store if it is not already there.
4. **Clone the repo and open the project**, exactly as in Route A step 1.
5. **Sign in** with your Apple ID under Signing & Capabilities, as in Route A step 2. Pick your
   paid team.
6. **Archive it.** In Xcode's menu bar: Product, then Destination, then **Any iOS Device**. Then
   Product, then **Archive**. When it finishes the Organizer window opens.
7. **Upload to App Store Connect.** In the Organizer: **Distribute App**, then **TestFlight &
   App Store**, then follow the prompts. It uploads and processes for a few minutes.
8. **On your phone**, install **TestFlight** from the App Store, sign in with the same Apple ID.
   The build appears under Internal Testing. Tap Install.

You can now shut the rented Mac down. The app lives on your phone for the length of the build's
TestFlight validity and you only need a Mac again when the code changes.

### Two things that are true and worth knowing

**Internal TestFlight testing normally requires no App Review.** You are adding yourself as an
internal tester on your own team, which is a different thing from releasing an app. Only external
testers and actual App Store releases go through review.

**I was wrong earlier when I said this app could not pass App Store review because of private
APIs.** It uses no private *Apple* APIs at all. AlarmKit is a normal published Apple framework. What
it does use is Whoop's and Eight Sleep's own internal web services, which is a question about *their*
terms of service, not Apple's technical rules. For a personal build and for TestFlight internal
testing, that distinction means this route is genuinely open. It is still not something to publish
to the public App Store.

---

## Route D, which does not exist

There is no way to do this with no Mac and no paid Apple account. Things that sound like they might
work and do not:

- **Swift Playgrounds on iPhone.** It cannot open an Xcode project, and it cannot set the
  `NSAlarmKitUsageDescription` permission key this app requires. On iPad it is closer but still
  cannot open this project.
- **Online "build your iOS app" services.** They compile web apps into a shell. They cannot use
  AlarmKit, which means no alarm that survives Silent mode, which is the entire point.
- **Installing the app file directly.** iOS refuses to install anything not signed by a developer
  account tied to your device.

---

## The GitHub build, which is currently blocked

There is a workflow at `.github/workflows/onealarm.yml` that compiles the app and runs the tests on
GitHub's own Mac servers. It would tell us whether the code builds without anyone owning a Mac. It
is worth fixing because it is free feedback on every change.

**Right now it fails instantly and runs nothing at all.** I pushed it, watched two runs, and both
produced zero jobs, including a deliberately trivial Linux job that costs almost nothing. That
pattern means GitHub is refusing to start any job in this repository, which is an account setting
rather than a problem with the file.

**This is yours to fix, it takes two minutes, and it needs your GitHub login.** Check these two, in
order:

1. **github.com/settings/billing** → look for **Actions minutes**. This repository is private, and
   private repositories consume a monthly allowance. If it is used up, or if there is no payment
   method and a spending limit of zero, every run dies immediately exactly like this. Mac servers
   also bill at **ten times** the normal rate, so the allowance goes quickly.
2. **The repository** → Settings → Actions → General → make sure **Allow all actions** is selected
   rather than Actions being disabled.

**The cheapest fix, if you would rather not pay:** make this repository public. Public repositories
get unlimited free Actions minutes including the Mac servers. The move out of `Alex_personal_brand`
happened on 2026-08-18 and was the prerequisite, because that repo holds the career-pivot material
and could never be made public. This one can: no credentials, no personal data, and a test that
fails the build if anything token shaped ever appears.

Once either fix is in, every push builds and tests the app automatically and you find out about a
broken build in five minutes instead of at 6am.

---

## When it does not work

**"Provisioning profile doesn't include the com.apple.developer.alarmkit entitlement"**
There is no such entitlement. It does not exist. If that line appears anywhere, delete it. This is a
common wrong suggestion and Apple's own engineers have complained about it.

**The build fails with Swift errors.**
Less likely than it used to be. Since 2026-08-18 a macOS runner compiles this clean for the device
SDK on every push, so the code that reaches you has been through a real compiler. Your Xcode can
still differ in version or settings. Copy the **first** error and send it over. The first is usually
the only real one and the rest cascade from it.

**Alarms do not fire in the simulator.**
Known, and not a bug in this app. Use a real phone.
