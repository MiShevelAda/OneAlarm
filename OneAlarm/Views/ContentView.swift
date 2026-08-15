import SwiftUI

@MainActor
struct ContentView: View {
    @Environment(ScheduleStore.self) private var store

    @State private var showingConnections = false
    @State private var previewDevice: DeviceID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    masterTimeSection
                    weekdaySection
                    deviceSection
                    applyButton
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("OneAlarm")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingConnections = true
                    } label: {
                        Image(systemName: "person.badge.key")
                    }
                    .accessibilityLabel("Connections")
                }
            }
            .sheet(isPresented: $showingConnections) {
                ConnectionsView()
                    .environment(store)
            }
            .sheet(item: $previewDevice) { device in
                WritePreviewSheet(device: device)
                    .environment(store)
            }
        }
    }

    // MARK: Master time

    private var masterTimeSection: some View {
        VStack(spacing: 10) {
            Text("Wake at")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            DatePicker(
                "Wake time",
                selection: Binding(
                    get: { dateFromMaster() },
                    set: { store.setMasterTime(wallClock(from: $0)) }
                ),
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.wheel)
            .labelsHidden()

            if let lead = RulesEngine.leadMinutes(for: store.targets), lead > 0 {
                Text("The chain starts \(lead) minutes earlier.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .padding(.top, 8)
    }

    private func dateFromMaster() -> Date {
        var components = DateComponents()
        components.hour = store.schedule.masterTime.hour
        components.minute = store.schedule.masterTime.minute
        return Calendar.current.date(from: components) ?? Date()
    }

    private func wallClock(from date: Date) -> WallClockTime {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return WallClockTime(hour: components.hour ?? 7, minute: components.minute ?? 0)
    }

    // MARK: Weekdays

    private var weekdaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Repeat")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(Locale.Weekday.displayOrder, id: \.calendarIndex) { day in
                    let selected = store.schedule.weekdays.contains(day)
                    Button {
                        store.toggleWeekday(day)
                    } label: {
                        Text(day.shortLabel)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(
                                selected ? Color.accentColor : Color(.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Devices

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Devices")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(store.schedule.rules.enumerated()), id: \.element.id) { index, rule in
                    DeviceRowView(rule: rule) {
                        previewDevice = rule.device
                    }
                    if index < store.schedule.rules.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: Apply

    private var applyButton: some View {
        Button {
            Task { await store.apply() }
        } label: {
            HStack(spacing: 8) {
                if store.isSyncing {
                    ProgressView().tint(.white)
                }
                Text(store.isSyncing ? "Setting alarms" : "Set all alarms")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(store.isSyncing)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let lastSyncedAt = store.lastSyncedAt {
                Text("Last set \(lastSyncedAt.formatted(date: .omitted, time: .shortened))")
            }
            Text("The iPhone alarm works on its own. The other two need connecting.")
                .multilineTextAlignment(.center)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
