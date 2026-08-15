import SwiftUI

/// The preview and confirm gate. Shows what would go out before anything goes out.
///
/// `preview` on each adapter performs no I/O at all, so opening this sheet cannot send anything.
///
/// That same property is why the two remote bodies are **reconstructions** rather than the real
/// request. Both legs read, edit and resend, so the real body is built from the account's own
/// schedule, which this screen cannot fetch without doing the I/O it promises not to do. It says so
/// on screen rather than implying otherwise, because the one thing worse than an approximate
/// preview is an approximate preview that claims to be exact.
@MainActor
struct WritePreviewSheet: View {
    @Environment(ScheduleStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let device: DeviceID

    private var preview: WritePreview? { store.preview(for: device) }
    private var target: ResolvedTarget? { store.target(for: device) }

    var body: some View {
        Screen(title: "Preview", onBack: { dismiss() }) {
            VStack(alignment: .leading, spacing: 16) {
                if preview?.reconstructed == true {
                    Notice(.good, title: "Nothing has been sent.",
                           "The address, the method and the values are exact. The body is rebuilt from your settings, not read from the account: this leg edits the schedule the service already has, so the real request also carries that schedule's own fields and its time format.")
                } else {
                    Notice(.good, title: "Nothing has been sent.",
                           "This is built by the same code that builds the real request.")
                }

                if let target {
                    VStack(alignment: .leading, spacing: 0) {
                        detail("Local time", target.localTime.hhmm)
                        detail("Days", Locale.Weekday.displayOrder
                            .filter { target.weekdays.contains($0) }
                            .map(\.shortLabel).joined(separator: " "))
                        detail("Next", target.nextOccurrence.formatted(date: .abbreviated, time: .shortened))
                        detail("UTC offset", target.utcOffsetString)
                    }
                    .padding(.vertical, 4)
                    .themeCard()

                    if target.crossesMidnight {
                        Notice(.warn, title: "This one fires the night before.",
                               "The offset moves it onto the \(target.dayShift < 0 ? "previous" : "next") day, so its days shift to match.")
                    }
                }

                if let preview {
                    Text(preview.summary).font(.system(size: 15)).foregroundStyle(Theme.grey)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(preview.method)  \(preview.url)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.State.target)
                        if let body = preview.body {
                            Text(body)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.grey)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .themeCard(radius: Theme.radiusRow)
                }

                Notice(title: "What can never be sent.",
                       "Each connection is limited to a short list of allowed addresses. Changing the bed temperature, running the pump, moving the frame and deleting anything are all refused before they leave the phone, including by mistake.")
            }
            .padding(.bottom, 20)
        } footer: {
            SolidButton(title: "Close") { dismiss() }
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).themeLabel()
            Spacer()
            Text(value).font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
    }
}
