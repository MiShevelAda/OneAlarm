# Getting OneAlarm onto your iPhone

Written for someone who does not write code. Follow it top to bottom.

## What you need first

- **A Mac.** There is no way around this. An iPhone app has to be built by Xcode, and Xcode only
  runs on macOS. Nothing on a phone or in a browser can do it.
- **Xcode 26 or newer**, free from the Mac App Store. It is a large download, so start it first.
- **Your iPhone on iOS 26.1 or newer.** Check in Settings, General, About. AlarmKit, the thing that
  makes a real alarm ring through Silent mode, does not exist before iOS 26.
- **A free Apple Developer account**, which is just your normal Apple ID. No payment needed.
- **A USB cable** for the first install.

You do **not** need an Eight Sleep or Whoop account to get started. The iPhone alarm works on its
own, and that alone is worth installing.

## Step 1: get the code onto the Mac

Open Terminal, on the Mac, and paste this one line:

```
git clone https://github.com/MiShevelAda/Alex_personal_brand.git ~/OneAlarm-repo && cd ~/OneAlarm-repo && git checkout claude/onealarm-ios-app-qgwk4k && open alarm-app/OneAlarm.xcodeproj
```

Xcode opens. If it asks whether to trust the project, say yes.

## Step 2: tell Xcode who you are

This is the only setup step, and it takes about a minute.

1. In the left sidebar, click the blue **OneAlarm** icon at the very top.
2. In the main panel, click **Signing & Capabilities**.
3. Tick **Automatically manage signing**.
4. Next to **Team**, choose your Apple ID. If the list is empty, click **Add an Account**, sign in
   with your Apple ID, then come back and choose it.
5. **Bundle Identifier** currently reads `de.trucora.OneAlarm`. If Xcode complains that it is
   already taken, change it to something unique, for example `de.trucora.OneAlarm.alex`.

Do the same for the **OneAlarmTests** target in that same list, if it shows a signing error.

## Step 3: run it

1. Plug the iPhone in. Unlock it. If it asks, tap **Trust This Computer**.
2. At the top of the Xcode window, next to the OneAlarm name, there is a device dropdown. Choose
   your iPhone from it, not a simulator. **The simulator is not good enough for this app**, alarms
   behave incorrectly there and you would be testing a lie.
3. Press the **play triangle**, top left. First build takes a couple of minutes.

## Step 4: the bit that always trips people up

The first time, the app will refuse to open on the phone and iOS will say something about an
untrusted developer. That is normal and expected.

On the **iPhone**: Settings, General, VPN & Device Management, tap your Apple ID under
**Developer App**, then tap **Trust**.

Now open OneAlarm from the home screen.

## Step 5: use it

1. Tap the **key icon**, top right, then **Request permission** under iPhone. Allow it. This is the
   one-time alarm permission.
2. Close that, set a wake time on the wheel, pick your days.
3. Tap **Set all alarms**.
4. The iPhone row should turn green.

**This is the one test that matters, so do it before anything else.** Set the time two minutes
ahead, turn on Silent mode, turn on a Focus, lock the phone, and wait. It should ring anyway. That
is the whole point of AlarmKit and it is the only part of this app that no amount of code review
here could confirm.

If it does **not** ring, say so and say exactly what happened, because there is a known trap behind
it. AlarmKit presents alarms through the same machinery as Live Activities, and an app that offers a
countdown has to ship a separate widget target or the system quietly drops alarms instead of ringing
them. This app deliberately has no countdown and no snooze, precisely so that target is not needed.
If alarms turn out to need it anyway, that is a known and fixable shape of problem, not a mystery.

## Step 6, optional: connect Eight Sleep and Whoop

**Do this part first, in the other apps:** open the Eight Sleep app and make sure you have one
alarm set, and open the Whoop app and make sure you have one smart alarm set. OneAlarm **moves the
alarm you already have**, it does not create a new one. That is deliberate: creating one means
guessing at fields nobody has confirmed, and moving one means your vibration, thermal and smart wake
settings stay exactly as you set them.

Then in OneAlarm, tap the key icon and enter your account details for either service. Whoop will
text you a code. Enter it.

**Before you trust it**, long press any device row to open the preview. It shows the exact thing
that would be sent, without sending it. Nothing leaves the phone until you press Set all alarms.

## If something goes wrong

**"Provisioning profile doesn't include the com.apple.developer.alarmkit entitlement"**
There is no such entitlement. It does not exist. If that line is anywhere in the project, delete it.
This is a very common wrong suggestion.

**The build fails with Swift errors.**
Expect this to be possible. This code was written on a Linux machine with no Swift compiler and no
Xcode, so it has never been compiled. Copy the first error and send it over, and it gets fixed. The
first error is usually the only real one, since the rest cascade from it.

**Alarms do not fire in the simulator.**
Known, and not a bug in this app. Since iOS 26.1 the simulator does not fire alerts on a locked
screen and the sound behaves oddly. Use a real phone.

**Eight Sleep says "subscription required".**
Their alarm API is gated behind an active subscription. Sign in worked, that specific call did not.
Nothing on our side can fix it.

**Whoop stops working after about a month.**
Expected. Their refresh token expires and there is no way to read its expiry in advance. Open
Connections and sign in again with a fresh code.

## What this app deliberately cannot do

It cannot delete anything, change your bed temperature, move the bed frame, run the pump, play
audio, or touch your account settings. Each connection is limited to a short list of allowed web
addresses and everything else is refused before it is sent, including by mistake. That list is in
`OneAlarm/Adapters/EightSleepAdapter.swift` and `WhoopAdapter.swift` if you ever want to see it.

It will also never be on the App Store. Two of the three connections use private interfaces that
Apple does not permit. This is a personal build for your own phone and it was designed that way.
