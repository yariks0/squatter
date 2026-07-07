import SwiftUI

struct HomeView: View {
    @State private var path = NavigationPath()

    private enum Route: Hashable {
        case record
        case analyze(id: UUID)
    }

    // RecordingResult isn't Hashable; keep the pending one alongside the path.
    @State private var pendingRecording: RecordingResult?

    var body: some View {
        NavigationStack(path: $path) {
            VStack {
                ContentUnavailableView(
                    "No workouts yet",
                    systemImage: "figure.strengthtraining.functional",
                    description: Text("Record your first set to get form feedback.")
                )
                Button {
                    path.append(Route.record)
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
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .record:
                    RecordView { result in
                        pendingRecording = result
                        path.append(Route.analyze(id: UUID()))
                    }
                case .analyze:
                    if let recording = pendingRecording {
                        AnalysisView(recording: recording) { _ in }
                    } else {
                        ContentUnavailableView("No recording", systemImage: "video.slash")
                    }
                }
            }
        }
    }
}

#Preview {
    HomeView()
}
