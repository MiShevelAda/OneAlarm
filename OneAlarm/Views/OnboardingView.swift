import SwiftUI
import UIKit

@MainActor
struct OnboardingView: View {
    @Environment(ScheduleStore.self) private var store
    let onFinished: () -> Void

    @State private var step: Step = .welcome
    @State private var denied = false

    enum Step { case welcome, permission }

    var body: some View {
        switch step {
        case .welcome: welcome
        case .permission: denied ? AnyView(permissionDenied) : AnyView(permission)
        }
    }

    // MARK: Welcome

    private var welcome: some View {
        Screen {
            VStack(alignment: .leading, spacing: 0) {
                Text("OneAlarm").themeLabel().padding(.bottom, 18)

                Text("You set the same alarm three times. Stop.")
                    .font(.system(size: 33, weight: .bold))
                    .tracking(-0.9)
                    .padding(.bottom, 12)

                Text("One wake time. Your bed, your band and your phone all follow it. Move it once and everything recomputes.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.grey)
                    .padding(.bottom, 26)

                VStack(spacing: 0) {
                    ladder(.eightSleep, "Ten minutes early, so the bed has time")
                    ladder(.whoop, "Five minutes early, a haptic nudge")
                    ladder(.iphone, "On the minute, and loud")
                }
                .padding(.vertical, 4)
                .themeCard()

                Text("No account. Nothing to sign up for. Your passwords stay on this phone.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.greyDim)
                    .padding(.top, 18)
            }
            .padding(.top, 40)
        } footer: {
            SolidButton(title: "Get started") { step = .permission }
        }
    }

    private func ladder(_ device: DeviceID, _ why: String) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.Ramp.rail(for: device))
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.system(size: 15, weight: .semibold))
                Text(why).font(.system(size: 13)).foregroundStyle(Theme.grey)
            }
            Spacer()
        }
        .padding(.horizontal, 15).padding(.vertical, 11)
    }

    // MARK: Permission

    private var permission: some View {
        Screen(title: "Step 1 of 2") {
            VStack(spacing: 0) {
                Image(systemName: "alarm.waves.left.and.right.fill")
                    .font(.system(size: 30))
                    .frame(width: 80, height: 80)
                    .overlay(Circle().strokeBorder(Theme.lineStrong, lineWidth: 1.5))
                    .padding(.top, 22).padding(.bottom, 26)

                Text("The one that actually wakes you")
                    .font(.system(size: 27, weight: .bold))
                    .tracking(-0.6)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 12)

                Text("iOS will ask permission next. OneAlarm needs it to set a real system alarm, which is the only kind that rings through Silent mode and a Focus.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.grey)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 26)

                VStack(spacing: 0) {
                    promise("Rings on Silent and through Focus")
                    promise("Shows on the Lock Screen and Dynamic Island")
                    promise("Lands on your Apple Watch automatically")
                    promise("Works with no accounts connected at all")
                }
                .padding(.vertical, 4)
                .themeCard()
            }
        } footer: {
            SolidButton(title: "Allow alarms") {
                Task {
                    let granted = await store.alarmKit.requestAuthorization()
                    await store.refreshAuthStates()
                    if granted { onFinished() } else { denied = true }
                }
            }
            QuietButton(title: "Not now") { onFinished() }
        }
    }

    private func promise(_ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Theme.State.confirmed.opacity(0.15), in: Circle())
                .foregroundStyle(Theme.State.confirmed)
            Text(text).font(.system(size: 14, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
    }

    // MARK: Denied

    private var permissionDenied: some View {
        Screen(title: "Alarm permission") {
            VStack(alignment: .leading, spacing: 18) {
                Notice(.bad, title: "Alarms are turned off for OneAlarm.",
                       "Without this the app can still show you the plan, but nothing will ring.")

                Text("Turning it back on").font(.system(size: 20, weight: .semibold))

                VStack(spacing: 0) {
                    numberedStep(1, "Open Settings")
                    numberedStep(2, "Tap Apps, then OneAlarm")
                    numberedStep(3, "Turn on Alarms")
                }
                .padding(.vertical, 4)
                .themeCard()
            }
            .padding(.top, 8)
        } footer: {
            SolidButton(title: "Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            QuietButton(title: "Later") { onFinished() }
        }
    }

    private func numberedStep(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(n)")
                .font(Theme.numeral(13))
                .frame(width: 26, height: 26)
                .background(Theme.cardLift, in: RoundedRectangle(cornerRadius: 8))
            Text(text).font(.system(size: 14, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
    }
}
