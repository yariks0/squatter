import Foundation
import Testing
import simd
@testable import Squatter

@Suite struct BodyGeometryTests {
    @Test func scanMeasuresStandingBoneLengths() throws {
        let squat = SyntheticSquat()
        let geometry = SquatAnalyzer.scanGeometry(of: squat.series(), activity: .squat)
        let scanned = try #require(geometry)
        #expect(abs(try #require(scanned.length(.leftHip, .leftKnee)) - squat.femurLength) < 0.005)
        #expect(abs(try #require(scanned.length(.rightKnee, .rightAnkle)) - squat.shinLength) < 0.005)
        let torsoChain = try #require(scanned.length(.root, .spine))
            + (try #require(scanned.length(.spine, .centerShoulder)))
        #expect(abs(torsoChain - squat.torsoLength) < 0.005)
        #expect(abs(try #require(scanned.length(.leftHip, .rightHip)) - 2 * squat.hipHalfWidth) < 0.005)
    }

    @Test func metricScanMeasuresTrueLengths() throws {
        var squat = SyntheticSquat()
        squat.metersPerImageHeight = 2.2
        let metric = try #require(SquatAnalyzer.metricScan(of: squat.series(), activity: .squat))
        #expect(abs(metric.femurMeters - Double(squat.femurLength)) < 0.01)
        #expect(abs(metric.shinMeters - Double(squat.shinLength)) < 0.01)
        #expect(abs(try #require(metric.torsoMeters) - Double(squat.torsoLength)) < 0.01)
        #expect(metric.quality < 0.02)
    }

    /// The scan's deep hold records the lifter's own full-depth reference
    /// via the same drop formula the pelvis anchor uses.
    @Test func profileScanMeasuresDeepestHold() throws {
        var squat = SyntheticSquat(repCount: 1, maxFemurAngle: 110)
        squat.bottomPauseSeconds = 5
        squat.metersPerImageHeight = 2.2
        let metric = try #require(SquatAnalyzer.profileScan(of: squat.series()))
        let deepest = try #require(metric.deepestHipBelowKneeDegrees)
        #expect(abs(deepest - 20) < 3)
        // Session scans must not measure depth from loaded bottoms.
        let session = try #require(SquatAnalyzer.metricScan(of: squat.series(), activity: .squat))
        #expect(session.deepestHipBelowKneeDegrees == nil)
    }

    /// The scan's frontal + T-pose stage: widths from horizontal image spans
    /// × aspect × scale, arm segments while held straight out.
    @Test func metricScanMeasuresWidthsAndArmsFromFrontalView() throws {
        var squat = SyntheticSquat()
        squat.metersPerImageHeight = 2.2
        squat.armsOut = true
        let metric = try #require(SquatAnalyzer.metricScan(of: squat.series(), activity: .squat))
        #expect(abs(try #require(metric.shoulderWidthMeters) - 0.36) < 0.01)
        #expect(abs(try #require(metric.hipWidthMeters) - 2 * Double(squat.hipHalfWidth)) < 0.01)
        #expect(abs(try #require(metric.upperArmMeters) - Double(squat.upperArmLength)) < 0.01)
        #expect(abs(try #require(metric.forearmMeters) - Double(squat.forearmLength)) < 0.01)
    }

    /// Side-on frames measure legs (vertical drops are view-invariant) but
    /// never widths or arms — the spans have collapsed.
    @Test func metricScanSkipsWidthsFromSideView() throws {
        var squat = SyntheticSquat()
        squat.metersPerImageHeight = 2.2
        squat.armsOut = true
        squat.imageYawDegrees = 90
        let metric = try #require(SquatAnalyzer.metricScan(of: squat.series(), activity: .squat))
        #expect(abs(metric.femurMeters - Double(squat.femurLength)) < 0.01)
        #expect(metric.shoulderWidthMeters == nil)
        #expect(metric.upperArmMeters == nil)
    }

    /// Vision's real-footage failure mode (measured on pulled sessions): the
    /// 3D skeleton keeps perfect bone lengths but is *posed* too shallow at
    /// the bottom. The 2D image points see the true pose; the metric anchor
    /// recovers it.
    @Test func imageAnchorRecoversPoseBiasedDepth() throws {
        var squat = SyntheticSquat(maxFemurAngle: 110)
        squat.metersPerImageHeight = 2.2
        let truth = SquatAnalyzer.analyze(squat.series())

        squat.modelPoseShallowBias = 25
        var blind = squat
        blind.metersPerImageHeight = 0
        let uncorrected = SquatAnalyzer.analyze(blind.series())
        // Without image data the biased pose is self-consistent and reads
        // shallow — no model-space constraint can see the error.
        #expect(try #require(uncorrected.reps[0].hipBelowKneeDegrees)
            < #require(truth.reps[0].hipBelowKneeDegrees) - 15)

        let corrected = SquatAnalyzer.analyze(squat.series())
        #expect(corrected.metricGeometry != nil)
        #expect(corrected.reps.count == truth.reps.count)
        for (fixed, real) in zip(corrected.reps, truth.reps) {
            #expect(abs(try #require(fixed.hipBelowKneeDegrees)
                - #require(real.hipBelowKneeDegrees)) < 4)
            #expect(abs(fixed.kneeFlexionDegrees - real.kneeFlexionDegrees) < 5)
        }
        #expect(corrected.findings.contains { $0.title == "Good depth" })
    }

    /// A tilted camera or a 2D hip glitch makes the image read *shallower*
    /// than the model. The 3D pose never exaggerates depth, so the anchor
    /// must never shallow it — a real pulled session lost 30° on good reps
    /// before this gate existed.
    @Test func imageAnchorNeverShallowsThePose() throws {
        var squat = SyntheticSquat(maxFemurAngle: 95)
        // Model 15° deeper than what the image claims.
        squat.modelPoseShallowBias = -15
        let modelOnly = SquatAnalyzer.analyze(squat.series())
        squat.metersPerImageHeight = 2.2
        let withImage = SquatAnalyzer.analyze(squat.series())
        #expect(withImage.reps.count == modelOnly.reps.count)
        for (image, model) in zip(withImage.reps, modelOnly.reps) {
            #expect(abs(try #require(image.hipBelowKneeDegrees)
                - #require(model.hipBelowKneeDegrees)) < 1.5)
        }
    }

    /// The anchor can't conjure depth that isn't there: a genuinely shallow
    /// squat with agreeing image data still reads shallow.
    @Test func imageAnchorDoesNotFakeDepthOnShallowSquats() {
        var squat = SyntheticSquat(maxFemurAngle: 50)
        squat.metersPerImageHeight = 2.2
        let analysis = SquatAnalyzer.analyze(squat.series())
        #expect(analysis.findings.contains { $0.title == "Shallow depth" })
    }

    @Test func analysisIsUnchangedWithoutImageData() throws {
        let squat = SyntheticSquat()
        let raw = squat.series()
        let smoothed = JointSeriesSmoother.smoothed(raw, window: AnalysisTuning.smoothingWindow)
        let reps = RepSegmenter.segment(smoothed, activity: .squat)
        let baseline = MetricsCalculator.metrics(for: reps, in: smoothed, activity: .squat)
        let analyzed = SquatAnalyzer.analyze(raw)
        #expect(analyzed.reps.count == baseline.count)
        #expect(abs(analyzed.reps[0].kneeFlexionDegrees - baseline[0].kneeFlexionDegrees) < 0.01)
        #expect(abs(try #require(analyzed.reps[0].hipBelowKneeDegrees)
            - #require(baseline[0].hipBelowKneeDegrees)) < 0.01)
    }

    @Test func preScanProfileOverridesSessionScan() throws {
        var squat = SyntheticSquat(maxFemurAngle: 110)
        squat.metersPerImageHeight = 2.2
        squat.modelPoseShallowBias = 25
        let profile = BodyGeometryProfile(
            metric: MetricBodyGeometry(
                femurMeters: Double(squat.femurLength),
                shinMeters: Double(squat.shinLength),
                quality: 0.01
            ),
            scannedAt: .now
        )
        let analysis = SquatAnalyzer.analyze(squat.series(), profile: profile)
        #expect(analysis.metricGeometry == profile.metric)
        #expect(analysis.findings.contains { $0.title == "Good depth" })
    }

    /// A mobility-limited lifter whose scan shows +2° available: reaching
    /// near that unloaded max counts as their full depth instead of being
    /// nagged toward an impossible +12°.
    @Test func depthIsJudgedAgainstTheLiftersOwnScan() {
        var squat = SyntheticSquat(maxFemurAngle: 95)  // bottoms ≈ +5°
        squat.metersPerImageHeight = 2.2
        let profile = BodyGeometryProfile(
            metric: MetricBodyGeometry(
                femurMeters: Double(squat.femurLength),
                shinMeters: Double(squat.shinLength),
                quality: 0.01,
                deepestHipBelowKneeDegrees: 2
            ),
            scannedAt: .now
        )
        let personalized = SquatAnalyzer.analyze(squat.series(), profile: profile)
        #expect(personalized.findings.contains { $0.title == "Good depth" })
        let absolute = SquatAnalyzer.analyze(squat.series())
        #expect(absolute.findings.contains { $0.title == "Close to full depth" })
    }

    /// The scan proves +25° exists; loaded bottoms at ~+5° leave depth on
    /// the table — and reaching the absolute standard is still demanded.
    @Test func depthInReserveIsCalledOut() {
        var squat = SyntheticSquat(maxFemurAngle: 95)
        squat.metersPerImageHeight = 2.2
        let profile = BodyGeometryProfile(
            metric: MetricBodyGeometry(
                femurMeters: Double(squat.femurLength),
                shinMeters: Double(squat.shinLength),
                quality: 0.01,
                deepestHipBelowKneeDegrees: 25
            ),
            scannedAt: .now
        )
        let analysis = SquatAnalyzer.analyze(squat.series(), profile: profile)
        #expect(analysis.findings.contains { $0.title == "Depth in reserve" })
        #expect(analysis.findings.contains { $0.title == "Close to full depth" })
    }

    /// A noisy metric scan must not anchor anything.
    @Test func noisyMetricScanIsRejected() {
        var squat = SyntheticSquat(maxFemurAngle: 110)
        squat.metersPerImageHeight = 2.2
        squat.modelPoseShallowBias = 35
        let profile = BodyGeometryProfile(
            metric: MetricBodyGeometry(
                femurMeters: Double(squat.femurLength),
                shinMeters: Double(squat.shinLength),
                quality: AnalysisTuning.geometryScanQualityGate * 2
            ),
            scannedAt: .now
        )
        let analysis = SquatAnalyzer.analyze(squat.series(), profile: profile)
        // Biased pose stays shallow because the anchor never engaged.
        #expect(analysis.findings.contains { $0.title == "Shallow depth" })
    }
}
