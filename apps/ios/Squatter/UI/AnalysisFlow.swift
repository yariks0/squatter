import SwiftUI

@MainActor
@Observable
final class AnalysisViewModel {
    enum Phase {
        case processing(Double)
        case done(SquatAnalysis)
        case failed(String)
    }

    private(set) var phase: Phase = .processing(0)
    let recording: RecordingResult
    let activity: ActivityType

    init(recording: RecordingResult, activity: ActivityType = .squat) {
        self.recording = recording
        self.activity = activity
    }

    /// Runs once; calls `onFinished` exactly once on success. The run is
    /// wrapped in a `BackgroundWorkActivity`, so leaving the app or
    /// locking the screen doesn't stall extraction.
    func run(onFinished: (SquatAnalysis) -> Void) async {
        guard case .processing(let started) = phase, started == 0 else { return }
        let backgroundActivity = BackgroundWorkActivity(
            title: String(localized: "Analyzing your set"),
            subtitle: String(localized: "Measuring every rep")
        )
        backgroundActivity.begin()
        do {
            let series = try await PoseExtractor.extract(
                videoURL: recording.videoURL,
                depthSidecarURL: recording.depthSidecarURL,
                timeRange: recording.analysisRange,
                progress: { fraction in
                    Task { @MainActor [weak self] in
                        if case .processing = self?.phase { self?.phase = .processing(max(fraction, 0.01)) }
                        backgroundActivity.report(fraction)
                    }
                },
                readerStallRecovery: { await BackgroundWorkActivity.waitForRetry() }
            )
            let analysis = SquatAnalyzer.analyze(
                series, activity: activity, profile: BodyGeometryProfileStore.load()
            )
            phase = .done(analysis)
            onFinished(analysis)
            backgroundActivity.end(success: true)
        } catch {
            phase = .failed(error.localizedDescription)
            backgroundActivity.end(success: false)
        }
    }
}

/// Runs the offline analysis over a fresh recording, then shows the report.
struct AnalysisView: View {
    @State private var model: AnalysisViewModel
    let onFinished: (SquatAnalysis) -> Void

    init(
        recording: RecordingResult,
        activity: ActivityType = .squat,
        onFinished: @escaping (SquatAnalysis) -> Void
    ) {
        _model = State(initialValue: AnalysisViewModel(recording: recording, activity: activity))
        self.onFinished = onFinished
    }

    var body: some View {
        Group {
            switch model.phase {
            case .processing(let fraction):
                VStack(spacing: 20) {
                    ProgressView(value: fraction) {
                        Text("Analyzing your set…")
                            .font(.headline)
                    }
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 40)
                    Text("Extracting 3D body pose\(model.recording.usedLiDAR ? " with LiDAR depth" : "") and measuring every rep.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            case .done(let analysis):
                ReportView(analysis: analysis, videoURL: model.recording.videoURL)
            case .failed(let message):
                ContentUnavailableView(
                    "Analysis failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .task { await model.run(onFinished: onFinished) }
        .navigationTitle("Set report")
        .navigationBarTitleDisplayMode(.inline)
    }
}
