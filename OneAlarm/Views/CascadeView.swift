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
                nextMorning
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

    // MARK: The next morning

    /// The screen's first job is to say which morning it means.
    ///
    /// A time on its own is what made a correct weekday alarm read as broken when it was tested at
    /// 01:00 on a Sunday: the screen said 08:00 and nothing else, and the next occurrence was two
    /// days away. The day is now the first thing on the screen, always, and the second line says
    /// whether the time came from a routine or from a bend.
    @ViewBuilder
    private var nextMorning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.nextAlarmHeadline).themeLabel()

            if let notice = store.overrideNotice {
                Notice(.warn, title: notice,
                       "Nothing about your routine changed. It comes back on its own.")

                HStack(spacing: 8) {
                    Button("Make this the routine") { store.makeOverridePermanent() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.lineStrong, lineWidth: 1))

                    Button("Undo") { store.clearOverride() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.State.confirmed)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                }
            } else if let next = store.next, let routine = next.routineName {
                Text("\(routine) · \(next.time.hhmm)")
                    .font(.system(size: 14)).foregroundStyle(Theme.grey)
            } else if store.next == nil {
                Notice(.warn, title: "No alarm is set.",
                       "No routine covers the next two weeks. Nothing will wake you.")
            }

            HStack(spacing: 8) {
                nudge("−15", minutes: -15)
                nudge("+15", minutes: 15)
                Button {
                    store.skipNextMorning()
                } label: {
                    Text("Skip")
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(store.next == nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Nudges bend the next morning only. Never the routine.
    ///
    /// The default is the frequent intent: a routine changes twice a year, a single morning bends
    /// twice a month. A question answered the same way nine times in ten is a tax, not a safeguard,
    /// and one answered half asleep is one that gets dismissed unread. Getting this wrong is visible
    /// on the line above and one tap from fixed; the opposite default rewrites a routine silently.
    private func nudge(_ label: String, minutes: Int) -> some View {
        Button {
            guard let next = store.next else { return }
            store.bendNextMorning(to: WallClockTime(
                minutesSinceMidnight: next.time.minutesSinceMidnight + minutes
            ))
        } label: {
            Text(label)
                .font(Theme.numeral(17))
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(store.next == nil)
    }

    // MARK: Master time

    private var masterTime: some View {
        VStack(spacing: 14) {
            Text(store.overrideNotice == nil ? "Wake at" : "Wake at, this morning only").themeLabel()

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
                        // Bends the next morning, never the routine. Same rule as the nudges: the
                        // frequent intent is the default, and the rare one is a labelled tap.
                        let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                        store.bendNextMorning(to: WallClockTime(hour: c.hour ?? 7, minute: c.minute ?? 0))
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

    /// The days of the routine that covers the next morning, not a free floating day set.
    ///
    /// A day moved into this routine leaves whichever one held it, because a day in two routines is
    /// two answers to the same question. A day in none means no alarm, which is a real answer.
    private var weekdays: some View {
        let routineID = store.next.flatMap { next in
            store.schedule.routine(covering: next.weekday)?.id
        }
        return VStack(alignment: .leading, spacing: 6) {
            if let routineID,
               let routine = store.schedule.routines.first(where: { $0.id == routineID }) {
                Text("\(routine.name) · \(routine.time.hhmm)").themeLabel()
            }
            HStack(spacing: 6) {
            ForEach(Locale.Weekday.displayOrder, id: \.calendarIndex) { day in
                let on = routineID.flatMap { id in
                    store.schedule.routines.first(where: { $0.id == id })?.weekdays.contains(day)
                } ?? false
                Button {
                    if let routineID { store.toggleDay(day, in: routineID) }
                } label: {
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
            HStack {
                Text("The descent").themeLabel()
                Spacer()
                // A stated choice rather than three coincidences. Spacing devices out is the point
                // of the app, so wanting them together has to be one tap rather than three.
                if store.schedule.rules.contains(where: { $0.offsetMinutes != 0 }) {
                    Button("Ring together") { store.ringTogether() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.grey)
                }
            }

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

    /// Which morning this actually fires, shown whenever that is not the next one.
    ///
    /// Silent on the common case so the row stays a time, loud the moment the answer is surprising,
    /// which is the case that costs you a morning.
    private var whenLabel: String? {
        let calendar = Calendar.current
        let next = target.nextOccurrence
        if calendar.isDateInToday(next) || calendar.isDateInTomorrow(next) { return nil }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: next)
        ).day ?? 0
        return next.formatted(.dateTime.weekday(.abbreviated)).uppercased() + ", IN \(days) DAYS"
    }

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.Ramp.rail(for: target.device))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(target.localTime.hhmm).font(Theme.numeral(30))
                    // A time with no day is how a weekday alarm gets tested on a Sunday and
                    // reported as broken. It fired exactly when it was told to; the screen just
                    // never said which morning that was.
                    if let day = whenLabel {
                        Text(day)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.State.unconfirmed)
                    }
                }
                Text(target.device.displayName).font(.system(size: 15, weight: .semibold))

                // Each device's own time, editable here rather than nowhere. The offsets have
                // existed since the first build and no screen ever reached them.
                HStack(spacing: 6) {
                    Button {
                        store.setDeviceTime(WallClockTime(
                            minutesSinceMidnight: target.localTime.minutesSinceMidnight - 5
                        ), for: target.device)
                    } label: { stepLabel("−5") }
                    .buttonStyle(.plain)

                    Button {
                        store.setDeviceTime(WallClockTime(
                            minutesSinceMidnight: target.localTime.minutesSinceMidnight + 5
                        ), for: target.device)
                    } label: { stepLabel("+5") }
                    .buttonStyle(.plain)

                    if store.schedule.anchorDevice == target.device {
                        Text("MAIN")
                            .font(.system(size: 9, weight: .bold)).tracking(1)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Theme.State.confirmed.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(Theme.State.confirmed)
                    } else {
                        Button { store.makeAnchor(target.device) } label: {
                            Text("Set as main")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
                                .foregroundStyle(Theme.grey)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)

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

    private func stepLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.numeral(13))
            .frame(width: 38, height: 28)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1))
            .foregroundStyle(.white)
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
