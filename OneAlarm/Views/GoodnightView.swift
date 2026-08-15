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

    private var confirmed: [ResolvedTarget] {
        store.targets.filter { (store.status[$0.device] ?? .idle).isSettled }
    }

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

                if allConfirmed {
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

    private func caption(for device: DeviceID) -> String {
        switch device {
        case .eightSleep: return "Bed starts warming"
        case .whoop: return "Wrist buzzes"
        case .iphone: return "Phone and watch, loud"
        }
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
