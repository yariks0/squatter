import SwiftData
import SwiftUI

@main
struct SquatterApp: App {
    @State private var auth = AuthSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .task { auth.start() }
        }
        .modelContainer(for: [WorkoutSession.self, RemoteWorkoutSummary.self])
    }
}
