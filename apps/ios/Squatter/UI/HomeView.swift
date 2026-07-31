import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AuthSession.self) private var auth
    @Query(sort: \WorkoutSession.date, order: .reverse) private var sessions: [WorkoutSession]
    /// Sessions pulled from the backend that have no recording on this device
    /// (another phone, or after a reinstall).
    @Query(sort: \RemoteWorkoutSummary.date, order: .reverse)
    private var remoteSummaries: [RemoteWorkoutSummary]

    @State private var path = NavigationPath()
    /// Recordings on disk that no saved session references yet.
    @State private var unanalyzed: [URL] = []

    /// Local + remote sessions merged for the dashboard, local winning any
    /// id collision (it carries the full analysis).
    private var allSummaries: [SessionSummary] {
        let local = sessions.map(SessionSummary.init)
        let localIDs = Set(local.map(\.id))
        let remote = remoteSummaries.map(SessionSummary.init).filter { !localIDs.contains($0.id) }
        return (local + remote).sorted { $0.date > $1.date }
    }

    // The recording rides inside the route: passing it through view state
    // races the navigation push and the destination can render before the
    // write lands ("No recording").
    private enum Route: Hashable {
        case setup(ActivityType)
        case record(ActivityType)
        /// Post-record review: play back and optionally trim before analysis.
        case review(RecordingResult, ActivityType)
        case analyze(RecordingResult, ActivityType)
        case attempt(fileName: String)
        case bodyScanGuide
        case bodyScanRecord
        case bodyScanResult(RecordingResult)
    }

    @State private var choosingActivity = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if sessions.isEmpty && unanalyzed.isEmpty && remoteSummaries.isEmpty {
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
                        if !allSummaries.isEmpty {
                            Section {
                                ProgressDashboard(sessions: allSummaries)
                            } header: {
                                Text("Progress")
                            }
                        }
                        if !unanalyzed.isEmpty {
                            Section("Recorded — not analyzed") {
                                ForEach(unanalyzed, id: \.self) { url in
                                    NavigationLink(value: Route.attempt(fileName: url.lastPathComponent)) {
                                        AttemptRow(videoURL: url)
                                    }
                                }
                                .onDelete(perform: deleteAttempts)
                            }
                        }
                        if !sessions.isEmpty || !remoteSummaries.isEmpty {
                            Section("History") {
                                ForEach(sessions) { session in
                                    NavigationLink(value: session.persistentModelID) {
                                        SessionRow(session: session)
                                    }
                                }
                                .onDelete(perform: deleteSessions)
                                // Remote-only sessions: no recording on this
                                // device, so no report to open — shown for
                                // continuity with a cloud marker.
                                ForEach(remoteSummaries) { summary in
                                    RemoteSummaryRow(summary: summary)
                                }
                            }
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        recordButton
                            .padding(.bottom, 8)
                    }
                }
            }
            .onAppear(perform: refreshUnanalyzed)
            .task { await SyncEngine.shared.pull(into: modelContext) }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    accountMenu
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .setup(let activity):
                    SetupGuideView(activity: activity) { path.append(Route.record(activity)) }
                case .record(let activity):
                    RecordView(activity: activity) { result in
                        path.append(Route.review(result, activity))
                    }
                case .review(let recording, let activity):
                    AttemptReviewView(
                        videoURL: recording.videoURL,
                        depthSidecarURL: recording.depthSidecarURL,
                        initialActivity: activity
                    ) { result, chosen in
                        path.append(Route.analyze(result, chosen))
                    }
                case .analyze(let recording, let activity):
                    AnalysisView(recording: recording, activity: activity) { analysis in
                        save(recording: recording, analysis: analysis)
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                path = NavigationPath()
                            } label: {
                                Label("Home", systemImage: "house.fill")
                            }
                        }
                    }
                case .bodyScanGuide:
                    BodyScanGuideView { path.append(Route.bodyScanRecord) }
                case .bodyScanRecord:
                    RecordView(activity: .squat) { result in
                        path.append(Route.bodyScanResult(result))
                    }
                case .bodyScanResult(let recording):
                    BodyScanResultView(recording: recording) {
                        path = NavigationPath()
                    }
                case .attempt(let fileName):
                    if let directory = try? FileLocations.recordingsDirectory() {
                        let videoURL = directory.appendingPathComponent(fileName)
                        let depthURL = videoURL.deletingPathExtension()
                            .appendingPathExtension(DepthSidecar.fileExtension)
                        AttemptReviewView(
                            videoURL: videoURL,
                            depthSidecarURL: FileManager.default.fileExists(atPath: depthURL.path)
                                ? depthURL : nil
                        ) { result, chosen in
                            path.append(Route.analyze(result, chosen))
                        }
                    } else {
                        ContentUnavailableView("Recording unavailable", systemImage: "video.slash")
                    }
                }
            }
            .navigationDestination(for: PersistentIdentifier.self) { id in
                if let session = modelContext.model(for: id) as? WorkoutSession {
                    SessionReportView(session: session)
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

    /// The emblem doubles as a menu: body scan plus the account actions —
    /// the logo is the only toolbar affordance.
    private var accountMenu: some View {
        Menu {
            Button {
                path.append(Route.bodyScanGuide)
            } label: {
                Label("Body scan", systemImage: "person.and.background.dotted")
            }
            switch auth.state {
            case let .loggedIn(email):
                Section(email) {
                    Button("Log out", role: .destructive) { auth.logout() }
                }
            case .offline:
                Section("Offline") {
                    Button("Sign in to sync") { auth.showLogin() }
                }
            case .checking, .loggedOut:
                Button("Log out", role: .destructive) { auth.logout() }
            }
        } label: {
            KodoEmblem(size: 36)
        }
    }

    private var recordButton: some View {
        Button {
            choosingActivity = true
        } label: {
            Label("Record a set", systemImage: "record.circle")
        }
        .buttonStyle(KodoProminentButtonStyle())
        .sheet(isPresented: $choosingActivity) {
            LiftChooserSheet { activity in
                choosingActivity = false
                path.append(Route.setup(activity))
            }
            .presentationDetents([.height(330)])
            .presentationDragIndicator(.visible)
        }
    }

    private func save(recording: RecordingResult, analysis: SquatAnalysis) {
        guard let session = try? WorkoutSession(date: .now, recording: recording, analysis: analysis)
        else { return }
        modelContext.insert(session)
        try? modelContext.save()
        SyncEngine.shared.pushSession(session)
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            SyncEngine.shared.deleteSession(videoFileName: sessions[index].videoFileName)
            sessions[index].deleteFiles()
            modelContext.delete(sessions[index])
        }
        try? modelContext.save()
        refreshUnanalyzed()
    }

    private func refreshUnanalyzed() {
        let linked = Set(sessions.map(\.videoFileName))
        let all = (try? FileLocations.recordedVideoURLs()) ?? []
        unanalyzed = all.filter { !linked.contains($0.lastPathComponent) }
    }

    private func deleteAttempts(at offsets: IndexSet) {
        for index in offsets {
            let videoURL = unanalyzed[index]
            try? FileManager.default.removeItem(at: videoURL)
            let depthURL = videoURL.deletingPathExtension()
                .appendingPathExtension(DepthSidecar.fileExtension)
            try? FileManager.default.removeItem(at: depthURL)
            CoachReportStore.delete(for: videoURL)
        }
        refreshUnanalyzed()
    }
}

/// Saved-session report with a toolbar action to re-run the analysis over
/// the original recording — for sessions saved before pipeline or threshold
/// changes. Re-analysis covers the whole recording; a trim window chosen at
/// record time is not persisted on the session.
private struct SessionReportView: View {
    @Environment(\.modelContext) private var modelContext
    let session: WorkoutSession
    /// Bumped per re-analysis; a fresh id gives AnalysisView a fresh run.
    @State private var reanalysisRun = 0

    var body: some View {
        Group {
            if reanalysisRun > 0, let recording {
                AnalysisView(recording: recording, activity: session.activity) { analysis in
                    save(analysis)
                }
                .id(reanalysisRun)
            } else if let analysis = session.analysis(), let videoURL = session.videoURL {
                ReportView(analysis: analysis, videoURL: videoURL)
            } else {
                ContentUnavailableView(
                    "Session unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This session's data could not be loaded.")
                )
            }
        }
        .navigationTitle(session.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    reanalysisRun += 1
                } label: {
                    Label("Re-analyze", systemImage: "arrow.clockwise")
                }
                .disabled(recording == nil)
            }
        }
    }

    /// The session's files as a recording, for re-extraction; nil when the
    /// video is gone.
    private var recording: RecordingResult? {
        guard let videoURL = session.videoURL,
              FileManager.default.fileExists(atPath: videoURL.path)
        else { return nil }
        let depthURL = session.depthFileName.flatMap { name in
            (try? FileLocations.recordingsDirectory())?.appendingPathComponent(name)
        }
        let hasDepth = depthURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return RecordingResult(
            videoURL: videoURL,
            depthSidecarURL: hasDepth ? depthURL : nil,
            duration: 0,
            usedLiDAR: hasDepth
        )
    }

    private func save(_ analysis: SquatAnalysis) {
        try? session.update(with: analysis)
        try? modelContext.save()
        SyncEngine.shared.pushSession(session)
        // The stored coach report narrates the replaced analysis; drop it so
        // the report screen offers a fresh generation instead.
        if let videoURL = session.videoURL {
            CoachReportStore.delete(for: videoURL)
        }
    }
}

/// Kodo lift chooser: one sculpted card per activity, Soul Red icon badge,
/// gauge-style caption.
private struct LiftChooserSheet: View {
    let onChoose: (ActivityType) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("WHAT ARE YOU LIFTING?")
                .font(.caption2.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
                .padding(.top, 22)
            ForEach(ActivityType.allCases) { activity in
                Button {
                    onChoose(activity)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: activity.systemImage)
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(
                                LinearGradient(
                                    colors: [Kodo.soulRedBright, Kodo.soulRed],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                in: Circle()
                            )
                        Text(activity.displayName)
                            .font(.headline)
                            .foregroundStyle(Kodo.inkPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.bold())
                            .foregroundStyle(Kodo.inkSecondary)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Kodo.cardTop, Kodo.cardBottom],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(Kodo.cardEdge, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }
}

private struct AttemptRow: View {
    let videoURL: URL

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "video.badge.ellipsis")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    LinearGradient(
                        colors: [.orange, .orange.opacity(0.65)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    in: Circle()
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Recording")
                    .font(.subheadline.bold())
                Text("Tap to review or analyze")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var creationDate: Date? {
        (try? videoURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}

private struct SessionRow: View {
    let session: WorkoutSession

    var body: some View {
        HStack(spacing: 14) {
            ScoreRing(score: session.score, diameter: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.bold())
                HStack(spacing: 6) {
                    Text(session.activity.displayName)
                    Text("· \(session.repCount) rep\(session.repCount == 1 ? "" : "s")")
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
}

/// A session synced from another device: the numbers are here, but the
/// recording isn't, so the row is informational (no report to open).
private struct RemoteSummaryRow: View {
    let summary: RemoteWorkoutSummary

    var body: some View {
        HStack(spacing: 14) {
            ScoreRing(score: summary.score, diameter: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.bold())
                HStack(spacing: 6) {
                    Text(summary.activity.displayName)
                    Text("· \(summary.repCount) rep\(summary.repCount == 1 ? "" : "s")")
                    Label("Synced", systemImage: "icloud")
                        .labelStyle(.titleAndIcon)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .foregroundStyle(.secondary)
    }
}

#Preview {
    HomeView()
        .modelContainer(for: WorkoutSession.self, inMemory: true)
        .environment(AuthSession())
}
