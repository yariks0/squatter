import SwiftUI

struct HomeView: View {
    @State private var lastRecording: RecordingResult?

    var body: some View {
        NavigationStack {
            VStack {
                ContentUnavailableView(
                    "No workouts yet",
                    systemImage: "figure.strengthtraining.functional",
                    description: Text("Record your first set to get form feedback.")
                )
                NavigationLink {
                    RecordView { result in
                        lastRecording = result
                    }
                } label: {
                    Label("Record a set", systemImage: "record.circle")
                        .font(.title3.bold())
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 32)
            }
            .navigationTitle("Squatter")
        }
    }
}

#Preview {
    HomeView()
}
