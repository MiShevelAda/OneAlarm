import SwiftUI

@main
@MainActor
struct OneAlarmApp: App {
    @State private var store = ScheduleStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .task {
                    await store.refreshAuthStates()
                }
        }
    }
}
