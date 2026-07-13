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
    /// Metric geometry the pose was anchored to — the pre-scan profile when
    /// one exists, else measured from this session's standing frames. nil =
    /// no anchoring (no LiDAR, or the scan was too noisy). Optional so older
    /// sessions decode.
    var metricGeometry: MetricBodyGeometry? = nil

    var kind: ActivityType { activity ?? .squat }
}

/// End-to-end analysis: smooth → scan body geometry + correct the skeleton
/// → segment reps → metrics → coaching findings.
enum SquatAnalyzer {
    static func analyze(
        _ raw: JointSeries, activity: ActivityType = .squat,
        profile: BodyGeometryProfile? = nil
    ) -> SquatAnalysis {
        // Joint angles are only as good as the skeleton: when bone lengths
        // jitter, every form rule fires on noise, so a single honest finding
        // replaces them all. Judged on the un-repaired series — despiking
        // (like geometry correction) would hide exactly the flicker this
        // gate catches, so repair runs on a separate fork below.
        let gateSeries = JointSeriesSmoother.smoothed(raw, window: AnalysisTuning.smoothingWindow)
        let jitter = TrackingQuality.boneLengthJitter(of: gateSeries)
        let trackable = gateSeries.frames.isEmpty || jitter <= AnalysisTuning.trackingJitterGateRatio
        // Repair on the raw series (SG would smear a spike across its whole
        // window), then smooth what remains.
        let smoothed = JointSeriesSmoother.smoothed(
            JointTrackRepair.repaired(raw), window: AnalysisTuning.smoothingWindow
        )
        // Squat-only for now: the pelvis mis-projection shows on deep squats,
        // while on a deadlift the corrector's spine handling measurably
        // perturbs the spine-flexion (injury) signal — don't enable there
        // without real footage proving it out.
        let geometry = trackable && activity == .squat
            ? scanGeometry(of: smoothed, activity: activity) : nil
        // The pre-scan profile wins over the session's own standing frames:
        // it was measured in a controlled setup, not in a gym corner.
        let metric = geometry == nil ? nil
            : profile?.metric ?? metricScan(of: smoothed, activity: activity)
        let series = geometry.map {
            SkeletonCorrector.corrected(smoothed, geometry: $0, metric: metric)
        } ?? smoothed
        let reps = RepSegmenter.segment(series, activity: activity)
        var metrics = MetricsCalculator.metrics(for: reps, in: series, activity: activity)
        // Per-rep jitter from the same un-repaired series as the global gate;
        // frame indices align across the fork, so rep windows transfer.
        let timeline = TrackingQuality.frameJitterTimeline(of: gateSeries)
        for index in metrics.indices {
            metrics[index].trackingJitter = TrackingQuality.repJitter(
                timeline, from: reps[index].startIndex, to: reps[index].endIndex
            )
        }
        let findings = trackable
            ? gatedFindings(for: metrics, activity: activity, profile: profile)
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
            bodyGeometry: geometry,
            metricGeometry: metric
        )
    }

    /// Form rules over only the reps whose own window tracked cleanly. When
    /// the global gate passes but single reps flickered (someone walked
    /// through the frame, a brief occlusion), those reps' angles are noise:
    /// judging them would fire false findings, discarding the whole set
    /// would waste the clean reps. Suppressed reps keep their metrics — only
    /// rule judgment is withheld, and one info finding names them.
    private static func gatedFindings(
        for metrics: [RepMetrics], activity: ActivityType, profile: BodyGeometryProfile?
    ) -> [Finding] {
        let trusted = metrics.filter {
            ($0.trackingJitter ?? 0) <= AnalysisTuning.repTrackingJitterGateRatio
        }
        // Every rep untrackable = the whole-set story, told the global way.
        if trusted.isEmpty, !metrics.isEmpty {
            return [FormRules.trackingQualityFinding(activity: activity)]
        }
        var findings = FormRules.findings(
            for: trusted, activity: activity,
            // Only the dedicated scan measures this, so a session-scan
            // fallback never judges depth against itself.
            depthReference: profile?.metric.deepestHipBelowKneeDegrees
        )
        let suppressed = metrics.filter {
            ($0.trackingJitter ?? 0) > AnalysisTuning.repTrackingJitterGateRatio
        }
        if !suppressed.isEmpty {
            findings.append(FormRules.partialTrackingFinding(
                repNumbers: suppressed.map(\.repNumber), activity: activity
            ))
        }
        return findings
    }

    /// Metric bone lengths from a series' standing frames — the in-the-wild
    /// fallback when no pre-scan profile exists, and what the scan flow runs
    /// over a dedicated standing recording.
    static func metricScan(of series: JointSeries, activity: ActivityType) -> MetricBodyGeometry? {
        MetricBodyGeometry.measure(
            from: standingFrames(of: series, activity: activity),
            aspectRatio: series.imageAspectRatio
        )
    }

    /// The dedicated body-scan flow's measurement: standing frames plus the
    /// deep-hold frames, which give the lifter's own full-depth reference.
    /// Sessions use `metricScan` — no depth calibration from loaded bottoms,
    /// which are the very thing being judged.
    static func profileScan(of series: JointSeries) -> MetricBodyGeometry? {
        let signal = RepSegmenter.liftSignal(series, activity: .squat)
        let baseline = RepSegmenter.standingBaseline(of: signal)
        guard baseline > 0 else { return nil }
        let deep = zip(series.frames, signal)
            .filter { $0.1 <= baseline * AnalysisTuning.geometryScanDeepFraction }
            .map(\.0)
        return MetricBodyGeometry.measure(
            from: standingFrames(of: series, activity: .squat),
            aspectRatio: series.imageAspectRatio,
            deepFrames: deep
        )
    }

    /// The body scan: every set starts (or locks out) standing, where Vision
    /// tracks accurately — frames whose lift signal sits at the standing
    /// baseline are the scan, and their median bone lengths are the lifter's
    /// geometry. Self-gating: a session without enough clean standing frames
    /// (e.g. bench with the legs cropped) measures nothing and runs
    /// uncorrected.
    static func scanGeometry(of series: JointSeries, activity: ActivityType) -> BodyGeometry? {
        BodyGeometry.measure(from: standingFrames(of: series, activity: activity))
    }

    private static func standingFrames(
        of series: JointSeries, activity: ActivityType
    ) -> [JointFrame] {
        let signal = RepSegmenter.liftSignal(series, activity: activity)
        let baseline = RepSegmenter.standingBaseline(of: signal)
        guard baseline > 0 else { return [] }
        return zip(series.frames, signal)
            .filter { $0.1 >= baseline * AnalysisTuning.geometryScanFraction }
            .map(\.0)
    }
}
