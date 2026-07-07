import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No workouts yet",
                systemImage: "figure.strengthtraining.functional",
                description: Text("Record your first set to get form feedback.")
            )
            .navigationTitle("Squatter")
        }
    }
}

#Preview {
    HomeView()
}
