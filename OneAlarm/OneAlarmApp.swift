import SwiftUI
import UIKit

@main
@MainActor
struct OneAlarmApp: App {
    @State private var store = ScheduleStore()
    @AppStorage("OneAlarm.hasOnboarded") private var hasOnboarded = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if hasOnboarded {
                    CascadeView()
                } else {
                    OnboardingView { hasOnboarded = true }
                }
            }
            .environment(store)
            .preferredColorScheme(.dark)
            .task {
                await store.refreshAuthStates()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await store.refreshAuthStates()
                    await store.applyIfClockMoved()
                }
            }
            // The Whoop leg writes a fixed UTC offset with no daylight saving awareness, so a zone
            // change or a transition has to be re-sent or the strap wakes him an hour out.
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                Task { await store.applyIfClockMoved() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                Task { await store.applyIfClockMoved() }
            }
        }
    }
}
