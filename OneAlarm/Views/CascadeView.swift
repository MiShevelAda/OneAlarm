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
    @State private var showingRoutines = false
    @State private var showingTomorrowPicker = false

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
                weekStrip
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
        .sheet(isPresented: $showingRoutines) { RoutinesView().environment(store) }
        .sheet(isPresented: $showingTomorrowPicker) {
            TomorrowPicker().environment(store).presentationDetents([.medium])
        }
    }

    // MARK: The next morning

    /// The whole home screen is **one morning**, and this block is it.
    ///
    /// Alex, 2026-08-16: *"it's not very clear what is a routine and what is not a routine."* The
    /// cause was scope, not wording. This screen used to carry a wheel that bent tomorrow, a picker
    /// inside each routine card that changed the routine, and steppers on each device row that moved
    /// that device's lead: three identical looking controls with three different lifetimes, in one
    /// scrolling column. No label survives that.
    ///
    /// So the wheel is gone from here and routines are gone from here. This screen edits tomorrow
    /// and says so above the controls; `RoutinesView` edits the week and says so too. The one thing
    /// still shared is the device lead on each row, which is a per device offset rather than a time
    /// and now reads as one.
    ///
    /// The day stays the first thing on the screen. A time on its own is what made a correct weekday
    /// alarm read as broken when it was tested at 01:00 on a Sunday.
    @ViewBuilder
    private var nextMorning: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.nextAlarmHeadline).themeLabel()

            Button { showingTomorrowPicker = true } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(store.next?.time.hhmm ?? "--:--").font(Theme.numeral(54))
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.greyDim)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.next == nil)

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
            } else if let routine = store.next?.routineName {
                // Says where the time came from, and that it repeats. Without this the big number
                // above reads as a one-off that somebody typed.
                Text("From your \(routine) routine. Repeats every week.")
                    .font(.system(size: 14)).foregroundStyle(Theme.grey)
            } else if store.next == nil {
                Notice(.warn, title: "No alarm is set.",
                       "No routine covers the next two weeks. Nothing will wake you.")
            }

            thisMorningOnly
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The three verbs that change one morning, under a line that says so.
    ///
    /// Extracted for the same reason as everything else in this file that got extracted: the type
    /// checker gives up on an oversized body and reports it only as "unable to type-check this
    /// expression in reasonable time", which is a compile error with no location in it.
    private var thisMorningOnly: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("This morning only").themeLabel()
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
    }

    // MARK: My week

    /// Every routine, read only, one line each.
    ///
    /// Alex asked twice for opposite sounding things: *"it's still not clear which routines I have
    /// set up, it should be directly on my home screen"*, and then that routines are confusing here.
    /// Both are right, and they are not in conflict once **seeing** is separated from **editing**.
    /// This strip is the answer to the first: the week is visible at a glance and never hidden
    /// behind a menu. It is not the answer to the second, so nothing in it can be changed. One tap
    /// goes to the screen where it can.
    private var weekStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("My week").themeLabel()
                Spacer()
                Text("\(store.schedule.routines.count) routine\(store.schedule.routines.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(Theme.greyDim)
            }

            Button { showingRoutines = true } label: { weekCard }
                .buttonStyle(.plain)

            if let uncovered = store.uncoveredDays, !uncovered.isEmpty {
                Notice(.warn, title: "No alarm on \(uncovered).",
                       "Those days belong to no routine, so nothing will wake you on them.")
            }
        }
    }

    private var weekCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.schedule.routines.enumerated()), id: \.offset) { index, routine in
                if index > 0 { Divider().overlay(Theme.line) }
                WeekStripRow(routine: routine, isNext: store.next?.routineID == routine.id)
            }

            if store.schedule.routines.isEmpty {
                Text("No routines yet. Tap to add one.")
                    .font(.system(size: 14)).foregroundStyle(Theme.grey)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(15)
            }

            Divider().overlay(Theme.line)

            HStack(spacing: 6) {
                Text("Edit my week").font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.grey)
            .padding(.horizontal, 15).padding(.vertical, 13)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
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
                // A leg with no account is greyed, switched off and last, rather than sitting
                // among the working rows showing a time it has no way to keep. `orderedTargets`
                // already sorts them to the bottom, so this only decides how each one is drawn.
                ForEach(store.orderedTargets, id: \.device) { target in
                    if store.isConnected(target.device) {
                        CascadeRow(target: target) { store.makeAnchor(target.device) }
                    } else {
                        DisabledRow(device: target.device, reason: "Not connected")
                    }
                }

                // Switched off by hand. Still shown, so turning one off is visible rather than a
                // row that silently vanishes.
                ForEach(store.schedule.rules.filter { !$0.isEnabled }, id: \.id) { rule in
                    DisabledRow(device: rule.device, reason: "Off")
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
                       "Its days shift back to match, so the bed reacts on the right night.")
            }

            whoopCarriesOneRoutine

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

    /// **Both the phone and Whoop carry one routine at a time**, and the phone is the serious one.
    ///
    /// Said out loud because it is a real limitation with a real consequence and nothing on screen
    /// admitted it. Eight Sleep holds one alarm per day set, so a whole week fits there. Whoop has a
    /// single smart alarm schedule with a single day list, so OneAlarm writes the routine covering
    /// the next morning and that list replaces whatever was on it.
    ///
    /// On a Friday night that puts his strap on Saturday and Sunday, and Monday morning has no Whoop
    /// alarm unless he syncs again on the Sunday. Same shape as the damage done on 15 August, when a
    /// test wrote all seven days over his real Monday to Friday schedule, except that this time it is
    /// the service's limit rather than a mistake. Either way he should hear it from the app rather
    /// than from his wrist.
    ///
    /// Only shown when it can actually bite: more than one live routine on the account.
    ///
    /// The phone was in the "carries the whole week" half of this sentence until 17 August, and it
    /// was not true. `AlarmKitAdapter` schedules **one** alarm from the single resolved target and
    /// cancels the previous one, so after a Friday night sync the phone is armed for Saturday and
    /// Sunday and Monday has no alarm on it at all. AlarmKit itself holds several alarms happily;
    /// this app only ever gives it one. That is a silent missed morning on the leg that exists to be
    /// the guarantee, and saying so on screen is the least it is owed until it is fixed.
    @ViewBuilder
    private var whoopCarriesOneRoutine: some View {
        let live = store.schedule.routines.filter { $0.isOn && !$0.weekdays.isEmpty }
        if live.count > 1, let next = store.next?.routineName {
            Notice(.bad, title: "Only \(next) is armed. Set again after it.",
                   "Your phone and your strap each hold one routine at a time, so right now they carry \(next) and nothing else. Your bed holds the whole week. Press Set all alarms again after \(next)'s last morning, or that next morning has no phone alarm. This is a limitation of the app rather than of your devices, and it is the top item on the list to fix.")
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
                HStack(spacing: 7) {
                    Text(target.device.displayName).font(.system(size: 15, weight: .semibold))
                    if store.schedule.anchorDevice == target.device {
                        Text("MAIN")
                            .font(.system(size: 9, weight: .bold)).tracking(1)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Theme.State.confirmed.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(Theme.State.confirmed)
                    }
                }

                // Main first means the times below it are no longer a countdown, so each row says
                // in words where it sits relative to the main alarm.
                if let distance = store.distanceFromMain(target.device) {
                    Text(distance).font(.system(size: 11)).foregroundStyle(Theme.greyDim)
                }

                // Each device's own time, editable here rather than nowhere. The offsets have
                // existed since the first build and no screen ever reached them.
                steppers

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
                get: { store.schedule.rule(for: target.device)?.isEnabled ?? true },
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

    /// Its own property because the row's body grew past what the type checker will chew through
    /// in one expression, which is the usual sign a body is doing more than one job.
    private var steppers: some View {
        HStack(spacing: 6) {
            Button { shift(-5) } label: { StepChip("−5") }
                .buttonStyle(.plain)
            Button { shift(5) } label: { StepChip("+5") }
                .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    private func shift(_ minutes: Int) {
        let moved = WallClockTime(
            minutesSinceMidnight: target.localTime.minutesSinceMidnight + minutes
        )
        store.setDeviceTime(moved, for: target.device)
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
    /// "Off" when he switched it off, "Not connected" when it has no account. Different problems
    /// with different fixes, and a single greyed row that says neither is a puzzle.
    let reason: String

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.greyDim.opacity(0.4)).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.displayName).font(.system(size: 15, weight: .semibold))
                Text(reason).themeLabel()
            }
            Spacer()
            Toggle("", isOn: Binding(get: { false }, set: { store.setEnabled($0, for: device) }))
                .labelsHidden()
                .tint(Theme.State.confirmed)
                // Switching on a leg with no account would report success and write nothing. The
                // fix for this row is in Connections, not here.
                .disabled(!store.isConnected(device))
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

/// A small stepper face, shared by the routine cards and the device rows.
///
/// Was a private method on `CascadeRow`, which the routine cards could not see. Two views needing
/// the same face is what a view is for.
private struct StepChip: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.numeral(13))
            .frame(width: 40, height: 30)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1))
            .foregroundStyle(.white)
    }
}

/// One routine on the home screen, as a sentence. Nothing here is tappable on its own: the whole
/// strip is one button into `RoutinesView`.
///
/// Read only on purpose. This block exists so the week is **visible**, which Alex asked for, and the
/// editing lives on its own screen, which is what makes the two scopes tellable apart.
private struct WeekStripRow: View {
    let routine: Routine
    let isNext: Bool

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isNext ? AnyShapeStyle(Theme.State.confirmed) : AnyShapeStyle(Theme.line))
                .frame(width: 3, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(routine.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(routine.weekdays.isEmpty ? Theme.greyDim : Color.white)
                Text(routine.weekdays.isEmpty ? "no days, never fires" : "every \(routine.daysSentence)")
                    .font(.system(size: 12)).foregroundStyle(Theme.greyDim)
            }

            Spacer(minLength: 8)

            Text(routine.weekdays.isEmpty ? "--:--" : routine.time.hhmm)
                .font(Theme.numeral(20))
                .foregroundStyle(routine.weekdays.isEmpty ? Theme.greyDim : Color.white)
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
    }
}

/// The wheel for tomorrow, and the only thing it can do is bend tomorrow.
///
/// It is a sheet rather than a block on the home screen because a wheel is the most authoritative
/// "this is the setting" control iOS has, and wiring the most authoritative control to the most
/// temporary change is what made the whole screen unreadable. In a sheet with that sentence written
/// across the top, the scope arrives with the control.
///
/// The scope is **not** asked as a question first. Alex raised Apple's upfront "this alarm only or
/// all alarms" prompt and the reasoning against it still holds: at 23:41 the intent is almost always
/// tomorrow, and a question answered the same way nine times in ten is a tax rather than a
/// safeguard. So it bends, says so, and offers to promote afterwards on the home screen, where the
/// consequence is visible rather than hypothetical.
@MainActor
private struct TomorrowPicker: View {
    @Environment(ScheduleStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Screen {
            VStack(alignment: .leading, spacing: 12) {
                Text(store.nextAlarmHeadline)
                    .font(.system(size: 23, weight: .bold)).tracking(-0.5)
                    .padding(.top, 8)

                Text(store.next?.routineName.map { "Changes this morning only. Your \($0) routine stays as it is." }
                     ?? "Changes this morning only.")
                    .font(.system(size: 14)).foregroundStyle(Theme.grey)

                DatePicker(
                    "Wake time",
                    selection: Binding(
                        get: {
                            var parts = DateComponents()
                            parts.hour = store.next?.time.hour ?? 7
                            parts.minute = store.next?.time.minute ?? 0
                            return Calendar.current.date(from: parts) ?? Date()
                        },
                        set: {
                            let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                            store.bendNextMorning(to: WallClockTime(hour: parts.hour ?? 7,
                                                                    minute: parts.minute ?? 0))
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .colorScheme(.dark)
                .frame(maxWidth: .infinity)
            }
        } footer: {
            SolidButton(title: "Done") { dismiss() }
        }
    }
}
