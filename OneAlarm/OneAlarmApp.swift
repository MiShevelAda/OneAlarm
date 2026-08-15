import SwiftUI
import UIKit

@main
@MainActor
struct OneAlarmApp: App {
    @State private var store = ScheduleStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .task {
                    // Ask here rather than inside the fan out. The permission alert has no timeout,
                    // so awaiting it from a task group that the Apply button is waiting on hangs
                    // the button forever if the alert is dismissed without an answer.
                    if await store.alarmKit.needsAuthorizationPrompt {
                        await store.alarmKit.requestAuthorization()
                    }
                    await store.refreshAuthStates()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await store.refreshAuthStates()
                        await store.applyIfClockMoved()
                    }
                }
                // The Whoop leg writes a fixed UTC offset with no daylight saving awareness, so a
                // zone change or a transition has to be re-sent or the strap wakes him an hour out.
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                    Task { await store.applyIfClockMoved() }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    Task { await store.applyIfClockMoved() }
                }
        }
    }
}
