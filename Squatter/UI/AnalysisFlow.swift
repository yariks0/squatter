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

    init(recording: RecordingResult) {
        self.recording = recording
    }

    func run() async {
        guard case .processing = phase else { return }
        do {
            let series = try await PoseExtractor.extract(
                videoURL: recording.videoURL,
                depthSidecarURL: recording.depthSidecarURL,
                progress: { fraction in
                    Task { @MainActor [weak self] in
                        if case .processing = self?.phase { self?.phase = .processing(fraction) }
                    }
                }
            )
            phase = .done(SquatAnalyzer.analyze(series))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Runs the offline analysis over a fresh recording, then shows the report.
struct AnalysisView: View {
    @State private var model: AnalysisViewModel
    let onFinished: (SquatAnalysis) -> Void

    init(recording: RecordingResult, onFinished: @escaping (SquatAnalysis) -> Void) {
        _model = State(initialValue: AnalysisViewModel(recording: recording))
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
                    .onAppear { onFinished(analysis) }
            case .failed(let message):
                ContentUnavailableView(
                    "Analysis failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .task { await model.run() }
        .navigationTitle("Set report")
        .navigationBarTitleDisplayMode(.inline)
    }
}
