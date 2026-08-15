import SwiftUI

/// Where credentials are entered. Nothing typed here is written anywhere except the Keychain, and
/// nothing typed here is ever logged.
@MainActor
struct ConnectionsView: View {
    @Environment(ScheduleStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var eightSleepEmail = ""
    @State private var eightSleepPassword = ""
    @State private var whoopEmail = ""
    @State private var whoopPassword = ""
    @State private var whoopCode = ""
    @State private var whoopNeedsCode = false
    @State private var whoopCodePrompt = ""
    @State private var busy: DeviceID?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                iphoneSection
                eightSleepSection
                whoopSection

                if let message {
                    Section {
                        Text(message).font(.footnote)
                    }
                }

                Section {
                    Text("Credentials are stored in the iPhone Keychain, tied to this device, and are never included in a backup or copied to another phone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: iPhone

    private var iphoneSection: some View {
        Section("iPhone") {
            LabeledContent("Alarm permission") {
                Text(statusText(for: .iphone))
                    .foregroundStyle(.secondary)
            }
            Button("Request permission") {
                Task {
                    await store.alarmKit.requestAuthorization()
                    await store.refreshAuthStates()
                }
            }
            Text("Needed once. AlarmKit alarms ring through Silent and Focus, and show on a paired Apple Watch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Eight Sleep

    private var eightSleepSection: some View {
        Section("Eight Sleep") {
            LabeledContent("Status") {
                Text(statusText(for: .eightSleep)).foregroundStyle(.secondary)
            }
            TextField("Email", text: $eightSleepEmail)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $eightSleepPassword)
                .textContentType(.password)

            Button(busy == .eightSleep ? "Signing in" : "Connect") {
                Task { await connectEightSleep() }
            }
            .disabled(busy != nil || eightSleepEmail.isEmpty || eightSleepPassword.isEmpty)

            Button("Disconnect", role: .destructive) {
                Task {
                    await store.eightSleep.signOut()
                    await store.refreshAuthStates()
                }
            }

            Text("OneAlarm updates the alarm you already have in the Eight Sleep app, so create one there first. Your vibration and thermal settings are left exactly as they are.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func connectEightSleep() async {
        busy = .eightSleep
        message = nil
        do {
            try await store.eightSleep.signIn(email: eightSleepEmail, password: eightSleepPassword)
            eightSleepPassword = ""
            message = "Eight Sleep connected."
        } catch {
            message = (error as? AdapterError)?.errorDescription ?? error.localizedDescription
        }
        await store.refreshAuthStates()
        busy = nil
    }

    // MARK: Whoop

    private var whoopSection: some View {
        Section("Whoop") {
            LabeledContent("Status") {
                Text(statusText(for: .whoop)).foregroundStyle(.secondary)
            }

            if whoopNeedsCode {
                Text(whoopCodePrompt)
                    .font(.footnote)
                TextField("Code", text: $whoopCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                Button("Confirm code") {
                    Task { await confirmWhoopCode() }
                }
                .disabled(busy != nil || whoopCode.isEmpty)
            } else {
                TextField("Email", text: $whoopEmail)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $whoopPassword)
                    .textContentType(.password)
                Button(busy == .whoop ? "Signing in" : "Connect") {
                    Task { await connectWhoop() }
                }
                .disabled(busy != nil || whoopEmail.isEmpty || whoopPassword.isEmpty)
            }

            Button("Disconnect", role: .destructive) {
                Task {
                    await store.whoop.signOut()
                    whoopNeedsCode = false
                    await store.refreshAuthStates()
                }
            }

            Text("Whoop has no official alarm API, so this uses the same private one their app uses. Personal account only. Sign in again roughly monthly. Create a smart alarm in the Whoop app first, OneAlarm moves that one.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            // Stated rather than carried silently. The reference work this leg is ported from does
            // not push the time to the strap firmware either, and relies on the official app to
            // sync it. Whether the band buzzes without that step is genuinely unknown.
            Label(
                "Keep the Whoop app installed and open it now and then. OneAlarm changes the alarm on Whoop's servers, and their app is what carries it to the band.",
                systemImage: "info.circle"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func connectWhoop() async {
        busy = .whoop
        message = nil
        do {
            // One attempt, never a retry loop. Repeated failures rate limit the auth endpoint.
            let outcome = try await store.whoop.signIn(email: whoopEmail, password: whoopPassword)
            whoopPassword = ""
            switch outcome {
            case .signedIn:
                message = "Whoop connected."
            case .needsCode(let challenge):
                whoopNeedsCode = true
                whoopCodePrompt = challenge.prompt
            }
        } catch {
            message = (error as? AdapterError)?.errorDescription ?? error.localizedDescription
        }
        await store.refreshAuthStates()
        busy = nil
    }

    private func confirmWhoopCode() async {
        busy = .whoop
        message = nil
        do {
            try await store.whoop.submitCode(whoopCode)
            whoopCode = ""
            whoopNeedsCode = false
            message = "Whoop connected."
        } catch {
            message = (error as? AdapterError)?.errorDescription ?? error.localizedDescription
        }
        await store.refreshAuthStates()
        busy = nil
    }

    // MARK: Helpers

    private func statusText(for device: DeviceID) -> String {
        switch store.authStates[device] ?? .notConfigured {
        case .connected: return "Connected"
        case .notConfigured: return "Not connected"
        case .needsReauth(let reason): return reason
        }
    }
}
