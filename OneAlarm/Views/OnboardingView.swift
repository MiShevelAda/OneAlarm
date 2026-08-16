import SwiftUI
import UIKit

/// Setup, start to finish, before the home screen is ever seen.
///
/// Alex, 2026-08-16: *"ideally I should set up everything from the beginning, so when I go to the
/// home screen everything is already set up, and they should be done from the beginning and not
/// from the settings of the app."*
///
/// The previous version was two screens, welcome and the alarm permission, and left both accounts
/// to be discovered later behind a key icon in the corner. So the first thing the app ever showed
/// was a home screen with two of its three legs missing and no indication that was unusual.
///
/// Pick the devices, then connect them in order, then land on a working screen. Every account step
/// is skippable, and skipping is a stated outcome rather than a silence: the home screen says which
/// legs are not connected.
@MainActor
struct OnboardingView: View {
    @Environment(ScheduleStore.self) private var store

    let onFinished: () -> Void

    @State private var step: Step = .devices
    @State private var wanted: Set<DeviceID> = [.iphone, .eightSleep, .whoop]
    @State private var denied = false
    @State private var linking: DeviceID?
    @State private var skipped: Set<DeviceID> = []

    enum Step: Equatable { case devices, permission, connect(DeviceID) }

    /// Accounts to connect, in the order they are asked for.
    ///
    /// Whoop first because its sign in can stop at a texted code, which means leaving the app. Doing
    /// that first means the trip out happens while setup is clearly unfinished, rather than as the
    /// last thing between him and a working screen.
    private var accountQueue: [DeviceID] {
        [.whoop, .eightSleep].filter { wanted.contains($0) }
    }

    var body: some View {
        Group {
            switch step {
            case .devices: devices
            case .permission: denied ? AnyView(permissionDenied) : AnyView(permission)
            case .connect(let device): connect(device)
            }
        }
        .sheet(item: $linking) { device in
            Group {
                switch device {
                case .eightSleep: EightSleepLinkView()
                case .whoop: WhoopLinkView()
                case .iphone: EmptyView()
                }
            }
            .environment(store)
        }
        .onChange(of: linking) { previous, current in
            // The sheet closing is the signal. It closes on success, on cancel and on a refusal, so
            // the auth state decides what happened rather than the dismissal.
            guard current == nil, let previous else { return }
            Task {
                await store.refreshAuthStates()
                advance(past: previous)
            }
        }
    }

    // MARK: 1. Which devices

    private var devices: some View {
        Screen(title: "OneAlarm") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What wakes you up?")
                        .font(.system(size: 30, weight: .bold)).tracking(-0.7)
                    Text("Pick everything you use. OneAlarm sets one time and moves all of them to match it.")
                        .font(.system(size: 15)).foregroundStyle(Theme.grey)
                }
                .padding(.top, 4)

                deviceToggle(.iphone, detail: "Always on. This is the one that has to ring.", locked: true)
                deviceToggle(.whoop, detail: "Haptic wake window on the strap.", locked: false)
                deviceToggle(.eightSleep, detail: "Thermal and vibration, before the sound.", locked: false)
                soonRow("Oura Ring")
                soonRow("Garmin")

                Notice("Nothing is connected yet. The next screens ask for each account, and every one of them can be skipped and done later.")
            }
            .padding(.bottom, 20)
        } footer: {
            SolidButton(title: "Continue") { step = .permission }
        }
    }

    private func deviceToggle(_ device: DeviceID, detail: String, locked: Bool) -> some View {
        let on = wanted.contains(device)
        return Button {
            guard !locked else { return }
            if on { wanted.remove(device) } else { wanted.insert(device) }
        } label: {
            HStack(spacing: 13) {
                Image(systemName: device.symbolName)
                    .font(.system(size: 17))
                    .frame(width: 40, height: 40)
                    .background(Theme.cardLift, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .foregroundStyle(Theme.Ramp.lit(for: device))

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName).font(.system(size: 17, weight: .semibold))
                    Text(detail).font(.system(size: 13)).foregroundStyle(Theme.grey)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: .constant(on))
                    .labelsHidden()
                    .tint(Theme.State.confirmed)
                    .allowsHitTesting(false)
                    .opacity(locked ? 0.55 : 1)
            }
            .padding(15)
            .frame(maxWidth: .infinity)
            .background(on ? AnyShapeStyle(Theme.Ramp.card(for: device)) : AnyShapeStyle(Theme.card),
                        in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(on ? Theme.State.confirmed.opacity(0.4) : Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Named rather than hidden, because "does it work with my Oura" is answered better by a greyed
    /// row than by an absence.
    private func soonRow(_ name: String) -> some View {
        HStack(spacing: 13) {
            Text(name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.greyDim)
            Spacer(minLength: 8)
            Text("LATER")
                .font(.system(size: 10, weight: .bold)).tracking(1)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(Theme.greyDim)
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
    }

    // MARK: 2. The one permission that matters

    private var permission: some View {
        Screen(title: "iPhone", onBack: { step = .devices }) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Let OneAlarm set alarms")
                        .font(.system(size: 30, weight: .bold)).tracking(-0.7)
                    Text("These are real system alarms. They ring through Silent mode and through Focus, and they show on the Lock Screen.")
                        .font(.system(size: 15)).foregroundStyle(Theme.grey)
                }
                .padding(.top, 4)

                Notice(title: "This is the leg that has to work.",
                       "Your bed and your strap need an account, a network and a server. The phone needs none of them, which is why it is the one that carries the guarantee.")

                Notice(.warn, title: "Turn off your other wake alarm.",
                       "OneAlarm cannot see or change the alarm in your iOS sleep schedule, so if it is on, it will ring at its own time as well. Health, Sleep, Change Wake Up, then the Alarm toggle.")
            }
            .padding(.bottom, 20)
        } footer: {
            SolidButton(title: "Allow alarms") {
                Task {
                    let granted = await store.alarmKit.requestAuthorization()
                    await store.refreshAuthStates()
                    if granted { beginAccounts() } else { denied = true }
                }
            }
        }
    }

    private var permissionDenied: some View {
        Screen(title: "iPhone") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Alarms are switched off")
                    .font(.system(size: 30, weight: .bold)).tracking(-0.7)
                    .padding(.top, 4)
                Notice(.bad, title: "Nothing can wake you until this is on.",
                       "1. Open Settings.\n2. Scroll to OneAlarm.\n3. Turn Alarms on.")
            }
            .padding(.bottom, 20)
        } footer: {
            SolidButton(title: "Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            QuietButton(title: "Carry on without it") { beginAccounts() }
        }
    }

    // MARK: 3. Each account, in turn

    private func connect(_ device: DeviceID) -> some View {
        let position = (accountQueue.firstIndex(of: device) ?? 0) + 1
        return Screen(title: device.displayName) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect \(device.displayName)")
                        .font(.system(size: 30, weight: .bold)).tracking(-0.7)
                    Text("Account \(position) of \(accountQueue.count). Then you are done.")
                        .font(.system(size: 15)).foregroundStyle(Theme.grey)
                }
                .padding(.top, 4)

                Notice(title: "OneAlarm moves alarms you already have.",
                       device == .whoop
                       ? "It changes the time on your smart alarm schedule and leaves the wake mode you chose alone. It never creates one and never deletes one."
                       : "It matches each of your routines to the alarm that already runs on the same days, and changes only that alarm's time. Days, vibration and thermal stay exactly as you set them. It never creates one and never deletes one.")

                if device == .eightSleep {
                    Notice(.warn, title: "Set your alarms up in the Eight Sleep app first.",
                           "One per routine, on the days you want. Any time will do, OneAlarm sets the times from then on.")
                }
            }
            .padding(.bottom, 20)
        } footer: {
            SolidButton(title: "Sign in to \(device.displayName)") { linking = device }
            QuietButton(title: "Skip, set this up later") {
                skipped.insert(device)
                advance(past: device)
            }
        }
    }

    // MARK: Flow

    private func beginAccounts() {
        denied = false
        if let first = accountQueue.first {
            step = .connect(first)
        } else {
            onFinished()
        }
    }

    /// Move to the next account, or finish.
    ///
    /// Deliberately advances whether the account connected or not. A sheet that closed on a refusal
    /// still means "this one is done for now", and blocking setup on an account that may be
    /// unreachable at that moment would trap somebody behind a device they cannot fix from here.
    private func advance(past device: DeviceID) {
        guard let index = accountQueue.firstIndex(of: device) else {
            onFinished()
            return
        }
        let next = index + 1
        if next < accountQueue.count {
            step = .connect(accountQueue[next])
        } else {
            onFinished()
        }
    }
}
