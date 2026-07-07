import SwiftUI

struct ReportView: View {
    let analysis: SquatAnalysis
    let videoURL: URL
    @State private var playback: PlaybackModel

    init(analysis: SquatAnalysis, videoURL: URL) {
        self.analysis = analysis
        self.videoURL = videoURL
        _playback = State(initialValue: PlaybackModel(videoURL: videoURL))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                PlayerOverlayView(playback: playback, series: analysis.series)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                if !analysis.reps.isEmpty {
                    if #available(iOS 18.0, *) {
                        RepTimelineView(analysis: analysis, playback: playback)
                    } else {
                        repStrip
                    }
                }
                findingsSection
                if !analysis.reps.isEmpty {
                    CoachSectionView(analysis: analysis, videoURL: videoURL)
                }
            }
            .padding()
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ScoreRing(score: analysis.score, diameter: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(analysis.reps.count) rep\(analysis.reps.count == 1 ? "" : "s")")
                    .font(.system(.title2, design: .rounded).bold())
                HStack(spacing: 6) {
                    if analysis.usedDepth {
                        Label("LiDAR depth", systemImage: "sensor.fill")
                    } else {
                        Label("Camera only", systemImage: "camera.fill")
                    }
                    if let height = analysis.bodyHeight {
                        Text("· est. height \(height, format: .number.precision(.fractionLength(2))) m")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var repStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(analysis.reps) { rep in
                    Button {
                        playback.seek(to: rep.startTime)
                        playback.player.play()
                    } label: {
                        RepCard(rep: rep)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var findingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Coaching notes")
                .font(.headline)
            ForEach(analysis.findings) { finding in
                FindingRow(finding: finding)
            }
        }
    }
}

private struct RepCard: View {
    let rep: RepMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rep \(rep.repNumber)")
                .font(.system(.subheadline, design: .rounded).bold())
            metricLine(
                "Depth",
                rep.hipBelowKneeDegrees >= AnalysisTuning.fullDepthDegrees ? "full" :
                    rep.hipBelowKneeDegrees >= AnalysisTuning.parallelToleranceDegrees ? "parallel" : "high",
                good: rep.hipBelowKneeDegrees >= AnalysisTuning.parallelToleranceDegrees
            )
            metricLine(
                "Lean",
                "\(Int(rep.torsoLeanDegrees))°",
                good: rep.torsoLeanDegrees < AnalysisTuning.torsoLeanWarningDegrees
            )
            metricLine(
                "Knees",
                rep.kneeValgusRatio < AnalysisTuning.valgusWarningRatio ? "tracking" : "caving",
                good: rep.kneeValgusRatio < AnalysisTuning.valgusWarningRatio
            )
            Text(String(format: "%.1fs ↓ %.1fs ↑", rep.eccentricSeconds, rep.concentricSeconds))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 132, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func metricLine(_ label: String, _ value: String, good: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(good ? .green : .orange)
                .frame(width: 6, height: 6)
            Text("\(label): \(value)")
                .font(.caption)
        }
    }
}

struct FindingRow: View {
    let finding: Finding

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title)
                    .font(.subheadline.bold())
                Text(finding.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(color.opacity(0.15), lineWidth: 1)
        )
    }

    private var icon: String {
        switch finding.severity {
        case .info: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .risk: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch finding.severity {
        case .info: .green
        case .warning: .orange
        case .risk: .red
        }
    }
}
