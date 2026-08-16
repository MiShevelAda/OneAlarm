import SwiftUI

/// The hub, reachable from onboarding and from the home screen, so it is not a wizard step.
@MainActor
struct ConnectionsHubView: View {
    @Environment(ScheduleStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var linking: DeviceID?

    var body: some View {
        Screen(title: "Connections", onBack: { dismiss() }) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Link your devices").font(.system(size: 26, weight: .bold)).tracking(-0.6)
                    Text("Both are optional. The iPhone alarm already works.")
                        .font(.system(size: 15)).foregroundStyle(Theme.grey)
                }
                .padding(.top, 4)

                VStack(spacing: 0) {
                    row(.iphone)
                    Divider().overlay(Theme.line).padding(.leading, 62)
                    row(.eightSleep)
                    Divider().overlay(Theme.line).padding(.leading, 62)
                    row(.whoop)
                }
                .themeCard()

                Text("Passwords are kept in the iPhone Keychain, tied to this device. They are never backed up and never copied to another phone.")
                    .font(.system(size: 13)).foregroundStyle(Theme.greyDim)
            }
            .padding(.bottom, 20)
        } footer: {
            SolidButton(title: "Done") { dismiss() }
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
    }

    private func row(_ device: DeviceID) -> some View {
        Button {
            guard device != .iphone else { return }
            linking = device
        } label: {
            HStack(spacing: 13) {
                Image(systemName: device.symbolName)
                    .font(.system(size: 17))
                    .frame(width: 40, height: 40)
                    .background(Theme.cardLift, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                    .foregroundStyle(Theme.Ramp.lit(for: device))

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName).font(.system(size: 15, weight: .semibold))
                    Text(subtitle(for: device)).font(.system(size: 13)).foregroundStyle(Theme.grey)
                }
                Spacer(minLength: 8)
                trailing(for: device)
            }
            .padding(.horizontal, 15).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(for device: DeviceID) -> String {
        switch device {
        case .iphone: return "No account needed"
        case .eightSleep: return "Warms the bed before you wake"
        case .whoop: return "Haptic wake window"
        }
    }

    @ViewBuilder
    private func trailing(for device: DeviceID) -> some View {
        switch store.authStates[device] ?? .notConfigured {
        case .connected:
            StatePill(text: device == .iphone ? "Ready" : "Linked", color: Theme.State.confirmed)
        case .needsReauth:
            StatePill(text: "Attention", color: Theme.State.unconfirmed)
        case .notConfigured:
            if device == .iphone {
                StatePill(text: "Not allowed", color: Theme.State.unconfirmed)
            } else {
                Text("Connect ›").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.grey)
            }
        }
    }
}

// MARK: Eight Sleep

@MainActor
struct EightSleepLinkView: View {
    @Environment(ScheduleStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Stage { case prerequisite, credentials, working, choose, blocked, done }

    @State private var stage: Stage = .prerequisite
    @State private var email = ""
    @State private var password = ""
    @State private var result = ""
    @State private var failure: String?
    @State private var choices: [RemoteAlarmChoice] = []

    var body: some View {
        Group {
            switch stage {
            case .prerequisite: prerequisite
            case .credentials: credentials
            case .working: working
            case .choose: picker
            case .blocked: blocked
            case .done: done
            }
        }
        .task {
            guard store.authStates[.eightSleep] == .connected else { return }
            let found = (try? await store.eightSleep.availableAlarms()) ?? []
            if !found.isEmpty {
                choices = found
                stage = .choose
            }
        }
    }

    private var prerequisite: some View {
        Screen(title: "Eight Sleep", onBack: { dismiss() }) {
            VStack(alignment: .leading, spacing: 18) {
                StepDots(total: 3, current: 0).frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Before you start").themeLabel(.white)
                    Text("You need one alarm in the Eight Sleep app")
                        .font(.system(size: 21, weight: .semibold)).tracking(-0.4)
                    Text("Any time. OneAlarm will move it.")
                        .font(.system(size: 15)).foregroundStyle(.white.opacity(0.82))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Theme.Ramp.card(for: .eightSleep),
                            in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))

                Text("Why it works this way").font(.system(size: 19, weight: .semibold))
                Text("OneAlarm changes the alarm you already have rather than creating a new one. That keeps your vibration, thermal and level settings exactly as you set them, because it never has to guess what they should be.")
                    .font(.system(size: 15)).foregroundStyle(Theme.grey)

                Notice("Open the Eight Sleep app, make sure one alarm exists, then come back.")
            }
        } footer: {
            SolidButton(title: "I have an alarm set") { stage = .credentials }
            QuietButton(title: "Not yet") { dismiss() }
        }
    }

    private var credentials: some View {
        Screen(title: "Eight Sleep", onBack: { stage = .prerequisite }) {
            VStack(alignment: .leading, spacing: 14) {
                StepDots(total: 3, current: 1).frame(maxWidth: .infinity)

                Text("Sign in to Eight Sleep").font(.system(size: 26, weight: .bold)).tracking(-0.6)
                Text("The same email and password you use in their app.")
                    .font(.system(size: 15)).foregroundStyle(Theme.grey)

                CredentialField(placeholder: "Email", text: $email, secure: false)
                CredentialField(placeholder: "Password", text: $password, secure: true)

                if let failure { Notice(.bad, failure) }

                Notice(title: "Why a password and not a login button.",
                       "Eight Sleep has no official way for other apps to connect, and issues nothing that can be refreshed. The password stays in this phone's Keychain and is sent only to Eight Sleep.")
            }
        } footer: {
            SolidButton(title: "Connect", enabled: !email.isEmpty && !password.isEmpty) {
                failure = nil
                stage = .working
                Task { await connect() }
            }
        }
    }

    private var working: some View {
        Screen(title: "Eight Sleep") {
            VStack(spacing: 18) {
                StepDots(total: 3, current: 2)
                VStack(spacing: 0) {
                    progressRow("Signed in", done: true)
                    progressRow("Looking for your alarm", done: false, detail: "Checking the subscription too")
                }
                .padding(.vertical, 4)
                .themeCard()

                Text("Signing in only proves the password. This checks the leg will actually work at six in the morning.")
                    .font(.system(size: 14)).foregroundStyle(Theme.grey)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 10)
        }
    }

    private var done: some View {
        Screen(title: "Eight Sleep") {
            VStack(spacing: 16) {
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .bold))
                    .frame(width: 70, height: 70)
                    .background(Theme.State.confirmed.opacity(0.14), in: Circle())
                    .foregroundStyle(Theme.State.confirmed)
                    .padding(.top, 40)

                Text("Eight Sleep is linked").font(.system(size: 26, weight: .bold)).tracking(-0.6)
                Text(result).font(.system(size: 15)).foregroundStyle(Theme.grey)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Left exactly as you set it").themeLabel(.white)
                    Text("Your vibration, pattern and thermal settings are read from the server and sent back untouched.")
                        .font(.system(size: 14)).foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Theme.Ramp.card(for: .eightSleep),
                            in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
                .padding(.top, 8)
            }
        } footer: {
            SolidButton(title: "Done") { dismiss() }
        }
    }

    /// Shown when the account holds more than one alarm.
    private var picker: some View {
        AlarmPickerScreen(device: .eightSleep, choices: choices) { _ in
            stage = .working
            Task { await finish() }
        } onBack: {
            dismiss()
        } onDisconnect: {
            Task {
                await store.eightSleep.signOut()
                RemoteAlarmSelection.select(nil, for: .eightSleep)
                await store.refreshAuthStates()
                dismiss()
            }
        }
    }

    private func connect() async {
        do {
            try await store.eightSleep.signIn(email: email, password: password)
            password = ""
            await finish()
        } catch {
            failure = (error as? AdapterError)?.errorDescription ?? error.localizedDescription
            stage = .credentials
        }
        await store.refreshAuthStates()
    }

    /// Signing in only proves the password. This proves the leg will actually work, and asks which
    /// alarm to move when the answer is genuinely ambiguous.
    private func finish() async {
        do {
            result = try await store.eightSleep.readiness()
            stage = .done
        } catch AdapterError.alarmChoiceNeeded {
            choices = (try? await store.eightSleep.availableAlarms()) ?? []
            stage = choices.isEmpty ? .blocked : .choose
        } catch AdapterError.authenticationFailed(let detail) {
            // The password genuinely is the problem, so the password field is the right place.
            failure = AdapterError.authenticationFailed(detail).errorDescription
            stage = .credentials
        } catch {
            // Signed in fine. An inactive subscription or a missing alarm is not a typo.
            failure = (error as? AdapterError)?.errorDescription ?? error.localizedDescription
            stage = .blocked
        }
        await store.refreshAuthStates()
    }

    /// Signed in, but something on the Eight Sleep side still needs doing.
    private var blocked: some View {
        Screen(title: "Eight Sleep", onBack: { dismiss() }) {
            VStack(spacing: 16) {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .bold))
                    .frame(width: 56, height: 56)
                    .background(Theme.State.confirmed.opacity(0.14), in: Circle())
                    .foregroundStyle(Theme.State.confirmed)
                    .padding(.top, 34)

                Text("You are signed in to Eight Sleep")
                    .font(.system(size: 24, weight: .bold)).tracking(-0.6)
                    .multilineTextAlignment(.center)

                Notice(.warn, title: "One thing left, in the Eight Sleep app.", failure ?? "")

                Notice("Your phone alarm is unaffected and will still ring.")
            }
        } footer: {
            SolidButton(title: "I have fixed it, check again") {
                Task { await finish() }
            }
            QuietButton(title: "Leave it for now") { dismiss() }
        }
    }
}

// MARK: Whoop

@MainActor
struct WhoopLinkView: View {
    @Environment(ScheduleStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Stage { case warning, credentials, code, choose, blocked, done }

    @State private var stage: Stage = .warning
    @State private var email = ""
    @State private var password = ""
    @State private var codeText = ""
    @State private var prompt = ""
    @State private var result = ""
    @State private var failure: String?
    @State private var busy = false
    @State private var choices: [RemoteAlarmChoice] = []
    /// Held here so confirming the code cannot depend on the adapter still remembering it.
    @State private var challenge: WhoopAdapter.Challenge?

    var body: some View {
        Group {
            switch stage {
            case .warning: warning
            case .credentials: credentials
            case .code: code
            case .choose: picker
            case .blocked: blocked
            case .done: done
            }
        }
        // Re-opening an already linked device should land on the choice, not on a sign in screen
        // for an account that is already signed in. The picker promises this is changeable later,
        // so it has to actually be reachable.
        .task {
            guard store.authStates[.whoop] == .connected else { return }
            let found = (try? await store.whoop.availableAlarms()) ?? []
            if !found.isEmpty {
                choices = found
                stage = .choose
            }
        }
    }

    /// This is a decision, not a step, so it gets a screen. Whoop's terms genuinely allow them to
    /// act against the account, and that belongs before the password field rather than after.
    private var warning: some View {
        Screen(title: "Whoop", onBack: { dismiss() }) {
            VStack(alignment: .leading, spacing: 16) {
                StepDots(total: 4, current: 0).frame(maxWidth: .infinity)

                Text("Read this before linking Whoop")
                    .font(.system(size: 26, weight: .bold)).tracking(-0.6)
                Text("This one is different from the other two, and you should decide with the facts.")
                    .font(.system(size: 15)).foregroundStyle(Theme.grey)

                VStack(spacing: 0) {
                    caveat(Theme.State.failed, "Whoop offers no official way in",
                           "OneAlarm uses the same private service their own app uses. Their terms let them act against an account doing this. Realistically that means your membership.")
                    caveat(Theme.State.unconfirmed, "You will sign in again about monthly",
                           "Their login expires roughly every thirty days and there is no way to warn you before it does.")
                    caveat(Theme.State.unconfirmed, "Keep the Whoop app installed",
                           "OneAlarm changes the alarm on Whoop's servers. Their app is what carries it to the band on your wrist.")
                }
                .padding(.vertical, 4)
                .themeCard()

                Notice("Your bed and your phone do not depend on this. Skipping Whoop costs you one nudge, nothing else.")
            }
        } footer: {
            GhostButton(title: "I understand, link Whoop") { stage = .credentials }
            QuietButton(title: "Skip Whoop") { dismiss() }
        }
    }

    private func caveat(_ color: Color, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(color).frame(width: 7, height: 7).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(body).font(.system(size: 13)).foregroundStyle(Theme.grey)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15).padding(.vertical, 11)
    }

    private var credentials: some View {
        Screen(title: "Whoop", onBack: { stage = .warning }) {
            VStack(alignment: .leading, spacing: 14) {
                StepDots(total: 4, current: 1).frame(maxWidth: .infinity)
                Text("Sign in to Whoop").font(.system(size: 26, weight: .bold)).tracking(-0.6)
                Text("Whoop will text you a code straight after.")
                    .font(.system(size: 15)).foregroundStyle(Theme.grey)

                CredentialField(placeholder: "Email", text: $email, secure: false)
                CredentialField(placeholder: "Password", text: $password, secure: true)

                if let failure { Notice(.bad, failure) }

                Notice(title: "Your Whoop password is not kept.",
                       "Once the code is confirmed, OneAlarm stores only the renewable token Whoop hands back, and forgets the password.")
            }
        } footer: {
            SolidButton(title: "Send me a code", busy: busy,
                        enabled: !email.isEmpty && !password.isEmpty) {
                failure = nil
                Task { await signIn() }
            }
        }
    }

    private var code: some View {
        Screen(title: "Whoop", onBack: { stage = .credentials }) {
            VStack(spacing: 16) {
                StepDots(total: 4, current: 2)
                // Deliberately not "texted": Whoop sends this by SMS, email or an authenticator
                // app depending on the account, and `prompt` says which.
                Text("Enter your Whoop code")
                    .font(.system(size: 25, weight: .bold)).tracking(-0.6)
                    .multilineTextAlignment(.center)
                Text(prompt.isEmpty ? "It expires in about three minutes." : prompt)
                    .font(.system(size: 15)).foregroundStyle(Theme.grey)
                    .multilineTextAlignment(.center)

                TextField("", text: $codeText)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(Theme.numeral(30))
                    .padding(.vertical, 14)
                    .background(Theme.cardLift, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                    .padding(.top, 8)

                if let failure { Notice(.bad, failure) }
            }
            .padding(.top, 8)
        } footer: {
            SolidButton(title: "Confirm", busy: busy, enabled: codeText.count >= 4) {
                failure = nil
                Task { await confirm() }
            }
            // Codes expire in about three minutes, and fetching one means leaving the app, so
            // needing a fresh one is routine rather than a failure.
            QuietButton(title: "Send a new code") {
                failure = nil
                codeText = ""
                // Requests a fresh code with the credentials already held, rather than sending the
                // user back to retype a password they just entered.
                if password.isEmpty {
                    stage = .credentials
                } else {
                    Task { await signIn() }
                }
            }
        }
    }

    private var done: some View {
        Screen(title: "Whoop") {
            VStack(spacing: 16) {
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .bold))
                    .frame(width: 70, height: 70)
                    .background(Theme.State.confirmed.opacity(0.14), in: Circle())
                    .foregroundStyle(Theme.State.confirmed)
                    .padding(.top, 40)

                Text("Whoop is linked").font(.system(size: 26, weight: .bold)).tracking(-0.6)
                Text(result).font(.system(size: 15)).foregroundStyle(Theme.grey)
                    .multilineTextAlignment(.center)

                Notice(.warn, title: "Set a reminder for about a month from now.",
                       "Whoop's login will expire and OneAlarm cannot warn you in advance.")
                    .padding(.top, 8)
            }
        } footer: {
            SolidButton(title: "Done") { dismiss() }
        }
    }

    private func signIn() async {
        busy = true
        do {
            // One attempt. Never a retry loop: repeated failures rate limit the auth endpoint.
            switch try await store.whoop.signIn(email: email, password: password) {
            case .signedIn:
                // Only now is the password genuinely finished with.
                password = ""
                await finish()
            case .needsCode(let issued):
                // Deliberately kept until the challenge is answered, so Send a new code can
                // actually send one instead of demanding the password be retyped.
                challenge = issued
                prompt = issued.prompt
                stage = .code
            }
        } catch {
            failure = (error as? AdapterError)?.errorDescription ?? error.localizedDescription
        }
        await store.refreshAuthStates()
        busy = false
    }

    private var picker: some View {
        AlarmPickerScreen(device: .whoop, choices: choices) { _ in
            Task { await finish() }
        } onBack: {
            dismiss()
        } onDisconnect: {
            Task {
                await store.whoop.signOut()
                RemoteAlarmSelection.select(nil, for: .whoop)
                await store.refreshAuthStates()
                dismiss()
            }
        }
    }

    private func finish() async {
        do {
            result = try await store.whoop.readiness()
            stage = .done
        } catch AdapterError.alarmChoiceNeeded {
            choices = (try? await store.whoop.availableAlarms()) ?? []
            stage = choices.isEmpty ? .blocked : .choose
        } catch {
            // Signed in already. Whatever went wrong here is not the password, so do not dump the
            // user back on a credentials or code field as though they typed something wrong.
            failure = (error as? AdapterError)?.errorDescription ?? error.localizedDescription
            stage = .blocked
        }
        await store.refreshAuthStates()
    }

    /// Signed in, but something on the Whoop side still needs doing.
    private var blocked: some View {
        Screen(title: "Whoop", onBack: { dismiss() }) {
            VStack(spacing: 16) {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .bold))
                    .frame(width: 56, height: 56)
                    .background(Theme.State.confirmed.opacity(0.14), in: Circle())
                    .foregroundStyle(Theme.State.confirmed)
                    .padding(.top, 34)

                Text("You are signed in to Whoop")
                    .font(.system(size: 24, weight: .bold)).tracking(-0.6)
                    .multilineTextAlignment(.center)

                Notice(.warn, title: "One thing left, in the Whoop app.", failure ?? "")

                Notice("Your bed and your phone are unaffected and will still be set.")
            }
        } footer: {
            SolidButton(title: "I have fixed it, check again", busy: busy) {
                busy = true
                Task { await finish(); busy = false }
            }
            QuietButton(title: "Leave it for now") { dismiss() }
        }
    }

    private func confirm() async {
        busy = true
        do {
            try await store.whoop.submitCode(codeText, using: challenge)
            // The challenge is answered, so neither of these is needed any longer.
            password = ""
            challenge = nil
            codeText = ""
            await finish()
        } catch {
            failure = (error as? AdapterError)?.errorDescription ?? error.localizedDescription
        }
        await store.refreshAuthStates()
        busy = false
    }
}

// MARK: Shared

@MainActor
private struct CredentialField: View {
    let placeholder: String
    @Binding var text: String
    let secure: Bool

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text).textContentType(.password)
            } else {
                TextField(placeholder, text: $text)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .font(.system(size: 16))
        .padding(15)
        .background(Theme.cardLift, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

@MainActor
private func progressRow(_ title: String, done: Bool, detail: String? = nil) -> some View {
    HStack(spacing: 12) {
        if done {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Theme.State.confirmed.opacity(0.15), in: Circle())
                .foregroundStyle(Theme.State.confirmed)
        } else {
            ProgressView().scaleEffect(0.7).frame(width: 22, height: 22).tint(Theme.grey)
        }
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14, weight: .medium))
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.greyDim) }
        }
        Spacer()
    }
    .padding(.horizontal, 15).padding(.vertical, 11)
}

// MARK: Alarm picker

/// Shown when an account holds more than one alarm.
///
/// Neither service labels an alarm with a device or a room, so these are identified by time and
/// days, which is the only honest thing the data supports. The choice is remembered, and if the
/// chosen alarm later disappears the app asks again rather than quietly moving a different one.
@MainActor
struct AlarmPickerScreen: View {
    let device: DeviceID
    let choices: [RemoteAlarmChoice]
    let onPick: (RemoteAlarmChoice) -> Void
    let onBack: () -> Void
    let onDisconnect: () -> Void

    @State private var selected: String? = nil

    var body: some View {
        Screen(title: device.displayName, onBack: onBack) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Which alarm should OneAlarm move?")
                        .font(.system(size: 25, weight: .bold)).tracking(-0.6)
                    Text("This account has \(choices.count). OneAlarm changes one of them and leaves the rest alone.")
                        .font(.system(size: 15)).foregroundStyle(Theme.grey)
                }
                .padding(.top, 4)

                ForEach(Array(choices.byGroup.enumerated()), id: \.offset) { _, group in
                  VStack(alignment: .leading, spacing: 9) {
                    // The bed's own name, when the service gives one. Two alarms at the same time on
                    // two different pods are otherwise identical on screen, and picking the wrong
                    // one moves the wrong bed with no symptom until somebody does not wake up.
                    if let name = group.name {
                        Text(name)
                            .font(.system(size: 11, weight: .bold)).tracking(1.4)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.grey)
                            .padding(.top, 6)
                    }
                    ForEach(group.choices) { choice in
                        Button {
                            selected = choice.id
                        } label: {
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Theme.Ramp.rail(for: device))
                                    .frame(width: 3)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(choice.timeLabel).font(Theme.numeral(28))
                                    Text(choice.daysLabel)
                                        .font(.system(size: 13)).foregroundStyle(Theme.grey)
                                    if let detail = choice.detail, !detail.isEmpty {
                                        Text(detail)
                                            .font(.system(size: 12)).foregroundStyle(Theme.greyDim)
                                    }
                                    if !choice.isEnabled {
                                        Text("Currently off")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Theme.State.unconfirmed)
                                    }
                                }

                                Spacer(minLength: 8)

                                Image(systemName: selected == choice.id ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 21))
                                    .foregroundStyle(selected == choice.id ? Theme.State.confirmed : Theme.greyDim)
                            }
                            .padding(15)
                            .frame(minHeight: 76)
                            .background(
                                selected == choice.id
                                    ? AnyShapeStyle(Theme.Ramp.card(for: device))
                                    : AnyShapeStyle(Theme.card),
                                in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                                    .strokeBorder(
                                        selected == choice.id ? Theme.State.confirmed.opacity(0.5) : Theme.line,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                  }
                }

                if let unparsed = choices.first(where: { !$0.parsedCleanly }) {
                    Notice(.warn,
                           title: "This account returned a shape OneAlarm did not recognise.",
                           "Fields returned: " + unparsed.rawKeys.joined(separator: ", "))
                } else if choices.contains(where: { $0.group == nil }), let sample = choices.first {
                    // Shown when the parse SUCCEEDED but no name was found, which is the only way to
                    // tell "this service does not name its alarms" apart from "we looked in the
                    // wrong place". A diagnostic that appears only on failure cannot answer that,
                    // because the parse succeeds either way. Field names from an alarm schedule,
                    // never a credential.
                    Notice(.warn,
                           title: "This account did not name its beds.",
                           "Eight Sleep does not put a bed or a side on an alarm, so these are listed by time. To be certain which is which, open the Eight Sleep app and compare the times.\n\nWhat this account returned: "
                               + sample.rawKeys.joined(separator: ", "))
                }

                Notice("You can change this later from Connections. Nothing else on the account is touched.")

                // There was no way to sign out of anything. `signOut()` has existed on both
                // adapters since the first build and no screen ever called it, so the only way off
                // an account was deleting the app.
                Button {
                    onDisconnect()
                } label: {
                    Text("Disconnect this account")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.State.failed)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)

                Notice("Disconnecting forgets the password on this phone and stops OneAlarm writing. It does not change or delete the alarm itself, which stays exactly where it is now.")
            }
            .padding(.bottom, 20)
        } footer: {
            SolidButton(title: "Use this alarm", enabled: selected != nil) {
                guard let id = selected, let choice = choices.first(where: { $0.id == id }) else { return }
                RemoteAlarmSelection.select(id, for: device)
                onPick(choice)
            }
            QuietButton(title: "Leave it as it is", action: onBack)
        }
        .onAppear {
            // Only when the account holds one alarm, or when a choice was already made. Otherwise
            // a highlighted row is a recommendation the app cannot justify, and it turns a fresh
            // decision into the confirmation of a guess.
            selected = choices.count == 1
                ? choices.first?.id
                : RemoteAlarmSelection.selected(for: device)
        }
    }
}
