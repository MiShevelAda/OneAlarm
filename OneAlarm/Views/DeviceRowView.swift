import SwiftUI

@MainActor
struct DeviceRowView: View {
    @Environment(ScheduleStore.self) private var store

    let rule: DeviceRule
    let onPreview: () -> Void

    private var target: ResolvedTarget? { store.target(for: rule.device) }
    private var status: DeviceSyncStatus { store.status[rule.device] ?? .idle }
    private var authState: AuthState { store.authStates[rule.device] ?? .notConfigured }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: rule.device.symbolName)
                    .font(.system(size: 18))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(rule.isEnabled ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.device.displayName)
                        .font(.body.weight(.medium))
                    Text(rule.device.rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let target, rule.isEnabled {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(target.localTime.hhmm)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                        if target.crossesMidnight {
                            Text("previous day")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Toggle("", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { store.setEnabled($0, for: rule.device) }
                ))
                .labelsHidden()
            }

            if rule.isEnabled {
                offsetStepper
                statusLine
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onLongPressGesture(perform: onPreview)
    }

    private var offsetStepper: some View {
        HStack(spacing: 12) {
            Text(offsetLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 92, alignment: .leading)

            Stepper(
                offsetLabel,
                value: Binding(
                    get: { rule.offsetMinutes },
                    set: { store.setOffset($0, for: rule.device) }
                ),
                in: -120...120,
                step: 5
            )
            .labelsHidden()

            Spacer()

            Button("Preview", action: onPreview)
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.leading, 44)
    }

    private var offsetLabel: String {
        if rule.offsetMinutes == 0 { return "At wake time" }
        let magnitude = abs(rule.offsetMinutes)
        return rule.offsetMinutes < 0 ? "\(magnitude) min earlier" : "\(magnitude) min later"
    }

    @ViewBuilder
    private var statusLine: some View {
        let text = statusText
        if !text.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: statusSymbol)
                    .font(.caption2)
                Text(text)
                    .font(.caption)
                Spacer()
            }
            .foregroundStyle(statusColor)
            .padding(.leading, 44)
        }
    }

    private var statusText: String {
        switch status {
        case .idle:
            if case .needsReauth(let reason) = authState { return reason }
            if rule.device.requiresCredentials, authState == .notConfigured { return "Not connected" }
            return ""
        case .writing: return "Writing"
        case .verifying: return "Checking it landed"
        case .done(let message): return message
        case .warning(let message): return message
        case .failed(let message): return message
        }
    }

    private var statusSymbol: String {
        switch status {
        case .idle:
            if case .needsReauth = authState { return "exclamationmark.triangle" }
            return "link.badge.plus"
        case .writing, .verifying: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .idle:
            if case .needsReauth = authState { return .orange }
            return .secondary
        case .writing, .verifying: return .secondary
        case .done: return .green
        case .warning: return .orange
        case .failed: return .red
        }
    }
}
