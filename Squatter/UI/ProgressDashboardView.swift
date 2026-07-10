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

    /// nil = both lifts combined.
    @State private var scope: ActivityType? = nil

    private var scopedSessions: [WorkoutSession] {
        guard let scope else { return sessions }
        return sessions.filter { $0.activity == scope }
    }

    private var visibleActivities: [ActivityType] {
        scope.map { [$0] } ?? ActivityType.allCases
    }

    /// One point per (day, lift): the reps chart stacks the two lifts,
    /// the score chart draws one line per lift.
    private struct DayStat: Identifiable {
        let day: Date
        let activity: ActivityType
        let reps: Int
        let averageScore: Double
        var id: String { "\(day.timeIntervalSinceReferenceDate)-\(activity.rawValue)" }
    }

    private struct DayKey: Hashable {
        let day: Date
        let activity: ActivityType
    }

    private var calendar: Calendar { .current }

    private var days: [DayStat] {
        let grouped = Dictionary(grouping: scopedSessions) { session in
            DayKey(day: calendar.startOfDay(for: session.date), activity: session.activity)
        }
        let stats = grouped.map { key, sessions in
            let reps = sessions.reduce(0) { $0 + $1.repCount }
            let scoreTotal = sessions.reduce(0) { $0 + $1.score }
            return DayStat(
                day: key.day, activity: key.activity, reps: reps,
                averageScore: Double(scoreTotal) / Double(sessions.count)
            )
        }
        return stats.sorted { $0.day < $1.day }
    }

    /// Series color per lift, shared by both charts and the legend:
    /// Soul Red carries the squat, titanium the bench. Built from the
    /// visible lifts so a scoped chart doesn't advertise the hidden series.
    private func liftColor(_ activity: ActivityType) -> Color {
        switch activity {
        case .squat: Kodo.soulRedBright
        case .benchPress: Kodo.titanium
        case .deadlift: Kodo.copper
        }
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
            KodoSegmentedPicker(
                options: [ActivityType?.none] + ActivityType.allCases.map { $0 },
                label: { $0?.displayName ?? "All" },
                selection: $scope
            )
            statTiles
            repsChart
            scoreChart
            if let scope {
                strengthCard(for: scope)
            }
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
        return scopedSessions.filter { session in
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
                    value: scopedSessions.map(\.score).max().map { "\($0)" } ?? "—"
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
                Chart(days) { stat in
                    BarMark(
                        x: .value("Day", stat.day, unit: .day),
                        y: .value("Reps", stat.reps),
                        width: .fixed(16)
                    )
                    .foregroundStyle(by: .value("Lift", stat.activity.displayName))
                    .cornerRadius(3)
                }
                .chartForegroundStyleScale(
                    domain: visibleActivities.map(\.displayName),
                    range: visibleActivities.map(liftColor)
                )
                .chartLegend(position: .top, alignment: .trailing)
                .chartLegend(scope == nil ? .automatic : .hidden)
                .chartXScale(domain: xDomain)
                .chartYAxis { kodoAxis(values: .automatic(desiredCount: 3)) }
                .chartXAxis { kodoDayAxis }
                .frame(height: 130)
            }
        }
    }

    private var scoreChart: some View {
        KodoCard {
            VStack(alignment: .leading, spacing: 10) {
                KodoCaption("Form score")
                Chart {
                    ForEach(days) { stat in
                        LineMark(
                            x: .value("Day", stat.day, unit: .day),
                            y: .value("Score", stat.averageScore),
                            series: .value("Lift", stat.activity.displayName)
                        )
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Lift", stat.activity.displayName))
                    }
                    // Latest point per lift, graded like the score rings;
                    // only the overall latest carries the value label.
                    ForEach(latestPerActivity) { stat in
                        PointMark(
                            x: .value("Day", stat.day, unit: .day),
                            y: .value("Score", stat.averageScore)
                        )
                        .symbolSize(70)
                        .foregroundStyle(Kodo.grade(for: Int(stat.averageScore.rounded())))
                        .annotation(
                            position: .topLeading, spacing: 8,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                        ) {
                            if stat.id == days.last?.id {
                                Text("\(Int(stat.averageScore.rounded()))")
                                    .font(.system(.caption, design: .rounded).bold())
                                    .foregroundStyle(Kodo.inkPrimary)
                            }
                        }
                    }
                }
                .chartForegroundStyleScale(
                    domain: visibleActivities.map(\.displayName),
                    range: visibleActivities.map(liftColor)
                )
                .chartLegend(position: .top, alignment: .trailing)
                .chartLegend(scope == nil ? .automatic : .hidden)
                .chartXScale(domain: xDomain)
                .chartYScale(domain: 0 ... 100)
                .chartYAxis { kodoAxis(values: .automatic(desiredCount: 3)) }
                .chartXAxis { kodoDayAxis }
                .frame(height: 130)
            }
        }
    }

    private var latestPerActivity: [DayStat] {
        ActivityType.allCases.compactMap { activity in
            days.last { $0.activity == activity }
        }
    }

    // MARK: Load–velocity / estimated 1RM (single-lift scope only —
    // a profile mixes loads and bar speeds of one movement)

    /// (load, best-rep MCV) per session that has both a logged weight and
    /// LiDAR velocities.
    private func loadVelocityPoints(for activity: ActivityType) -> [(load: Double, velocity: Double)] {
        sessions.compactMap { session in
            guard session.activity == activity,
                  let load = session.weightKg,
                  let best = session.analysis()?.reps
                      .compactMap(\.meanConcentricVelocity).max()
            else { return nil }
            return (load, best)
        }
    }

    private func strengthCard(for activity: ActivityType) -> some View {
        let points = loadVelocityPoints(for: activity)
        let profile = LoadVelocityProfile.fit(
            points: points.map { (loadKg: $0.load, velocity: $0.velocity) }
        )
        let minimalVelocity = switch activity {
        case .squat: AnalysisTuning.squatMinimalVelocity
        case .benchPress: AnalysisTuning.benchMinimalVelocity
        case .deadlift: AnalysisTuning.deadliftMinimalVelocity
        }
        return KodoCard {
            VStack(alignment: .leading, spacing: 10) {
                KodoCaption("Strength · load–velocity")
                if let profile {
                    let oneRepMax = profile.estimatedOneRepMax(atMinimalVelocity: minimalVelocity)
                    HStack(spacing: 0) {
                        StatTile(label: "Est. 1RM", value: "\(Int(oneRepMax.rounded())) kg")
                        tileDivider
                        StatTile(label: "Loads logged", value: "\(profile.pointCount)")
                    }
                    Chart {
                        ForEach(points, id: \.load) { point in
                            PointMark(
                                x: .value("Load", point.load),
                                y: .value("MCV", point.velocity)
                            )
                            .symbolSize(60)
                            .foregroundStyle(liftColor(activity))
                        }
                        ForEach([points.map(\.load).min() ?? 0, oneRepMax], id: \.self) { load in
                            LineMark(
                                x: .value("Load", load),
                                y: .value("MCV", profile.predictedVelocity(atLoad: load))
                            )
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .foregroundStyle(Kodo.inkSecondary)
                        }
                        RuleMark(y: .value("MCV", minimalVelocity))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(Kodo.hairline)
                            .annotation(position: .topTrailing) {
                                Text("1RM velocity")
                                    .font(.caption2)
                                    .foregroundStyle(Kodo.inkSecondary)
                            }
                    }
                    .chartXAxisLabel("kg", alignment: .trailing)
                    .chartYAxisLabel("m/s")
                    .chartYAxis { kodoAxis(values: .automatic(desiredCount: 3)) }
                    .chartXAxis { kodoAxis(values: .automatic(desiredCount: 4)) }
                    .frame(height: 150)
                } else {
                    Text(points.isEmpty
                        ? "Log the weight on the bar when analyzing a set — three different loads unlock your estimated 1RM, no max attempt needed."
                        : "Sets at three different loads (10 kg apart or more) unlock your estimated 1RM — \(points.count) logged so far.")
                        .font(.subheadline)
                        .foregroundStyle(Kodo.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
    // Two weeks of mock history: rising volume, a mid-week form dip,
    // bench sessions interleaved with squats.
    let profile: [(daysAgo: Int, reps: Int, score: Int, activity: ActivityType)] = [
        (13, 5, 62, .squat), (12, 8, 70, .benchPress), (11, 6, 68, .squat),
        (9, 8, 74, .squat), (8, 10, 77, .benchPress), (7, 6, 58, .squat),
        (5, 8, 71, .squat), (4, 12, 82, .benchPress), (3, 10, 79, .squat),
        (1, 10, 84, .squat), (0, 12, 88, .benchPress),
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
            series: JointSeries(frames: [], bodyHeight: 1.80, usedDepth: true),
            activity: day.activity
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
