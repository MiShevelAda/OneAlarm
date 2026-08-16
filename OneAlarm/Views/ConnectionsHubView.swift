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

                // Which build this is. Three rounds in a row opened with "is the code you are
                // running the code I pushed", and there was no way to answer it from the phone.
                VStack(alignment: .leading, spacing: 3) {
                    Text("BUILD").themeLabel()
                    Text(Build.marker)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.grey)
                        .textSelection(.enabled)
                    Text(Build.whatIsNew)
                        .font(.system(size: 12)).foregroundStyle(Theme.greyDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
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
        case .eightSleep: return "Time only. Vibration and thermal stay yours"
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
                    Text("You need at least one alarm in the Eight Sleep app")
                        .font(.system(size: 21, weight: .semibold)).tracking(-0.4)
                    Text("Any time, any days. OneAlarm copies its vibration and thermal settings when it makes the others.")
                        .font(.system(size: 15)).foregroundStyle(.white.opacity(0.82))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Theme.Ramp.card(for: .eightSleep),
                            in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))

                Text("Why it works this way").font(.system(size: 19, weight: .semibold))
                Text("Each of your routines drives one alarm on your bed. OneAlarm sets its time, its days and whether it is on, and makes one if a routine has none. Temperature, vibration, level and pattern are read from Eight Sleep and handed straight back untouched, because it never has to guess what they should be. Alarms you made yourself are never deleted. If you delete a routine here, the alarm OneAlarm made for it goes too.")
                    .font(.system(size: 15)).foregroundStyle(Theme.grey)

                Notice("One is enough. OneAlarm creates the rest from it, one per routine, rather than asking you to build them by hand.")
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
                    Text("Days, vibration, pattern, thermal and the on switch are read from the server and sent back untouched. The only field OneAlarm ever writes is the time.")
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

    /// What the account holds, and which routine drives which alarm. Read only.
    ///
    /// Was a picker. Nothing is chosen here any more: the routines match themselves to the alarms
    /// that already have their days, so the only thing left to confirm is the bed.
    private var picker: some View {
        BedConfirmScreen(choices: choices) {
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

    /// Signing in only proves the password. This proves the leg will actually work: an active
    /// subscription, at least one alarm, and at least one routine whose days an alarm here carries.
    private func finish() async {
        do {
            result = try await store.eightSleep.readiness(against: store.plans[.eightSleep])
            stage = .done
        } catch AdapterError.noMatchingDays {
            // Not a failure and not a question either. Show the account, say which routine has no
            // alarm to drive, and let him decide whether to add one in the Eight Sleep app.
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
    /// The `/schedule/all` envelope, printed on the linked screen. See `whoopTruth`.
    @State private var envelope: [String] = []

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

                whoopTruth
            }
        } footer: {
            SolidButton(title: "Done") { dismiss() }
        }
        .task {
            envelope = await store.whoop.envelopeDump()
        }
    }

    /// The whole Whoop alarm screen as the server describes it, printed rather than parsed.
    ///
    /// **Added 17 August, for a question OneAlarm cannot answer by reasoning.** Alex deleted every
    /// schedule on his Whoop account. OneAlarm moves schedules and does not create them, so with zero
    /// of them there is nothing it can do, and Whoop's own `CREATE SCHEDULE` button did nothing
    /// either. He asked whether there is a way around it.
    ///
    /// `docs/RESEARCH.md` §2.3 says this endpoint is a **rendered screen** rather than a resource,
    /// and that its top level carries `schedule_button_component`, which is Whoop's own description of
    /// the very button he is pressing. With the account empty it is rendering the create screen, so
    /// what that button does is more likely to be described in there than anywhere we could reason
    /// our way to.
    ///
    /// This is the one method that has ever worked on this service. Six rounds of reasoning produced
    /// six wrong answers and cost five hours; both breakthroughs came from printing the response.
    /// Nothing here is inferred and nothing is written.
    @ViewBuilder
    private var whoopTruth: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text(envelope.isEmpty ? "Nothing read yet." : envelope.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.greyDim)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            Text("Your Whoop alarm screen, raw")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.grey)
        }
        .tint(Theme.grey)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
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
        AlarmPickerScreen(device: .whoop, choices: choices) { choice in
            // **His tap is ownership, and that is the third way a routine can come to own a schedule.**
            //
            // The matcher adopts only on exact day equality, never a subset, because writing days to
            // an alarm nobody established was ours is what turned his real Monday to Friday schedule
            // into every day. Correct, and on 17 August it stranded him: his Weekend routine covers
            // Saturday and Sunday, the Whoop schedule he made covered Saturday alone, so nothing
            // matched. On Eight Sleep that is harmless because a routine with no alarm gets one made.
            // Whoop cannot create, so the routine had nowhere to go and Sunday never arrived.
            //
            // Until now this closure discarded the choice entirely, `{ _ in }`, while the button said
            // "Use this alarm". Choosing here now records the link, which is the same standing as an
            // exact day match: safe for the reason the other two are, which is that he said so.
            //
            // Only a routine whose days **contain** the schedule's, and which owns nothing yet, so a
            // tap can never take a schedule away from a routine that already has one. Falls back to
            // the old single-schedule selection when nothing fits, rather than silently doing nothing.
            if !choice.weekdays.isEmpty,
               let routine = store.plans[.whoop]?.entries.first(where: {
                   $0.weekdays.isSuperset(of: choice.weekdays)
                       && RemoteAlarmLink.alarmID(for: $0.routineID, on: .whoop) == nil
               }) {
                RemoteAlarmLink.link(routine: routine.routineID, to: choice.id, on: .whoop)
            } else {
                RemoteAlarmSelection.select(choice.id, for: .whoop)
            }
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

// MARK: Bed confirmation

/// The Eight Sleep screen that replaced the alarm picker.
///
/// Alex, 2026-08-16: *"I shouldn't actually pick routines... So what I should be able to pick is
/// just the bed, and I should not pick a routine. This doesn't make sense to me. This should only
/// be done in the background."*
///
/// He is right on both halves. Picking one alarm out of a list was the app asking him to answer a
/// question it had created for itself, and the answer could not be right: one alarm cannot carry two
/// routines, so every time the week turned over the app rewrote the chosen alarm's **days**. The bed
/// is the only thing on this account that is genuinely ambiguous, so it is the only thing he is
/// asked about.
///
/// What is left is a statement, not a question. It shows which alarm each routine will drive, which
/// routines have no alarm to drive, and which alarms OneAlarm will never touch. Nothing on it is
/// selectable, because there is nothing left to select.
@MainActor
struct BedConfirmScreen: View {
    let choices: [RemoteAlarmChoice]
    let onConfirm: () -> Void
    let onBack: () -> Void
    let onDisconnect: () -> Void

    @Environment(ScheduleStore.self) private var store

    @State private var bed: EightSleepAdapter.BedIdentity?
    @State private var routines: [String] = []
    /// Alarms OneAlarm made before 17 August that his own app will not show him.
    @State private var confirmingSilence = false
    @State private var silenceResult: [String] = []
    @State private var isSilencing = false

    private var matchReport: AlarmMatchReport {
        guard let plan = store.plans[.eightSleep], !plan.entries.isEmpty else {
            return AlarmMatchReport()
        }
        // The same links the write uses. A screen that matched by days while the write matched by
        // recorded ownership would draw a picture of a different account.
        return RoutinePlan.match(
            entries: plan.entries,
            // Hidden alarms are excluded here too, and this is the same rule as the line above rather
            // than a new one. The write stopped considering them on 17 August; a screen that still
            // did would list them as "no routine has these days", which is false for both of the ones
            // on his account and reads as a settled explanation.
            against: choices.filter { !$0.isHidden }.map(\.candidate),
            links: RemoteAlarmLink.all(for: .eightSleep)
        )
    }

    var body: some View {
        let report = matchReport
        return Screen(title: "Eight Sleep", onBack: onBack) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(bed?.label.map { "You are on \($0)" } ?? "Your bed")
                        .font(.system(size: 25, weight: .bold)).tracking(-0.6)
                    Text("Each of your routines drives one alarm on this bed. OneAlarm sets its time, its days and whether it is on, and creates one if a routine has none. You do not pick an alarm.")
                        .font(.system(size: 15)).foregroundStyle(Theme.grey)
                }
                .padding(.top, 4)

                if let bed, bed.deviceCount > 1 {
                    Notice(title: "This account has \(bed.deviceCount) Pods and one shared list of alarms.",
                           "Alarms belong to the account rather than to a bed, and they fire on whichever Pod you are currently assigned to. Move yourself in the Eight Sleep app to change that.")
                } else if bed?.label == nil {
                    Notice(.warn, title: "This account did not name a bed.",
                           "The matching below still works: it goes by days, not by names. Only the heading is missing.")
                }

                matchRows(report)

                if !report.routinesWithNoAlarm.isEmpty {
                    // Says what OneAlarm will do, not what he should do.
                    //
                    // This used to read "Add one in the Eight Sleep app with those days", which was
                    // true until this evening and is the precise thing he asked to stop doing:
                    // *"the OneAlarm app should also write the new alarm sequence into the Eight
                    // Sleep app, and I shouldn't do it manually."* The app creates it now, and a
                    // screen still sending him to do it by hand is the app failing at its one job
                    // and then telling him it is his problem.
                    Notice(title: "No alarm here runs on \(report.routinesWithNoAlarm.joined(separator: " or ")) yet.",
                           "OneAlarm makes one on the next Set all alarms, inside the routine that already runs on those days, copying the vibration and thermal settings from an alarm you already have. It never reshapes an existing alarm's days to fit, because that would move a morning you did not ask it to move.")
                }

                Notice(title: "OneAlarm owns the when. Eight Sleep owns the how.",
                       "Times, days and the on switch come from your routines here and are written to your bed. Temperature, vibration, level and pattern are read from Eight Sleep and handed straight back untouched, so set those in their app. Any alarm OneAlarm has not taken over is never touched at all.")

                silenceRetired

                serverTruth
                routineTruth

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

                Notice("Disconnecting forgets the password on this phone and stops OneAlarm writing. It does not change or delete any alarm, which all stay exactly where they are now.")
            }
            .padding(.bottom, 20)
        } footer: {
            SolidButton(title: "This is my bed", action: onConfirm)
            QuietButton(title: "Leave it as it is", action: onBack)
        }
        .task {
            // A label. It never blocks and it never fails loudly: `currentBed` returns nil rather
            // than throwing, because a bed whose name cannot be fetched must not take an alarm
            // down with it.
            bed = await store.eightSleep.currentBed()
            routines = await store.eightSleep.routineDump()
        }
    }

    /// What Eight Sleep's server returns for each alarm, verbatim, right now.
    ///
    /// Alex, 2026-08-16: *"it seems not to write the Eight Sleep alarms... it still seems not to
    /// write this inside the Eight Sleep app."* Two different claims are hiding in that sentence:
    /// the write did not land, and their app is not showing what landed. The whole project rule is
    /// that when those two are confused, the next action is a dump rather than a hypothesis, and
    /// this is the dump. If `time` here reads back as the time OneAlarm sent, the write landed and
    /// the question moves to their app. If it does not, the question is ours.
    ///
    /// Not hidden behind a failure. A diagnostic that only appears when parsing breaks cannot answer
    /// a question about a parse that succeeded, which has cost this project two answers already.
    @ViewBuilder
    private var serverTruth: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(choices) { choice in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(choice.summary)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.grey)
                        Text(choice.rawKeys.filter { $0.contains(" = ") }.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.greyDim)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("What Eight Sleep returns right now")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.grey)
        }
        .tint(Theme.grey)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
    }

    /// His Eight Sleep **routines**, verbatim.
    ///
    /// Alex asked to *"write routines inside the 8sleep app"*, and until today this project did not
    /// know their app had routines as an object at all. It does: a routine carries days, a bedtime,
    /// an enabled flag and its alarms, and every alarm's `tags` points back at one. That is almost
    /// certainly why an alarm OneAlarm creates on its own never appears in their app.
    ///
    /// Nothing is written to a routine yet. This prints his, so the next step is built against his
    /// account rather than against somebody else's capture.
    /// Switch off the alarms OneAlarm made that his own app will not show him.
    ///
    /// **The only destructive-ish thing in this app, and it exists because this app caused the
    /// problem.** Before 17 August every alarm OneAlarm created carried a copied `oneOff-napMode`
    /// tag, so the Eight Sleep app filtered it out. Two of them are on his account, both enabled,
    /// both ringing minutes after his real alarm at full vibration. He cannot switch them off in the
    /// Eight Sleep app because it does not list them. OneAlarm will not delete them either: deleting
    /// reaches only alarms it recorded creating, and these predate that record.
    ///
    /// Off, not deleted: time, days, temperature and vibration all survive. Alex asked for it on
    /// 17 August, in one word: *"yes"*.
    ///
    /// The button appears only when there is something to switch off, and disappears once there is
    /// not, so a solved problem stops taking up space on the screen.
    @ViewBuilder
    private var silenceRetired: some View {
        let retired = choices.filter { $0.isHidden && !$0.weekdays.isEmpty && $0.isEnabled }
        if !retired.isEmpty || !silenceResult.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !silenceResult.isEmpty {
                    Text(silenceResult.joined(separator: "\n"))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.State.confirmed)
                } else {
                    Notice(.warn, title: "\(retired.count) alarm\(retired.count == 1 ? "" : "s") here will ring and you cannot see \(retired.count == 1 ? "it" : "them").",
                           "OneAlarm made \(retired.count == 1 ? "it" : "them") before 17 August and left a nap tag on \(retired.count == 1 ? "it" : "them"), which is why the Eight Sleep app does not list \(retired.count == 1 ? "it" : "them"). Switching \(retired.count == 1 ? "it" : "them") off is the only fix, because there is nothing to tap in their app and OneAlarm never deletes anything.")

                    Button {
                        confirmingSilence = true
                    } label: {
                        Text(isSilencing ? "Switching off..." : "Switch \(retired.count == 1 ? "it" : "them") off")
                            .font(.system(size: 15, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Theme.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.lineStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSilencing)
                }
            }
            // Names every alarm it will touch, because the whole problem with these is that he
            // cannot go and look at them anywhere else.
            .confirmationDialog(
                "Switch off \(retired.map(\.summary).joined(separator: " and "))?",
                isPresented: $confirmingSilence,
                titleVisibility: .visible
            ) {
                Button("Switch off", role: .destructive) {
                    isSilencing = true
                    let ids = retired.map(\.id)
                    Task {
                        silenceResult = (try? await store.eightSleep.silenceAlarms(ids))
                            ?? ["That did not work. Nothing was changed."]
                        isSilencing = false
                    }
                    // `choices` is a `let` handed down by the parent, not state this screen owns, so
                    // there is nothing to refresh here and an attempt to would not compile. The
                    // result text takes over the block instead, which is also the more honest
                    // rendering: it says what happened rather than redrawing a list and leaving him
                    // to infer it from something no longer being there.
                }
                Button("Leave them", role: .cancel) {}
            } message: {
                Text("They keep their time, their days and their temperature. Nothing is deleted, and your \(retired.count == 1 ? "other alarm is" : "other alarms are") untouched.")
            }
        }
    }

    @ViewBuilder
    private var routineTruth: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if routines.isEmpty {
                    Text("Nothing read yet, or this account does not expose routines at this address.")
                        .font(.system(size: 12)).foregroundStyle(Theme.greyDim)
                } else {
                    Text(routines.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.greyDim)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            Text("Your Eight Sleep routines, raw")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.grey)
        }
        .tint(Theme.grey)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
    }

    @ViewBuilder
    private func matchRows(_ report: AlarmMatchReport) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            // Indexed rather than keyed on the alarm id. Two routines with the same days would both
            // claim the same alarm, and a duplicate id in a ForEach is a silently dropped row.
            ForEach(Array(report.pairs.enumerated()), id: \.offset) { _, pair in
                MatchRow(
                    title: pair.routineName,
                    detail: choices.first { $0.id == pair.alarmID }
                        .map { "follows the alarm at \($0.timeLabel), \($0.daysLabel)" } ?? "matched",
                    warning: pair.shouldBeEnabled
                        ? nil
                        : "Switched off, because this routine is off in OneAlarm. Turn the routine back on in My week and the bed follows.",
                    live: true
                )
            }
            ForEach(report.routinesWithNoAlarm, id: \.self) { name in
                MatchRow(title: name, detail: "no alarm on this bed runs on these days", warning: nil, live: false)
            }
            ForEach(report.alarmsWithNoRoutine, id: \.self) { label in
                MatchRow(title: label, detail: "no routine has these days, so OneAlarm never touches it",
                         warning: nil, live: false)
            }
            // Alarms his own Eight Sleep app will not list.
            //
            // Kept separate from the rows above, and warned about rather than merely mentioned,
            // because they are the one thing on this screen he cannot go and fix himself. They ring.
            // They do not appear in the Eight Sleep app, so there is nothing there to switch off, and
            // OneAlarm deletes only alarms it recorded creating, and these predate that record.
            ForEach(choices.filter(\.isHidden)) { choice in
                MatchRow(
                    title: choice.summary,
                    detail: "OneAlarm made this before 17 August and left a nap tag on it, so the Eight Sleep app does not list it",
                    warning: "This one still rings, and you cannot switch it off in the Eight Sleep app because it is not shown there. OneAlarm leaves it alone rather than quietly taking it over, and will not delete it either, because it cannot prove it made this one.",
                    live: false
                )
            }
        }
    }

    /// Extracted because the enclosing body was already at the size where the Swift type checker
    /// gives up and says so only as "unable to type-check this expression in reasonable time".
    private struct MatchRow: View {
        let title: String
        let detail: String
        let warning: String?
        let live: Bool

        var body: some View {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(live ? AnyShapeStyle(Theme.Ramp.rail(for: .eightSleep)) : AnyShapeStyle(Theme.line))
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(live ? Color.white : Theme.grey)
                    Text(detail).font(.system(size: 13)).foregroundStyle(Theme.grey)
                    if let warning {
                        Text(warning)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.State.unconfirmed)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 70)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1))
        }
    }
}

// MARK: Alarm picker

/// Shown when an account holds more than one alarm.
///
/// **Whoop only now.** Eight Sleep holds one alarm per day set, so its routines match themselves and
/// there is nothing to pick; see `BedConfirmScreen`. Whoop holds one schedule per account, so if
/// that account ever returns more than one row, the ambiguity is real and asking is the only honest
/// answer.
///
/// Whoop does not label a schedule with a device or a room, so these are identified by time and
/// days, which is the only honest thing the data supports. The choice is remembered, and if the
/// chosen alarm later disappears the app asks again rather than quietly moving a different one.
@MainActor
struct AlarmPickerScreen: View {
    let device: DeviceID
    let choices: [RemoteAlarmChoice]
    let onPick: (RemoteAlarmChoice) -> Void
    let onBack: () -> Void
    let onDisconnect: () -> Void

    @Environment(ScheduleStore.self) private var store

    @State private var selected: String? = nil
    @State private var bed: EightSleepAdapter.BedIdentity?

    /// Says why this list can be longer than the one in the device's own app.
    ///
    /// Eight Sleep shows two and returns three. Without this line the extra row reads as OneAlarm
    /// inventing an alarm, which is worse than the clutter it causes.
    private var pickerSubtitle: String {
        let inert = choices.filter { !$0.canFire }.count
        // **"OneAlarm changes one of them" stopped being true on the Whoop leg on 17 August.** It now
        // writes one schedule per routine, matched by days, after Alex's account proved Whoop holds
        // more than one. A screen still promising the old behaviour is the sort of stale copy that
        // gets read as a statement of intent and then defended.
        let base = device == .whoop
            ? "This account has \(choices.count). Each of your routines drives the schedule with its own days, so you do not usually pick one here."
            : "This account has \(choices.count). OneAlarm changes one of them and leaves the rest alone."
        guard inert > 0 else { return base }
        let word = inert == 1 ? "one" : "\(inert)"
        return base + " The \(device.displayName) app may show fewer: \(word) of these can never go off, and their app hides those."
    }

    var body: some View {
        Screen(title: device.displayName, onBack: onBack) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(device == .whoop ? "Which schedule should a routine take over?" : "Which alarm should OneAlarm move?")
                        .font(.system(size: 25, weight: .bold)).tracking(-0.6)
                    Text(pickerSubtitle).font(.system(size: 15)).foregroundStyle(Theme.grey)
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
                                    if !choice.canFire {
                                        Text(choice.isEnabled
                                             ? "No days set, so it never goes off"
                                             : "Switched off, and no days set")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Theme.State.unconfirmed)
                                    } else if !choice.isEnabled {
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
                } else if let bed, let label = bed.label {
                    // The answer, once, at account level. Not a badge per row: alarms on this API
                    // are user scoped, so an alarm does not belong to a bed and a per row bed name
                    // would be a claim the API cannot support.
                    Notice(.good, title: "You are on \(label).",
                           bed.deviceCount > 1
                           ? "This account has \(bed.deviceCount) Pods and one shared list of alarms. Whichever alarm you pick fires on the bed you are currently assigned to, which is this one. Move yourself in the Eight Sleep app to change that."
                           : "Your alarms fire on this bed.")
                } else if choices.contains(where: { $0.group == nil }), let sample = choices.first {
                    // Shown when the parse SUCCEEDED but no name was found, which is the only way to
                    // tell "this service does not name its alarms" apart from "we looked in the
                    // wrong place". A diagnostic that appears only on failure cannot answer that,
                    // because the parse succeeds either way. Field names from an alarm schedule,
                    // never a credential.
                    // **Device aware, because it was not and Alex saw the result.** On 17 August this
                    // printed "This account did not name its beds. Eight Sleep does not put a bed or
                    // a side on an alarm" on the **Whoop** screen. `device` has been a property of
                    // this screen since it was written; the copy simply never asked.
                    //
                    // Worth more than a typo fix: the whole point of this notice is telling a real
                    // absence apart from looking in the wrong place, and a notice naming the wrong
                    // service answers that question about a service nobody asked about.
                    Notice(.warn,
                           title: device == .whoop
                               ? "Whoop does not label its schedules."
                               : "This account did not name its beds.",
                           (device == .whoop
                            ? "A Whoop schedule carries days and a wake time and no name, so these are listed by time. Each of your routines drives the schedule whose days match it exactly. Pick one here when the days do not match, for example a routine covering Saturday and Sunday against a schedule covering Saturday alone: choosing it hands that schedule to the routine, and OneAlarm sets its days from then on.\n\nWhat this account returned: "
                            : "Eight Sleep does not put a bed or a side on an alarm, so these are listed by time. To be certain which is which, open the Eight Sleep app and compare the times.\n\nWhat this account returned: ")
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
        .task {
            // A label. It never blocks the picker and it never fails loudly: `currentBed` returns
            // nil rather than throwing, because a bed whose name cannot be fetched must not take an
            // alarm down with it.
            guard device == .eightSleep else { return }
            bed = await store.eightSleep.currentBed()
        }
    }
}
