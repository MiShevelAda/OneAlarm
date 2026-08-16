import SwiftUI

/// The trust moment, and the one screen with no precedent in either brand.
///
/// Whoop shows you the past. Eight Sleep acts silently and narrates in the morning. This app has to
/// promise a *future* and be believed, at the moment the phone goes face down. That is where it
/// earns trust or does not, so it gets the quietest treatment in the app: one continuous rail, three
/// times, no controls, and a line telling you there is nothing left to do.
@MainActor
struct GoodnightView: View {
    @Environment(ScheduleStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var allConfirmed: Bool {
        !store.targets.isEmpty && store.targets.allSatisfy {
            if case .done = store.status[$0.device] ?? .idle { return true }
            return false
        }
    }

    var body: some View {
        Screen {
            VStack(spacing: 0) {
                Text("Good night").themeLabel().padding(.top, 44).padding(.bottom, 34)

                Text(allConfirmed ? "Your morning is set" : "Your morning is mostly set")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.7)
                    .padding(.bottom, 40)

                rail.padding(.bottom, 40)

                Text(summary)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.grey)
                    .multilineTextAlignment(.center)

                // **Anything that must be read, read here.**
                //
                // This sheet is presented over the home screen every time Set all alarms finishes,
                // settled or not, so it is the screen he is actually looking at. Until 18 August a
                // one time change that landed perfectly ended with "All confirmed. Nothing left to
                // do. Put the phone down" on screen and the sentence confirming it one dismissal
                // behind. The screen was telling him to stop looking at the moment there was
                // something to look at.
                if !notices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(notices, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.grey)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // Long press and copy. Alex reports these lines back, and three
                                // handoffs have already failed on him having to retype or crop
                                // something. The build stamp got this for the same reason.
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 18)
                    .padding(.horizontal, 4)
                }

                if allConfirmed, notices.isEmpty {
                    Text("Put the phone down.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.greyDim)
                        .padding(.top, 6)
                }
            }
        } footer: {
            QuietButton(title: "Back to alarms") { dismiss() }
        }
    }

    /// One rail, the whole dawn, rather than a gradient per card. This is the only place the full
    /// ramp appears uninterrupted.
    private var rail: some View {
        HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.Ramp.full)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 26) {
                ForEach(store.targets, id: \.device) { target in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(target.localTime.hhmm)
                            .font(Theme.numeral(target.device == .iphone ? 32 : 24))
                            .foregroundStyle(target.device == .iphone ? Theme.Ramp.warmLit : .white)
                        Text(caption(for: target.device)).themeLabel()
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: 260)
    }

    /// What each device does at its time, and nothing about how it does it.
    ///
    /// Alex, 2026-08-16: *"it says the bed will be warming from 06:55. No, it should say the bed
    /// will be at desired temperature at this time, because the actual modification, how I want it
    /// to be set up, if it's vibrating, how hard it is, is it a temperature, I want that to be
    /// inside the Eight Sleep app."*
    ///
    /// He is right twice over. "Bed starts warming" describes a ramp OneAlarm neither sets nor
    /// reads: it writes one field, `time`, and what happens at that time is whatever vibration and
    /// thermal he configured in their app. The old caption invented a mechanism and implied
    /// ownership of a setting this app deliberately never touches.
    private func caption(for device: DeviceID) -> String {
        switch device {
        case .eightSleep: return "Bed, as you set it up in Eight Sleep"
        case .whoop: return "Wrist buzzes"
        case .iphone: return "Phone and watch, loud"
        }
    }

    /// Sentences the last write said must be read, in device order, deduplicated.
    ///
    /// Deduplicated because a routine covering a morning on two legs can produce the same warning
    /// twice, and the same sentence printed twice reads as two problems.
    private var notices: [String] {
        var seen = Set<String>()
        return store.targets.flatMap { store.highlights[$0.device] ?? [] }
            .filter { seen.insert($0).inserted }
    }

    private var summary: String {
        let failed = store.targets.filter {
            if case .failed = store.status[$0.device] ?? .idle { return true }
            return false
        }
        if allConfirmed { return "All confirmed. Nothing left to do." }
        if failed.isEmpty { return "Set, though not every device could confirm it." }
        // Never let a failure imply the alarm will not ring, when the backstop is fine.
        let iphoneOK = store.targets.contains { $0.device == .iphone }
            && !failed.contains { $0.device == .iphone }
        return iphoneOK
            ? "\(failed.map(\.device.displayName).joined(separator: " and ")) did not take. Your phone alarm will still ring."
            : "Some devices did not take. Worth checking before you sleep."
    }
}
