import Charts
import SwiftUI

/// Home-screen dashboard: headline stats for the current week plus per-day
/// rep volume and form-score trends, aggregated from saved sessions.
///
/// Styling follows Mazda's Kodo language: sculpted dark cards in both color
/// schemes, one Soul Red accent reserved for the form-quality line, machined
/// gray for volume, and gauge-style uppercase labels. Restraint over
/// decoration — the flowing score curve is the only expressive element.
struct ProgressDashboard: View {
    let sessions: [WorkoutSession]

    private struct DayStat: Identifiable {
        let day: Date
        let reps: Int
        let averageScore: Double
        var id: Date { day }
    }

    private var calendar: Calendar { .current }

    private var days: [DayStat] {
        let grouped = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.date) }
        let stats = grouped.map { day, sessions in
            let reps = sessions.reduce(0) { $0 + $1.repCount }
            let scoreTotal = sessions.reduce(0) { $0 + $1.score }
            return DayStat(
                day: day, reps: reps,
                averageScore: Double(scoreTotal) / Double(sessions.count)
            )
        }
        return stats.sorted { $0.day < $1.day }
    }

    /// Charts share one x-domain so the bars and the trend line align. Always
    /// spans at least two weeks so a young history doesn't stretch one bar
    /// across the whole plot.
    private var xDomain: ClosedRange<Date> {
        let today = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let twoWeeksBack = calendar.date(byAdding: .day, value: -13, to: today) ?? today
        let start = min(days.first?.day ?? twoWeeksBack, twoWeeksBack)
        return start ... end
    }

    var body: some View {
        Group {
            statTiles
            repsChart
            scoreChart
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        // Zero horizontal insets: the cards span the same width as the other
        // sections' row backgrounds (the list margin alone does the insetting).
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
    }

    // MARK: Stat tiles

    private func sessions(daysBack range: Range<Int>) -> [WorkoutSession] {
        let today = calendar.startOfDay(for: .now)
        return sessions.filter { session in
            let age = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: session.date), to: today
            ).day ?? .max
            return range.contains(age)
        }
    }

    private var statTiles: some View {
        let thisWeek = sessions(daysBack: 0 ..< 7)
        let lastWeek = sessions(daysBack: 7 ..< 14)
        let weekReps = thisWeek.reduce(0) { $0 + $1.repCount }
        let weekScore = averageScore(of: thisWeek)
        let lastWeekScore = averageScore(of: lastWeek)

        return KodoCard {
            HStack(spacing: 0) {
                StatTile(
                    label: "Reps · week",
                    value: "\(weekReps)",
                    delta: lastWeek.isEmpty
                        ? nil : Double(weekReps - lastWeek.reduce(0) { $0 + $1.repCount })
                )
                tileDivider
                StatTile(
                    label: "Avg score",
                    value: weekScore.map { "\(Int($0.rounded()))" } ?? "—",
                    delta: zip(weekScore, lastWeekScore).map { ($0 - $1).rounded() }
                )
                tileDivider
                StatTile(
                    label: "Best score",
                    value: sessions.map(\.score).max().map { "\($0)" } ?? "—"
                )
            }
        }
    }

    private var tileDivider: some View {
        Rectangle()
            .fill(Kodo.hairline)
            .frame(width: 1, height: 36)
    }

    private func averageScore(of sessions: [WorkoutSession]) -> Double? {
        guard !sessions.isEmpty else { return nil }
        return Double(sessions.reduce(0) { $0 + $1.score }) / Double(sessions.count)
    }

    // MARK: Charts

    private var repsChart: some View {
        KodoCard {
            VStack(alignment: .leading, spacing: 10) {
                KodoCaption("Reps per day")
                Chart(days) { day in
                    BarMark(
                        x: .value("Day", day.day, unit: .day),
                        y: .value("Reps", day.reps),
                        width: .fixed(16)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Kodo.titanium, Kodo.titanium.opacity(0.55)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .cornerRadius(3)
                }
                .chartXScale(domain: xDomain)
                .chartYAxis { kodoAxis(values: .automatic(desiredCount: 3)) }
                .chartXAxis { kodoDayAxis }
                .frame(height: 120)
            }
        }
    }

    private var scoreChart: some View {
        KodoCard {
            VStack(alignment: .leading, spacing: 10) {
                KodoCaption("Form score")
                Chart {
                    ForEach(days) { day in
                        LineMark(
                            x: .value("Day", day.day, unit: .day),
                            y: .value("Score", day.averageScore)
                        )
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Kodo.soulRed.opacity(0.75), Kodo.soulRedBright],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        AreaMark(
                            x: .value("Day", day.day, unit: .day),
                            y: .value("Score", day.averageScore)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Kodo.soulRed.opacity(0.22), .clear],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    }
                    if let last = days.last {
                        PointMark(
                            x: .value("Day", last.day, unit: .day),
                            y: .value("Score", last.averageScore)
                        )
                        .symbolSize(70)
                        .foregroundStyle(Kodo.grade(for: Int(last.averageScore.rounded())))
                        .annotation(
                            position: .topLeading, spacing: 8,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                        ) {
                            Text("\(Int(last.averageScore.rounded()))")
                                .font(.system(.caption, design: .rounded).bold())
                                .foregroundStyle(Kodo.inkPrimary)
                        }
                    }
                }
                .chartXScale(domain: xDomain)
                .chartYScale(domain: 0 ... 100)
                .chartYAxis { kodoAxis(values: .automatic(desiredCount: 3)) }
                .chartXAxis { kodoDayAxis }
                .frame(height: 120)
            }
        }
    }

    private func kodoAxis(values: AxisMarkValues) -> some AxisContent {
        AxisMarks(values: values) {
            AxisGridLine().foregroundStyle(Kodo.hairline)
            AxisValueLabel()
                .font(.caption2)
                .foregroundStyle(Kodo.inkSecondary)
        }
    }

    private var kodoDayAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 5)) {
            AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                .font(.caption2)
                .foregroundStyle(Kodo.inkSecondary)
        }
    }
}

// MARK: - Kodo styling

/// Dark gradient card with a hairline top-light edge — the "sculpted metal"
/// surface every dashboard element sits on.
private struct KodoCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Kodo.cardTop, Kodo.cardBottom],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Kodo.cardEdge, lineWidth: 1)
                    )
            )
    }
}

/// Gauge-style card caption: uppercase, tracked out, secondary ink.
private struct KodoCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(1.4)
            .foregroundStyle(Kodo.inkSecondary)
    }
}

/// Label over a large value, with an optional signed delta against the
/// previous week (up is good for both reps and score).
private struct StatTile: View {
    let label: String
    let value: String
    var delta: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Kodo.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Kodo.inkPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let delta {
                Label("\(Int(abs(delta))) wk", systemImage: deltaSymbol)
                    .font(.caption2)
                    .foregroundStyle(
                        delta > 0 ? Color.green : delta < 0 ? Kodo.soulRedBright : Kodo.inkSecondary
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }

    private var deltaSymbol: String {
        if delta ?? 0 > 0 { "arrow.up" } else if delta ?? 0 < 0 { "arrow.down" } else { "minus" }
    }
}

/// `Optional.zip`: both values or nil.
private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    if let a, let b { (a, b) } else { nil }
}

#if DEBUG
#Preview {
    // Two weeks of mock history: rising volume, a mid-week form dip.
    let profile: [(daysAgo: Int, reps: Int, score: Int)] = [
        (13, 5, 62), (11, 6, 68), (9, 8, 74), (7, 6, 58),
        (5, 8, 71), (3, 10, 79), (1, 10, 84), (0, 12, 88),
    ]
    let sessions = profile.compactMap { day -> WorkoutSession? in
        let rep = RepMetrics(
            repNumber: 1, startTime: 0, endTime: 3, eccentricSeconds: 1.5,
            concentricSeconds: 1.5, depthFraction: 0.6, kneeFlexionDegrees: 80,
            hipBelowKneeDegrees: 5, torsoLeanDegrees: 35, kneeValgusRatio: 0.05,
            asymmetryDegrees: 3
        )
        let analysis = SquatAnalysis(
            reps: Array(repeating: rep, count: day.reps),
            findings: [], score: day.score, usedDepth: true, bodyHeight: 1.80,
            series: JointSeries(frames: [], bodyHeight: 1.80, usedDepth: true)
        )
        let recording = RecordingResult(
            videoURL: URL(fileURLWithPath: "/mock/\(day.daysAgo).mov"),
            depthSidecarURL: nil, duration: 40, usedLiDAR: true
        )
        return try? WorkoutSession(
            date: Calendar.current.date(byAdding: .day, value: -day.daysAgo, to: .now) ?? .now,
            recording: recording, analysis: analysis
        )
    }
    return List {
        Section("Progress") {
            ProgressDashboard(sessions: sessions.reversed())
        }
    }
}
#endif
