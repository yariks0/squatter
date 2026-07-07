import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]

    @State private var path = NavigationPath()
    // RecordingResult isn't Hashable; the pending one lives alongside the path.
    @State private var pendingRecording: RecordingResult?

    private enum Route: Hashable {
        case setup
        case record
        case analyze(id: UUID)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if sessions.isEmpty {
                    VStack {
                        ContentUnavailableView(
                            "No workouts yet",
                            systemImage: "figure.strengthtraining.functional",
                            description: Text("Record your first set to get form feedback.")
                        )
                        recordButton
                            .padding(.bottom, 32)
                    }
                } else {
                    List {
                        ForEach(sessions) { session in
                            NavigationLink(value: session.persistentModelID) {
                                SessionRow(session: session)
                            }
                        }
                        .onDelete(perform: deleteSessions)
                    }
                    .safeAreaInset(edge: .bottom) {
                        recordButton
                            .padding(.bottom, 8)
                    }
                }
            }
            .navigationTitle("Squatter")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .setup:
                    SetupGuideView { path.append(Route.record) }
                case .record:
                    RecordView { result in
                        pendingRecording = result
                        path.append(Route.analyze(id: UUID()))
                    }
                case .analyze:
                    if let recording = pendingRecording {
                        AnalysisView(recording: recording) { analysis in
                            save(recording: recording, analysis: analysis)
                        }
                    } else {
                        ContentUnavailableView("No recording", systemImage: "video.slash")
                    }
                }
            }
            .navigationDestination(for: PersistentIdentifier.self) { id in
                if let session = modelContext.model(for: id) as? WorkoutSession,
                   let analysis = session.analysis(),
                   let videoURL = session.videoURL {
                    ReportView(analysis: analysis, videoURL: videoURL)
                        .navigationTitle(session.date.formatted(date: .abbreviated, time: .shortened))
                        .navigationBarTitleDisplayMode(.inline)
                } else {
                    ContentUnavailableView(
                        "Session unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("This session's data could not be loaded.")
                    )
                }
            }
        }
    }

    private var recordButton: some View {
        Button {
            path.append(Route.setup)
        } label: {
            Label("Record a set", systemImage: "record.circle")
                .font(.title3.bold())
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
    }

    private func save(recording: RecordingResult, analysis: SquatAnalysis) {
        guard let session = try? WorkoutSession(date: .now, recording: recording, analysis: analysis)
        else { return }
        modelContext.insert(session)
        try? modelContext.save()
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            sessions[index].deleteFiles()
            modelContext.delete(sessions[index])
        }
        try? modelContext.save()
    }
}

private struct SessionRow: View {
    let session: WorkoutSession

    var body: some View {
        HStack(spacing: 14) {
            Text("\(session.score)")
                .font(.title3.bold())
                .foregroundStyle(scoreColor)
                .frame(width: 44, height: 44)
                .background(scoreColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(session.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.bold())
                HStack(spacing: 6) {
                    Text("\(session.repCount) rep\(session.repCount == 1 ? "" : "s")")
                    if session.usedLiDAR {
                        Label("LiDAR", systemImage: "sensor.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var scoreColor: Color {
        switch session.score {
        case 85...: .green
        case 60 ..< 85: .orange
        default: .red
        }
    }
}

#Preview {
    HomeView()
        .modelContainer(for: WorkoutSession.self, inMemory: true)
}
