import SwiftUI

/// Every routine, and the only place any of them can be edited.
///
/// Alex, 2026-08-16: *"the function is not very user friendly. We need to find a better way how to
/// set up routines. We need to make it easier and make it more clear what is a routine and what is
/// not a routine."*
///
/// The cause was not decoration, it was scope. The home screen carried **three** time controls with
/// three different meanings and nothing separating them: a wheel that bent tomorrow, a picker inside
/// each routine card that changed the routine, and a pair of steppers on each device row that moved
/// that device's lead. Three identical looking affordances, three different lifetimes. There is no
/// wording that fixes that while they sit in one scrolling column.
///
/// So they are split by place, which is the one separation that cannot be misread. **The home screen
/// is tomorrow.** This screen is the week. Nothing here affects only tomorrow and nothing on the
/// home screen changes a routine without saying so first.
@MainActor
struct RoutinesView: View {
    @Environment(ScheduleStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// The routine opened for editing. One at a time, so there is never a second wheel on screen.
    @State private var expanded: String?
    @State private var confirmingDelete: String?

    var body: some View {
        Screen(title: "My week", onBack: { dismiss() }) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your routines")
                        .font(.system(size: 27, weight: .bold)).tracking(-0.6)
                    Text("A routine is a set of days with one wake time. Everything here repeats every week until you change it. To move one morning only, go back and use the buttons under tomorrow's time.")
                        .font(.system(size: 15)).foregroundStyle(Theme.grey)
                }
                .padding(.top, 4)

                ForEach(store.schedule.routines) { routine in
                    RoutineEditor(
                        routine: routine,
                        isNext: store.next?.routineID == routine.id,
                        isExpanded: expanded == routine.id,
                        onToggleExpanded: { expanded = expanded == routine.id ? nil : routine.id },
                        onDelete: { confirmingDelete = routine.id }
                    )
                }

                addButton

                if let uncovered = store.uncoveredDays, !uncovered.isEmpty {
                    Notice(.warn, title: "No alarm on \(uncovered).",
                           "Those days belong to no routine, so nothing will wake you on them. That is a real setting if you meant it, and a gap if you did not.")
                }

                Notice(title: "A day belongs to one routine only.",
                       "Tapping a day here takes it from whichever routine had it. Two routines claiming one day would be two answers to \"when do I wake on Tuesday\", and nothing could pick between them.")
            }
            .padding(.bottom, 20)
        } footer: {
            SolidButton(title: "Done") { dismiss() }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(get: { confirmingDelete != nil },
                                 set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = confirmingDelete { store.deleteRoutine(id) }
                confirmingDelete = nil
            }
            Button("Keep it", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text(deletionMessage)
        }
    }

    /// The routine about to be deleted, by name and by days.
    ///
    /// It used to read "Delete this routine?" with a generic body. With three routines on screen
    /// that names none of them, and this is the only destructive action in the app: it ends with an
    /// alarm switched off on his bed on the next sync. Everywhere else in this project a destructive
    /// act is named out loud, and this was the one place it was not.
    private var deletionTitle: String {
        guard let routine = doomed else { return "Delete this routine?" }
        return "Delete \(routine.displayName)?"
    }

    private var deletionMessage: String {
        guard let routine = doomed, !routine.weekdays.isEmpty else {
            return "It has no days, so nothing changes on any device."
        }
        return "Every \(routine.daysSentence) stops having an alarm. Those days are not handed to another routine, because that would move a morning you did not ask to move. On your bed, the alarm this routine owns is switched off on the next sync rather than deleted, so you can turn it back on in the Eight Sleep app."
    }

    private var doomed: Routine? {
        guard let id = confirmingDelete else { return nil }
        return store.schedule.routines.first { $0.id == id }
    }

    private var addButton: some View {
        Button {
            // Opened straight away. A new card that appears collapsed reads as nothing having
            // happened, and the days it was given are the first thing worth seeing.
            expanded = store.addRoutine()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                Text("Add a routine").font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.lineStrong, lineWidth: 1))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

/// One routine, editable.
///
/// Collapsed it is a sentence: a name, its days, its time. Expanded it is the two controls that
/// change it. Collapsing by default matters because the previous version showed every routine's day
/// chips and time at once, which put four editable controls on a screen he was trying to read.
@MainActor
private struct RoutineEditor: View {
    @Environment(ScheduleStore.self) private var store

    let routine: Routine
    let isNext: Bool
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onDelete: () -> Void

    private var hasDays: Bool { !routine.weekdays.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isExpanded {
                chips
                timePicker
                comfortSection
                deleteRow
            } else {
                summary
            }
        }
        .padding(15)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
            .strokeBorder(isNext ? Theme.State.confirmed.opacity(0.45) : Theme.line, lineWidth: 1))
    }

    private var header: some View {
        Button(action: onToggleExpanded) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                // Derived from the days, never stored. Alex: "don't redefine the name of the
                // routine." A stored "Weekdays" is true when written and a lie the moment the days
                // change, with nothing to warn you.
                Text(routine.displayName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(hasDays ? Color.white : Theme.greyDim)

                if isNext {
                    Text("NEXT")
                        .font(.system(size: 9, weight: .bold)).tracking(1)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.State.confirmed.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(Theme.State.confirmed)
                }

                Spacer(minLength: 6)

                Text(hasDays ? routine.time.hhmm : "no days")
                    .font(Theme.numeral(hasDays ? 26 : 15))
                    .foregroundStyle(hasDays ? Color.white : Theme.greyDim)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.greyDim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var summary: some View {
        Text(hasDays ? "Every \(routine.daysSentence)" : "No days, so this routine never fires. Tap to give it some.")
            .font(.system(size: 13))
            .foregroundStyle(Theme.grey)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Which days").themeLabel()
            HStack(spacing: 6) {
                ForEach(Locale.Weekday.displayOrder, id: \.calendarIndex) { day in
                    dayChip(day)
                }
            }
        }
    }

    private func dayChip(_ day: Locale.Weekday) -> some View {
        let on = routine.weekdays.contains(day)
        // Named, so taking a day from another routine is visible before the tap rather than after.
        let owner = store.schedule.routines.first { $0.id != routine.id && $0.weekdays.contains(day) }
        return Button {
            store.toggleDay(day, in: routine.id)
        } label: {
            VStack(spacing: 2) {
                Text(day.shortLabel).font(.system(size: 12, weight: .semibold))
                if !on, owner != nil {
                    Circle().fill(Theme.greyDim).frame(width: 3, height: 3)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(on ? Color.white.opacity(0.14) : Color.white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(on ? Theme.lineStrong : Theme.line, lineWidth: 1))
            .foregroundStyle(on ? Color.white : Theme.greyDim)
        }
        .buttonStyle(.plain)
    }

    /// A wheel, and it is the only wheel in the app that changes a routine.
    ///
    /// It is safe to be a wheel here precisely because of where it is. On the home screen the same
    /// control meant "bend tomorrow", and having both was the confusion Alex named. There is now one
    /// wheel per screen and each screen has one scope.
    /// **Temperature, vibration and smart wake, on the routine.**
    ///
    /// Alex reversed his own rule to get this: *"only the modifications of temperature, vibration
    /// etc should be done in the respective app"*, 16 August, replaced on 20 August by *"for eight
    /// sleep please add following options when editing the routine"*.
    ///
    /// **Every control is three-way, not two.** `Leave` is the default and means OneAlarm does not
    /// touch that field at all, which is what every routine does today and what a routine he never
    /// opens must keep doing. A plain on/off toggle would have no way to express "as it is", so
    /// merely opening this screen would start overwriting settings he made in Eight Sleep's app.
    /// That is the failure this whole section was banned to prevent, and a two state control would
    /// have reintroduced it through the UI instead of the wire.
    @ViewBuilder
    private var comfortSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("On your bed").themeLabel()

            tristate("Temperature wake", value: routine.comfort.thermalEnabled) {
                var next = routine.comfort
                next.thermalEnabled = $0
                store.setComfort(next, routineID: routine.id)
            }

            tristate("Vibration", value: routine.comfort.vibrationEnabled) {
                var next = routine.comfort
                next.vibrationEnabled = $0
                store.setComfort(next, routineID: routine.id)
            }

            tristate("Smart alarm", value: routine.comfort.smartEnabled) {
                var next = routine.comfort
                next.smartEnabled = $0
                store.setComfort(next, routineID: routine.id)
            }

            Notice("Leave means OneAlarm does not touch that setting, so whatever you chose in the Eight Sleep app stays. Strength and pattern are still set there.")
        }
    }

    /// On, Off, or Leave alone. The third option is the point.
    private func tristate(
        _ label: String,
        value: Bool?,
        onChange: @escaping (Bool?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 15, weight: .semibold))
            HStack(spacing: 8) {
                // Keyed on the title, not `\.0`. A key path to an **unlabelled** tuple element is the
                // only one of its kind in this tree and nothing here can compile-check it, and the
                // titles are unique anyway. The labelled form is what the rest of the app uses.
                ForEach(["Leave", "On", "Off"], id: \.self) { title in
                    let option: Bool? = title == "Leave" ? nil : (title == "On")
                    Button {
                        onChange(option)
                    } label: {
                        Text(title)
                            .font(.system(size: 13, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(value == option ? Theme.State.confirmed.opacity(0.18) : Theme.card,
                                        in: Capsule())
                            .overlay(Capsule().strokeBorder(
                                value == option ? Theme.State.confirmed : Theme.lineStrong, lineWidth: 1))
                            .foregroundStyle(value == option ? Theme.State.confirmed : Theme.grey)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var timePicker: some View {
        if hasDays {
            VStack(alignment: .leading, spacing: 4) {
                Text("Wake at").themeLabel()
                DatePicker(
                    "Routine time",
                    selection: Binding(
                        get: {
                            var parts = DateComponents()
                            parts.hour = routine.time.hour
                            parts.minute = routine.time.minute
                            return Calendar.current.date(from: parts) ?? Date()
                        },
                        set: {
                            let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                            store.setRoutineTime(
                                WallClockTime(hour: parts.hour ?? 7, minute: parts.minute ?? 0),
                                routineID: routine.id
                            )
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .colorScheme(.dark)
                .frame(height: 120)
                .frame(maxWidth: .infinity)

                Text("Every \(routine.daysSentence), from now on.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.greyDim)
            }
        }
    }

    private var deleteRow: some View {
        Button(action: onDelete) {
            Text("Delete this routine")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.State.failed)
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.plain)
    }
}
