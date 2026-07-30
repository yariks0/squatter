import SwiftUI

/// "AI coach" section of the set report: runs the LLM assessment on demand
/// and renders the structured report. Degrades gracefully — the deterministic
/// findings above it never depend on this.
struct CoachSectionView: View {
    let analysis: SquatAnalysis
    let videoURL: URL

    private enum Phase {
        case idle, running
        case done(CoachReport)
        case failed(String)
    }

    @State private var phase: Phase = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI coach")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            content
        }
        .onAppear {
            if case .idle = phase, let stored = CoachReportStore.load(for: videoURL) {
                phase = .done(stored)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            Button {
                run()
            } label: {
                Label("Get AI coaching", systemImage: "sparkles")
            }
            .buttonStyle(KodoProminentButtonStyle(fullWidth: true, compact: true))
            Text("Sends this set's metrics and a few keyframes to Claude for a form review. Needs a network connection.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 10) {
                ProgressView()
                Text("Coach is reviewing the set…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Try again") { run() }
                    .buttonStyle(.bordered)
            }
        case let .done(report):
            reportView(report)
            Button {
                run()
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
    }

    private func reportView(_ report: CoachReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.summary)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Label(report.priorityFix.title, systemImage: "target")
                    .font(.subheadline.bold())
                Text("Cue: \(report.priorityFix.cue)")
                    .font(.subheadline)
                Text(report.priorityFix.why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let topic = report.priorityFix.hintTopic {
                    FormHintView(topic: topic)
                        .padding(.top, 4)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            ForEach(report.findings) { finding in
                FindingRow(finding: finding.asFinding)
            }

            if !report.positives.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keep doing")
                        .font(.subheadline.bold())
                    ForEach(report.positives, id: \.self) { positive in
                        Text("• \(positive)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            trackingCheck(report)
        }
    }

    /// Reps where the model saw the drawn skeleton off the lifter's body.
    /// Silent when everything matches (or the report predates verification) —
    /// the check only speaks when a rep's numbers shouldn't be trusted.
    @ViewBuilder
    private func trackingCheck(_ report: CoachReport) -> some View {
        let flagged = (report.trackingVerification ?? [])
            .filter { $0.verdict != "matches" }
        if !flagged.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Label("Tracking check", systemImage: "eye.trianglebadge.exclamationmark")
                    .font(.caption.bold())
                ForEach(flagged, id: \.repNumber) { verdict in
                    let joints = verdict.joints.isEmpty
                        ? "" : " — \(verdict.joints.joined(separator: ", "))"
                    Text("Rep \(verdict.repNumber): \(verdict.verdict == "mismatch" ? "skeleton mismatch" : "minor drift")\(joints). \(verdict.note)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Metrics from mismatched reps were down-weighted in this review.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func run() {
        phase = .running
        Task {
            do {
                let report = try await CoachClient.coach(analysis: analysis, videoURL: videoURL)
                CoachReportStore.save(report, for: videoURL)
                phase = .done(report)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
