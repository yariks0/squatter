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
    /// Median relative bone-length jitter (see `TrackingQuality`); optional
    /// so sessions analyzed before the tracking gate still decode.
    var trackingJitter: Double? = nil
    /// Bone lengths scanned from the session's standing frames and enforced
    /// by `SkeletonCorrector`; nil when the scan failed (and the series is
    /// then uncorrected). Optional so older sessions decode.
    var bodyGeometry: BodyGeometry? = nil

    var kind: ActivityType { activity ?? .squat }
}

/// End-to-end analysis: smooth → scan body geometry + correct the skeleton
/// → segment reps → metrics → coaching findings.
enum SquatAnalyzer {
    static func analyze(_ raw: JointSeries, activity: ActivityType = .squat) -> SquatAnalysis {
        let smoothed = JointSeriesSmoother.smoothed(raw, window: AnalysisTuning.smoothingWindow)
        // Joint angles are only as good as the skeleton: when bone lengths
        // jitter, every form rule fires on noise, so a single honest finding
        // replaces them all. Judged before geometry correction — enforcing
        // bone lengths would hide exactly the flicker this gate catches.
        let jitter = TrackingQuality.boneLengthJitter(of: smoothed)
        let trackable = smoothed.frames.isEmpty || jitter <= AnalysisTuning.trackingJitterGateRatio
        // Squat-only for now: the pelvis mis-projection shows on deep squats,
        // while on a deadlift the corrector's spine handling measurably
        // perturbs the spine-flexion (injury) signal — don't enable there
        // without real footage proving it out.
        let geometry = trackable && activity == .squat
            ? scanGeometry(of: smoothed, activity: activity) : nil
        let series = geometry.map { SkeletonCorrector.corrected(smoothed, geometry: $0) }
            ?? smoothed
        let reps = RepSegmenter.segment(series, activity: activity)
        let metrics = MetricsCalculator.metrics(for: reps, in: series, activity: activity)
        let findings = trackable
            ? FormRules.findings(for: metrics, activity: activity)
            : [FormRules.trackingQualityFinding(activity: activity)]
        return SquatAnalysis(
            reps: metrics,
            findings: findings,
            score: FormRules.score(for: findings),
            usedDepth: raw.usedDepth,
            bodyHeight: raw.bodyHeight,
            series: series,
            activity: activity,
            trackingJitter: jitter.isFinite ? jitter : nil,
            bodyGeometry: geometry
        )
    }

    /// The body scan: every set starts (or locks out) standing, where Vision
    /// tracks accurately — frames whose lift signal sits at the standing
    /// baseline are the scan, and their median bone lengths are the lifter's
    /// geometry. Self-gating: a session without enough clean standing frames
    /// (e.g. bench with the legs cropped) measures nothing and runs
    /// uncorrected.
    static func scanGeometry(of series: JointSeries, activity: ActivityType) -> BodyGeometry? {
        let signal = RepSegmenter.liftSignal(series, activity: activity)
        let baseline = RepSegmenter.standingBaseline(of: signal)
        guard baseline > 0 else { return nil }
        let standing = zip(series.frames, signal)
            .filter { $0.1 >= baseline * AnalysisTuning.geometryScanFraction }
            .map(\.0)
        return BodyGeometry.measure(from: standing)
    }
}
