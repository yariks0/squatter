import Foundation

struct SquatAnalysis: Codable, Sendable {
    var reps: [RepMetrics]
    var findings: [Finding]
    var score: Int
    var usedDepth: Bool
    var bodyHeight: Float?
    /// Smoothed series, kept for overlay rendering and re-analysis.
    var series: JointSeries
    /// Optional so sessions analyzed before bench support still decode.
    var activity: ActivityType? = nil

    var kind: ActivityType { activity ?? .squat }
}

/// End-to-end analysis: smooth → segment reps → metrics → coaching findings.
enum SquatAnalyzer {
    static func analyze(_ raw: JointSeries, activity: ActivityType = .squat) -> SquatAnalysis {
        let series = JointSeriesSmoother.smoothed(raw, window: AnalysisTuning.smoothingWindow)
        let reps = RepSegmenter.segment(series, activity: activity)
        let metrics = MetricsCalculator.metrics(for: reps, in: series, activity: activity)
        let findings = FormRules.findings(for: metrics, activity: activity)
        return SquatAnalysis(
            reps: metrics,
            findings: findings,
            score: FormRules.score(for: findings),
            usedDepth: raw.usedDepth,
            bodyHeight: raw.bodyHeight,
            series: series,
            activity: activity
        )
    }
}
