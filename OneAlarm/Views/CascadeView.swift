import SwiftUI

/// The home screen, and the only one that matters day to day.
///
/// The cascade rides Eight Sleep's gradient because that scale is literally true here: the bed is
/// doing thermal work at T minus ten, the loud alarm fires at T. Device state rides Whoop's flat
/// accents. The two never swap jobs.
@MainActor
struct CascadeView: View {
    @Environment(ScheduleStore.self) private var store

    @State private var showingConnections = false
    @State private var previewDevice: DeviceID?
    @State private var showingGoodnight = false

    var body: some View {
        Screen(
            title: "OneAlarm",
            trailing: AnyView(
                Button { showingConnections = true } label: {
                    Image(systemName: "person.badge.key")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .overlay(Circle().strokeBorder(Theme.lineStrong, lineWidth: 1))
                }
                .accessibilityLabel("Connections")
            )
        ) {
            VStack(spacing: 26) {
                masterTime
                wakeWindow
                cascade
                previewLink
                footer
            }
            .padding(.bottom, 20)
        } footer: {
            SolidButton(title: store.isSyncing ? "Setting alarms" : "Set all alarms",
                        busy: store.isSyncing) {
                Task {
                    await store.apply()
                    if store.targets.allSatisfy({ (store.status[$0.device] ?? .idle).isSettled }) {
                        showingGoodnight = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingConnections) { ConnectionsHubView().environment(store) }
        .sheet(item: $previewDevice) { WritePreviewSheet(device: $0).environment(store) }
        .sheet(isPresented: $showingGoodnight) { GoodnightView().environment(store) }
    }

    // MARK: Master time

    private var masterTime: some View {
        VStack(spacing: 14) {
            Text("Wake at").themeLabel()

            DatePicker(
                "Wake time",
                selection: Binding(
                    get: {
                        var c = DateComponents()
                        c.hour = store.schedule.masterTime.hour
                        c.minute = store.schedule.masterTime.minute
                        return Calendar.current.date(from: c) ?? Date()
                    },
                    set: {
                        let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                        store.setMasterTime(WallClockTime(hour: c.hour ?? 7, minute: c.minute ?? 0))
                    }
                ),
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .colorScheme(.dark)

            weekdays
        }
        .padding(.top, 4)
    }

    private var weekdays: some View {
        HStack(spacing: 6) {
            ForEach(Locale.Weekday.displayOrder, id: \.calendarIndex) { day in
                let on = store.schedule.weekdays.contains(day)
                Button { store.toggleWeekday(day) } label: {
                    Text(day.shortLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(on ? Color.white.opacity(0.14) : Color.white.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(on ? Theme.lineStrong : Theme.line, lineWidth: 1)
                        )
                        .foregroundStyle(on ? .white : Theme.greyDim)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Wake window

    /// Whoop's hatched span and dashed target range, reused for the gap between first move and fully
    /// awake. Their instrument, our quantity.
    @ViewBuilder
    private var wakeWindow: some View {
        if let first = store.targets.first, let last = store.targets.last, first.device != last.device {
            VStack(spacing: 9) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(first.localTime.hhmm).font(Theme.numeral(24))
                        Text("First move").themeLabel()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(last.localTime.hhmm).font(Theme.numeral(24))
                        Text("Fully awake").themeLabel()
                    }
                }

                let minutes = Int(last.nextOccurrence.timeIntervalSince(first.nextOccurrence) / 60)
                ZStack {
                    HatchBar()
                    Text("\(minutes) min")
                        .font(Theme.numeral(13))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Theme.Ground.bottom, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white, lineWidth: 1.5))
                }
                .frame(height: 24)

                VStack(spacing: 5) {
                    Rectangle().fill(Theme.State.target).frame(height: 1).opacity(0.5)
                    Text("Wake window").themeLabel(Theme.State.target)
                }
            }
        }
    }

    // MARK: Cascade

    private var cascade: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The descent").themeLabel()

            VStack(spacing: 9) {
                ForEach(store.targets, id: \.device) { target in
                    CascadeRow(target: target) { previewDevice = target.device }
                }

                // Disabled legs still show, greyed, so switching one off is visible rather than a
                // row that silently vanishes.
                ForEach(store.schedule.rules.filter { !$0.isEnabled }, id: \.id) { rule in
                    DisabledRow(device: rule.device)
                }
            }
        }
    }

    private var previewLink: some View {
        Button { previewDevice = store.targets.first?.device } label: {
            Text("See exactly what gets sent")
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.white.opacity(0.06), in: Capsule())
                .foregroundStyle(Theme.grey)
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 8) {
            if store.nothingToApply {
                Notice(.bad, title: "Nothing was set.",
                       "Every device is either switched off or not connected.")
            } else if store.schedule.rule(for: .iphone)?.isEnabled == false {
                Notice(.bad, title: "Your iPhone alarm is off.",
                       "It is the only one that rings with no account, no network and no subscription. Everything else is a nudge.")
            } else if store.targets.contains(where: { $0.crossesMidnight }) {
                Notice(.warn, title: "One device fires the night before.",
                       "Its days shift back to match, so the bed warms on the right night.")
            }

            if store.needsApply, store.lastSyncedAt != nil {
                Text("Changed since last set")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.State.unconfirmed)
            } else if let last = store.lastSyncedAt {
                Text("Last set \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.greyDim)
            }
        }
    }
}

// MARK: Row

@MainActor
private struct CascadeRow: View {
    @Environment(ScheduleStore.self) private var store
    let target: ResolvedTarget
    let onPreview: () -> Void

    private var status: DeviceSyncStatus { store.status[target.device] ?? .idle }
    private var authState: AuthState { store.authStates[target.device] ?? .notConfigured }

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.Ramp.rail(for: target.device))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(target.localTime.hhmm).font(Theme.numeral(30))
                Text(target.device.displayName).font(.system(size: 15, weight: .semibold))

                HStack(spacing: 8) {
                    statusPill
                    if target.crossesMidnight {
                        Text("Night before")
                            .font(.system(size: 10, weight: .bold)).tracking(1)
                            .textCase(.uppercase)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Theme.State.unconfirmed.opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(Theme.State.unconfirmed)
                    }
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { true },
                set: { store.setEnabled($0, for: target.device) }
            ))
            .labelsHidden()
            .tint(Theme.State.confirmed)
        }
        .padding(15)
        .background(Theme.Ramp.card(for: target.device),
                    in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
        .onLongPressGesture(perform: onPreview)
    }

    @ViewBuilder
    private var statusPill: some View {
        switch status {
        case .idle:
            if case .needsReauth(let reason) = authState {
                StatePill(text: reason, color: Theme.State.unconfirmed)
            } else if target.device.requiresCredentials, authState == .notConfigured {
                StatePill(text: "Not connected", color: Theme.grey, showsDot: false)
            } else if target.device == .iphone {
                StatePill(text: "Always rings", color: Theme.grey, showsDot: false)
            }
        case .writing, .verifying:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6).tint(Theme.grey)
                Text(status.pillText).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.grey)
            }
        default:
            StatePill(text: status.pillText, color: status.pillColor)
        }
    }
}

@MainActor
private struct DisabledRow: View {
    @Environment(ScheduleStore.self) private var store
    let device: DeviceID

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.greyDim.opacity(0.4)).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.displayName).font(.system(size: 15, weight: .semibold))
                Text("Off").themeLabel()
            }
            Spacer()
            Toggle("", isOn: Binding(get: { false }, set: { store.setEnabled($0, for: device) }))
                .labelsHidden()
                .tint(Theme.State.confirmed)
        }
        .padding(15)
        .themeCard()
        .opacity(0.55)
    }
}

/// Whoop's hatched span fill.
private struct HatchBar: View {
    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let spacing: CGFloat = 6
                var x: CGFloat = -size.height
                while x < size.width + size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    context.stroke(path, with: .color(.white.opacity(0.19)), lineWidth: 2)
                    x += spacing
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(
                HStack {
                    Rectangle().fill(.white).frame(width: 2)
                    Spacer()
                    Rectangle().fill(.white).frame(width: 2)
                }
            )
        }
    }
}

extension DeviceSyncStatus {
    /// Settled means finished, whatever the outcome. Used to decide when to offer good night.
    var isSettled: Bool {
        switch self {
        case .done, .warning, .failed: return true
        case .idle, .writing, .verifying: return false
        }
    }
}
