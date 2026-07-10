import Foundation
import Testing
import simd
@testable import Squatter

/// The real-footage artifact: at depth Vision projects the pelvis too high —
/// the hip crease disappears between thigh and torso. Model space is
/// root-anchored, so a raised pelvis reads as every non-pelvis joint sliding
/// down while root and hips stay put.
private func withHipRiseBias(_ series: JointSeries, riseMeters: Float) -> JointSeries {
    let signal = RepSegmenter.liftSignal(series, activity: .squat)
    guard let top = signal.max(), let bottom = signal.min(), top - bottom > 1e-6
    else { return series }
    let pelvis: Set<BodyJoint> = [.root, .leftHip, .rightHip]
    var result = series
    for index in result.frames.indices {
        let depth = Float((top - signal[index]) / (top - bottom))
        let shift = SIMD3<Float>(0, riseMeters * depth, 0)
        for joint in result.frames[index].positions.keys where !pelvis.contains(joint) {
            result.frames[index].positions[joint]! -= shift
        }
    }
    return result
}

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

    @Test func hipRiseBiasReadsShallowWithoutCorrection() {
        let squat = SyntheticSquat(maxFemurAngle: 100)
        let truth = referenceMetrics(for: squat.series())
        let biased = referenceMetrics(for: withHipRiseBias(squat.series(), riseMeters: 0.07))
        // Documents the bug: a clearly below-parallel squat loses several
        // degrees of measured flexion once the pelvis drifts up.
        #expect(biased.kneeFlexionDegrees > truth.kneeFlexionDegrees + 5)
        #expect(biased.hipBelowKneeDegrees < truth.hipBelowKneeDegrees - 5)
    }

    @Test func correctionRestoresDepthMetrics() throws {
        let squat = SyntheticSquat(maxFemurAngle: 110)
        let truth = SquatAnalyzer.analyze(squat.series())
        let corrected = SquatAnalyzer.analyze(withHipRiseBias(squat.series(), riseMeters: 0.07))
        #expect(corrected.reps.count == truth.reps.count)
        for (fixed, real) in zip(corrected.reps, truth.reps) {
            #expect(abs(fixed.kneeFlexionDegrees - real.kneeFlexionDegrees) < 3)
            #expect(abs(fixed.hipBelowKneeDegrees - real.hipBelowKneeDegrees) < 3)
            #expect(abs(fixed.depthFraction - real.depthFraction) < 0.06)
        }
        // The whole point: the full-depth squat no longer reads shallow.
        #expect(corrected.findings.contains { $0.title == "Good depth" })
    }

    @Test func correctionIsANoOpOnCleanTracking() {
        let squat = SyntheticSquat()
        let raw = squat.series()
        let uncorrected = referenceMetrics(for: raw)
        let analyzed = SquatAnalyzer.analyze(raw)
        #expect(abs(analyzed.reps[0].kneeFlexionDegrees - uncorrected.kneeFlexionDegrees) < 1)
        #expect(abs(analyzed.reps[0].hipBelowKneeDegrees - uncorrected.hipBelowKneeDegrees) < 1)
    }

    @Test func correctionDoesNotFakeDepthOnShallowSquats() {
        let squat = SyntheticSquat(maxFemurAngle: 50)
        let corrected = SquatAnalyzer.analyze(withHipRiseBias(squat.series(), riseMeters: 0.05))
        #expect(corrected.findings.contains {
            $0.title == "Shallow depth"
        })
    }

    @Test func correctedSkeletonKeepsScannedLengths() throws {
        let squat = SyntheticSquat(maxFemurAngle: 100)
        let biased = withHipRiseBias(squat.series(), riseMeters: 0.07)
        let analysis = SquatAnalyzer.analyze(biased)
        let geometry = try #require(analysis.bodyGeometry)
        // At the deepest frame of the corrected series, the femur is back at
        // its scanned length instead of stretched by the raised pelvis.
        let signal = RepSegmenter.liftSignal(analysis.series, activity: .squat)
        let bottomFrame = analysis.series.frames[
            signal.firstIndex(of: signal.min() ?? 0) ?? 0
        ]
        let hip = try #require(bottomFrame.position(.leftHip))
        let knee = try #require(bottomFrame.position(.leftKnee))
        let femur = try #require(geometry.length(.leftHip, .leftKnee))
        #expect(abs(simd_length(hip - knee) - femur) < 0.01)
    }

    /// Metrics through smoothing and segmentation but *without* the
    /// geometry correction — the pre-correction pipeline, as a baseline.
    private func referenceMetrics(for raw: JointSeries) -> RepMetrics {
        let smoothed = JointSeriesSmoother.smoothed(raw, window: AnalysisTuning.smoothingWindow)
        let reps = RepSegmenter.segment(smoothed, activity: .squat)
        let metrics = MetricsCalculator.metrics(for: reps, in: smoothed, activity: .squat)
        return metrics[0]
    }
}
