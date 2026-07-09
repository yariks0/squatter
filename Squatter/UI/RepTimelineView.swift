import SwiftUI

/// Depth-over-time graph synced to playback. While the video plays the graph
/// glides under a fixed center playhead; grabbing the graph pauses the video
/// and scrubs it to the moment under the playhead. The header shows the stats
/// of the rep currently under the playhead.
@available(iOS 18.0, *)
struct RepTimelineView: View {
    let analysis: SquatAnalysis
    let playback: PlaybackModel

    @State private var position = ScrollPosition(edge: .leading)
    @State private var scrubbing = false

    /// Sample x: seconds, y: 0 standing … 1 deepest point of the set.
    private let samples: [CGPoint]
    private let duration: TimeInterval

    private static let pointsPerSecond: CGFloat = 70
    private let graphHeight: CGFloat = 116

    init(analysis: SquatAnalysis, playback: PlaybackModel) {
        self.analysis = analysis
        self.playback = playback
        // Display-only median filter: single-frame tracking dropouts spike
        // the lift signal well past any real movement, and the median kills
        // them without rounding off rep edges the way a wider moving
        // average would. Analysis keeps the unfiltered signal.
        let signal = medianFiltered(
            RepSegmenter.liftSignal(analysis.series, activity: analysis.kind),
            window: 5
        )
        let baseline = RepSegmenter.standingBaseline(of: signal)
        // Bench tracking compresses the wrist–shoulder distance far below any
        // real touch on bad frames, so scaling to the signal minimum squashes
        // the actual presses into a sliver at the top. Use the segmenter's
        // range normalization instead and let outliers clamp; the squat
        // signal is clean enough that its minimum is the true deepest point.
        let floor = switch analysis.kind {
        case .squat: signal.min() ?? baseline
        case .benchPress: RepSegmenter.touchFloor(of: signal)
        }
        let maxDepth = baseline - floor
        if baseline > 0, maxDepth > 0 {
            samples = zip(analysis.series.frames, signal).map { frame, value in
                CGPoint(x: frame.time, y: min(max((baseline - value) / maxDepth, 0), 1))
            }
        } else {
            samples = []
        }
        duration = analysis.series.frames.last?.time ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            GeometryReader { geo in
                timeline(viewportWidth: geo.size.width)
            }
            .frame(height: graphHeight)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if let rep = currentRep {
                Text("Rep \(rep.repNumber)")
                    .font(.system(.subheadline, design: .rounded).bold())
                Text(summary(of: rep))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Set timeline")
                    .font(.system(.subheadline, design: .rounded).bold())
                Text("drag to scrub")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(timeString(playback.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var currentRep: RepMetrics? {
        analysis.reps.first {
            playback.currentTime >= $0.startTime && playback.currentTime <= $0.endTime
        }
    }

    private func summary(of rep: RepMetrics) -> String {
        switch analysis.kind {
        case .squat:
            let depth = rep.hipBelowKneeDegrees >= AnalysisTuning.fullDepthDegrees ? "full depth"
                : rep.hipBelowKneeDegrees >= AnalysisTuning.parallelToleranceDegrees ? "parallel" : "high"
            return String(
                format: "%@ · lean %.0f° · %.1f s ↓ %.1f s ↑",
                depth, rep.torsoLeanDegrees, rep.eccentricSeconds, rep.concentricSeconds
            )
        case .benchPress:
            let elbow = rep.elbowFlexionDegrees ?? 180
            let touch = elbow <= AnalysisTuning.benchFullTouchElbowDegrees ? "to the chest"
                : elbow <= AnalysisTuning.benchShallowElbowDegrees ? "near chest" : "cut high"
            return String(
                format: "%@ · flare %.0f° · %.1f s ↓ %.1f s ↑",
                touch, rep.elbowFlareDegrees ?? 0, rep.eccentricSeconds, rep.concentricSeconds
            )
        }
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let tenths = Int((interval * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }

    // MARK: - Timeline

    /// Half the viewport pads each side of the graph, so the content offset
    /// maps 1:1 to the time under the fixed center playhead.
    private func timeline(viewportWidth: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            TimelineGraph(
                samples: samples,
                reps: analysis.reps,
                activity: analysis.kind,
                pointsPerSecond: Self.pointsPerSecond
            )
            .frame(width: max(duration, 1) * Self.pointsPerSecond, height: graphHeight)
            .padding(.horizontal, viewportWidth / 2)
        }
        .scrollPosition($position)
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .tracking, .interacting:
                scrubbing = true
                playback.player.pause()
            case .idle:
                scrubbing = false
            default:
                break // .decelerating keeps scrubbing through the momentum tail
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.x
        } action: { _, offset in
            guard scrubbing else { return }
            playback.seek(to: max(0, min(duration, offset / Self.pointsPerSecond)))
        }
        .onChange(of: playback.currentTime) { _, time in
            guard !scrubbing else { return }
            position.scrollTo(x: time * Self.pointsPerSecond)
        }
        .overlay {
            Capsule()
                .fill(.red)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Centered running median; ends use the samples available.
private func medianFiltered(_ values: [Double], window: Int) -> [Double] {
    guard window > 1, values.count > window else { return values }
    let half = window / 2
    return values.indices.map { index in
        let neighborhood = values[max(0, index - half) ... min(values.count - 1, index + half)]
        return neighborhood.sorted()[neighborhood.count / 2]
    }
}

/// The plotted curve: squat depth pointing down like the movement itself,
/// with a dashed standing line and a numbered marker at every rep's bottom.
@available(iOS 18.0, *)
private struct TimelineGraph: View {
    let samples: [CGPoint]
    let reps: [RepMetrics]
    let activity: ActivityType
    let pointsPerSecond: CGFloat

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let topInset: CGFloat = 24
            let bottomInset: CGFloat = 10
            let plotHeight = size.height - topInset - bottomInset

            func point(_ sample: CGPoint) -> CGPoint {
                CGPoint(x: sample.x * pointsPerSecond, y: topInset + sample.y * plotHeight)
            }

            var line = Path()
            line.move(to: point(samples[0]))
            for sample in samples.dropFirst() {
                line.addLine(to: point(sample))
            }
            var area = line
            area.addLine(to: CGPoint(x: point(samples[samples.count - 1]).x, y: topInset))
            area.addLine(to: CGPoint(x: point(samples[0]).x, y: topInset))
            area.closeSubpath()

            func drawCurve(in context: GraphicsContext) {
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [.teal.opacity(0.05), .teal.opacity(0.35)]),
                    startPoint: CGPoint(x: 0, y: topInset),
                    endPoint: CGPoint(x: 0, y: size.height)
                ))
                context.stroke(
                    line,
                    with: .color(.teal),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
            }
            // Outside the reps the signal is setup/rack time where tracking
            // is mostly noise — recede it so the reps carry the chart.
            if reps.isEmpty {
                drawCurve(in: context)
            } else {
                var dimmed = context
                dimmed.opacity = 0.25
                drawCurve(in: dimmed)

                var vivid = context
                var repWindows = Path()
                for rep in reps {
                    repWindows.addRect(CGRect(
                        x: rep.startTime * pointsPerSecond, y: 0,
                        width: (rep.endTime - rep.startTime) * pointsPerSecond,
                        height: size.height
                    ))
                }
                vivid.clip(to: repWindows)
                drawCurve(in: vivid)
            }

            var standing = Path()
            standing.move(to: CGPoint(x: 0, y: topInset))
            standing.addLine(to: CGPoint(x: size.width, y: topInset))
            context.stroke(
                standing,
                with: .color(.secondary.opacity(0.35)),
                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
            )

            for rep in reps {
                let bottomTime = rep.startTime + rep.eccentricSeconds
                let x = bottomTime * pointsPerSecond
                let center = CGPoint(x: x, y: 12)
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: 20))
                tick.addLine(to: CGPoint(x: x, y: size.height - bottomInset))
                context.stroke(
                    tick,
                    with: .color(color(for: rep).opacity(0.35)),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 3])
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: x - 9, y: center.y - 9, width: 18, height: 18)),
                    with: .color(color(for: rep))
                )
                context.draw(
                    Text("\(rep.repNumber)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white),
                    at: center
                )
            }
        }
    }

    private func color(for rep: RepMetrics) -> Color {
        switch activity {
        case .squat:
            if rep.hipBelowKneeDegrees >= AnalysisTuning.fullDepthDegrees {
                .green
            } else if rep.hipBelowKneeDegrees >= AnalysisTuning.parallelToleranceDegrees {
                .orange
            } else {
                .red
            }
        case .benchPress:
            // Touch depth carries the marker: elbow flexion at the bottom
            // (180 = straight arm, smaller = deeper touch).
            if let elbow = rep.elbowFlexionDegrees {
                if elbow <= AnalysisTuning.benchFullTouchElbowDegrees {
                    .green
                } else if elbow <= AnalysisTuning.benchShallowElbowDegrees {
                    .orange
                } else {
                    .red
                }
            } else {
                .gray
            }
        }
    }
}
