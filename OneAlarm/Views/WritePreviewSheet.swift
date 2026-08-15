import SwiftUI

/// The preview and confirm gate. Shows exactly what would go out before anything goes out.
///
/// `preview` on each adapter performs no I/O at all, so opening this sheet cannot send anything,
/// and the body shown here is built by the same code path that builds the real request.
@MainActor
struct WritePreviewSheet: View {
    @Environment(ScheduleStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let device: DeviceID

    private var preview: WritePreview? { store.preview(for: device) }
    private var target: ResolvedTarget? { store.target(for: device) }

    var body: some View {
        NavigationStack {
            List {
                if let target {
                    Section("Resolved") {
                        LabeledContent("Local time", value: target.localTime.hhmm)
                        LabeledContent("Days", value: dayList(target))
                        LabeledContent("Next", value: target.nextOccurrence.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("UTC offset", value: target.utcOffsetString)
                        if target.crossesMidnight {
                            Label(
                                "The offset moves this onto the \(target.dayShift < 0 ? "previous" : "next") day, so the days above are shifted to match.",
                                systemImage: "arrow.turn.down.right"
                            )
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        }
                    }
                }

                if let preview {
                    Section("What gets sent") {
                        Text(preview.summary).font(.callout)
                        LabeledContent("Method", value: preview.method)
                        Text(preview.url)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    if let body = preview.body {
                        Section("Body") {
                            Text(body)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                Section {
                    Text("Nothing has been sent. Close this and use Set all alarms to write for real.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(device.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func dayList(_ target: ResolvedTarget) -> String {
        Locale.Weekday.displayOrder
            .filter { target.weekdays.contains($0) }
            .map(\.shortLabel)
            .joined(separator: " ")
    }
}
