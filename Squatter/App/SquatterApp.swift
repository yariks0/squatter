import SwiftData
import SwiftUI

@main
struct SquatterApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .modelContainer(for: WorkoutSession.self)
    }
}
