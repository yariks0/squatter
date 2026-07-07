import Foundation
import simd
import Testing
@testable import Squatter

struct RepSegmentationTests {
    @Test func countsCleanReps() {
        let series = SyntheticSquat(repCount: 5).series()
        let reps = RepSegmenter.segment(series)
        #expect(reps.count == 5)
    }

    @Test func countsNoisyReps() {
        let series = SyntheticSquat(repCount: 8, noise: 0.008).series()
        let smoothed = JointSeriesSmoother.smoothed(series, window: AnalysisTuning.smoothingWindow)
        let reps = RepSegmenter.segment(smoothed)
        #expect(reps.count == 8)
    }

    @Test func ignoresStandingStill() {
        var generator = SyntheticSquat(repCount: 0)
        generator.pauseSeconds = 10
        let reps = RepSegmenter.segment(generator.series())
        #expect(reps.isEmpty)
    }

    @Test func ignoresShallowKneeBends() {
        // A ~15° knee bend is someone shifting weight, not a squat rep.
        let series = SyntheticSquat(repCount: 3, maxFemurAngle: 15).series()
        let reps = RepSegmenter.segment(series)
        #expect(reps.isEmpty)
    }

    @Test func bottomLandsMidRep() throws {
        let generator = SyntheticSquat(repCount: 1)
        let reps = RepSegmenter.segment(generator.series())
        let rep = try #require(reps.first)
        // Bottom should land between start and end, nearer the eccentric/concentric boundary.
        #expect(rep.bottomTime > rep.startTime && rep.bottomTime < rep.endTime)
        let expectedBottom = generator.pauseSeconds + generator.eccentricSeconds
        #expect(abs(rep.bottomTime - expectedBottom) < 0.35)
    }
}

struct MetricsTests {
    private func metrics(_ generator: SyntheticSquat) -> [RepMetrics] {
        let series = generator.series()
        let reps = RepSegmenter.segment(series)
        return MetricsCalculator.metrics(for: reps, in: series)
    }

    @Test func deepSquatIsAtOrBelowParallel() throws {
        let all = metrics(SyntheticSquat(repCount: 3, maxFemurAngle: 100))
        #expect(all.count == 3)
        for rep in all {
            #expect(rep.hipBelowKneeDegrees > AnalysisTuning.parallelToleranceDegrees)
        }
    }

    @Test func shallowSquatIsAboveParallel() throws {
        let all = metrics(SyntheticSquat(repCount: 3, maxFemurAngle: 55))
        #expect(all.count == 3)
        for rep in all {
            // 55° femur angle leaves the hip well above the knee.
            #expect(rep.hipBelowKneeDegrees < AnalysisTuning.parallelToleranceDegrees)
        }
    }

    @Test func valgusDetectedWhenInjected() throws {
        let caving = metrics(SyntheticSquat(repCount: 3, valgusShift: 0.07))
        let clean = metrics(SyntheticSquat(repCount: 3, valgusShift: 0))
        #expect(!caving.isEmpty && !clean.isEmpty)
        for rep in caving {
            #expect(rep.kneeValgusRatio >= AnalysisTuning.valgusWarningRatio)
        }
        for rep in clean {
            #expect(rep.kneeValgusRatio < AnalysisTuning.valgusWarningRatio)
        }
    }

    @Test func torsoLeanMeasured() throws {
        let upright = metrics(SyntheticSquat(repCount: 2, maxTorsoLean: 25))
        let folded = metrics(SyntheticSquat(repCount: 2, maxTorsoLean: 62))
        #expect(!upright.isEmpty && !folded.isEmpty)
        for rep in upright {
            #expect(rep.torsoLeanDegrees < AnalysisTuning.torsoLeanWarningDegrees)
        }
        for rep in folded {
            #expect(rep.torsoLeanDegrees >= AnalysisTuning.torsoLeanWarningDegrees)
        }
    }

    @Test func tempoMatchesGenerator() throws {
        var generator = SyntheticSquat(repCount: 2)
        generator.eccentricSeconds = 1.5
        generator.concentricSeconds = 1.0
        let all = metrics(generator)
        // With an eased velocity profile the first few hundred ms of a descent
        // barely move the hips, so "rep start" is inherently fuzzy. Tempo only
        // needs to separate controlled (~1.5 s) from dive-bombed (<0.6 s) reps.
        for rep in all {
            #expect(abs(rep.eccentricSeconds - 1.5) < 0.6)
            #expect(abs(rep.concentricSeconds - 1.0) < 0.5)
        }
    }

    @Test func symmetricSquatHasLowAsymmetry() throws {
        for rep in metrics(SyntheticSquat(repCount: 2)) {
            #expect(rep.asymmetryDegrees < 5)
        }
    }

    @Test func stanceWidthMeasured() throws {
        var generator = SyntheticSquat(repCount: 2)
        for (scale, expectNarrow, expectWide) in [(1.0, false, false), (0.5, true, false), (2.5, false, true)] {
            generator.stanceScale = scale
            for rep in metrics(generator) {
                let ratio = try #require(rep.stanceWidthRatio)
                #expect((ratio < AnalysisTuning.stanceNarrowRatio) == expectNarrow)
                #expect((ratio > AnalysisTuning.stanceWideRatio) == expectWide)
            }
        }
    }

    @Test func bottomWobbleDetected() throws {
        var generator = SyntheticSquat(repCount: 3)
        generator.bottomPauseSeconds = 0.8
        for rep in metrics(generator) {
            let shift = try #require(rep.bottomHipShiftRatio)
            #expect(shift < AnalysisTuning.bottomShiftWarningRatio)
        }
        generator.bottomWobbleMeters = 0.06
        for rep in metrics(generator) {
            let shift = try #require(rep.bottomHipShiftRatio)
            #expect(shift >= AnalysisTuning.bottomShiftWarningRatio)
        }
    }

    @Test func lockoutMeasured() throws {
        for rep in metrics(SyntheticSquat(repCount: 3)) {
            let lockout = try #require(rep.lockoutKneeDegrees)
            #expect(lockout >= AnalysisTuning.lockoutKneeDegrees)
        }
        var generator = SyntheticSquat(repCount: 3)
        generator.restProgress = 0.35
        for rep in metrics(generator) {
            let lockout = try #require(rep.lockoutKneeDegrees)
            #expect(lockout < AnalysisTuning.lockoutKneeDegrees)
        }
    }
}

struct FormRulesTests {
    private func analyze(_ generator: SyntheticSquat) -> SquatAnalysis {
        SquatAnalyzer.analyze(generator.series())
    }

    @Test func goodSetScoresHigh() {
        // Full-depth, upright squat — the Chinese weightlifting standard.
        let analysis = analyze(SyntheticSquat(repCount: 5, maxFemurAngle: 105))
        #expect(analysis.reps.count == 5)
        #expect(analysis.score >= 90)
        #expect(!analysis.findings.contains { $0.severity == .risk })
        #expect(analysis.findings.contains { $0.title == "Good depth" })
    }

    @Test func parallelSquatSuggestsFullDepth() {
        let analysis = analyze(SyntheticSquat(repCount: 3, maxFemurAngle: 92))
        #expect(analysis.findings.contains { $0.title == "Close to full depth" })
    }

    @Test func valgusSetFlaggedAsRiskOrWarning() {
        let analysis = analyze(SyntheticSquat(repCount: 4, valgusShift: 0.09))
        #expect(analysis.findings.contains { $0.severity >= .warning && $0.title.contains("Knees") })
        #expect(analysis.score < 90)
    }

    @Test func shallowSetGetsDepthFinding() {
        let analysis = analyze(SyntheticSquat(repCount: 4, maxFemurAngle: 55))
        #expect(analysis.findings.contains { $0.title == "Shallow depth" && $0.severity == .warning })
    }

    @Test func foldedTorsoFlagged() {
        let analysis = analyze(SyntheticSquat(repCount: 3, maxTorsoLean: 60))
        #expect(analysis.findings.contains { $0.title.contains("lean") || $0.title.contains("folding") })
    }

    @Test func fastDropFlagged() {
        var generator = SyntheticSquat(repCount: 3)
        generator.eccentricSeconds = 0.35
        let analysis = analyze(generator)
        #expect(analysis.findings.contains { $0.title == "Dropping too fast" })
    }

    @Test func narrowStanceFlagged() {
        var generator = SyntheticSquat(repCount: 3)
        generator.stanceScale = 0.5
        let analysis = analyze(generator)
        #expect(analysis.findings.contains { $0.title == "Stance too narrow" })
    }

    @Test func bottomWobbleFlagged() {
        var generator = SyntheticSquat(repCount: 3)
        generator.bottomPauseSeconds = 0.8
        generator.bottomWobbleMeters = 0.06
        let analysis = analyze(generator)
        #expect(analysis.findings.contains { $0.title == "Hips shifting at the bottom" })
    }

    @Test func partialLockoutFlagged() {
        var generator = SyntheticSquat(repCount: 3)
        generator.restProgress = 0.35
        let analysis = analyze(generator)
        #expect(analysis.findings.contains { $0.title == "Not standing up fully" })
    }

    @Test func emptySeriesReportsNoReps() {
        let analysis = SquatAnalyzer.analyze(JointSeries(frames: [], bodyHeight: nil, usedDepth: false))
        #expect(analysis.reps.isEmpty)
        #expect(analysis.findings.contains { $0.title == "No reps detected" })
    }
}

struct SerializationTests {
    @Test func jointSeriesRoundTrips() throws {
        let series = SyntheticSquat(repCount: 2).series()
        let data = try JSONEncoder().encode(series)
        let decoded = try JSONDecoder().decode(JointSeries.self, from: data)
        #expect(decoded.frames.count == series.frames.count)
        #expect(decoded.frames[10].positions[.leftKnee] == series.frames[10].positions[.leftKnee])
    }

    @Test func analysisRoundTrips() throws {
        let analysis = SquatAnalyzer.analyze(SyntheticSquat(repCount: 2).series())
        let data = try JSONEncoder().encode(analysis)
        let decoded = try JSONDecoder().decode(SquatAnalysis.self, from: data)
        #expect(decoded.reps.count == analysis.reps.count)
        #expect(decoded.score == analysis.score)
    }

    /// Sessions saved before stance/bottom-shift/lockout metrics existed must
    /// still decode (the new fields are optional).
    @Test func metricsSavedBeforeNewFieldsStillDecode() throws {
        let legacy = """
        {"repNumber":1,"startTime":0,"endTime":2.5,"eccentricSeconds":1.3,
        "concentricSeconds":1.2,"depthFraction":0.5,"kneeFlexionDegrees":70,
        "hipBelowKneeDegrees":14,"torsoLeanDegrees":30,"kneeValgusRatio":0.05,
        "asymmetryDegrees":2}
        """
        let decoded = try JSONDecoder().decode(RepMetrics.self, from: Data(legacy.utf8))
        #expect(decoded.stanceWidthRatio == nil)
        #expect(decoded.bottomHipShiftRatio == nil)
        #expect(decoded.lockoutKneeDegrees == nil)
    }
}

struct FormFaultTests {
    private func bottomFrame(_ generator: SyntheticSquat) -> JointFrame {
        let series = generator.series()
        let bottomTime = generator.pauseSeconds + generator.eccentricSeconds
        return series.frames.min { abs($0.time - bottomTime) < abs($1.time - bottomTime) }!
    }

    @Test func cleanBottomHasNoFaults() {
        let faults = FormFaultDetector.faults(in: bottomFrame(SyntheticSquat(repCount: 1)))
        #expect(faults == .none)
    }

    @Test func foldedTorsoFaultsTorsoOnly() {
        let faults = FormFaultDetector.faults(
            in: bottomFrame(SyntheticSquat(repCount: 1, maxTorsoLean: 62))
        )
        #expect(faults.torso)
        #expect(!faults.leftLeg && !faults.rightLeg)
        #expect(BodyJoint.faulted((.spine, .centerShoulder), by: faults))
        #expect(!BodyJoint.faulted((.leftHip, .leftKnee), by: faults))
    }

    @Test func cavingKneesFaultLegs() {
        let faults = FormFaultDetector.faults(
            in: bottomFrame(SyntheticSquat(repCount: 1, valgusShift: 0.09))
        )
        #expect(faults.leftLeg && faults.rightLeg)
        #expect(BodyJoint.faulted((.leftKnee, .leftAnkle), by: faults))
        #expect(!BodyJoint.faulted((.root, .spine), by: faults))
    }

    @Test func standingFrameHasNoFaults() {
        let series = SyntheticSquat(repCount: 1).series()
        let faults = FormFaultDetector.faults(in: series.frames.first!)
        #expect(faults == .none)
    }

    private func repFaults(_ generator: SyntheticSquat, at time: TimeInterval) -> FrameFaults {
        let series = generator.series()
        let reps = MetricsCalculator.metrics(for: RepSegmenter.segment(series), in: series)
        let frame = series.frames.min { abs($0.time - time) < abs($1.time - time) }!
        return FormFaultDetector.faults(in: frame, at: frame.time, reps: reps)
    }

    @Test func shallowRepBottomFaultsLegs() {
        let generator = SyntheticSquat(repCount: 1, maxFemurAngle: 55)
        let bottom = generator.pauseSeconds + generator.eccentricSeconds
        let faults = repFaults(generator, at: bottom)
        #expect(faults.leftLeg && faults.rightLeg)
        #expect(!faults.torso)
    }

    @Test func deepRepBottomKeepsLegsGreen() {
        let generator = SyntheticSquat(repCount: 1, maxFemurAngle: 105)
        let bottom = generator.pauseSeconds + generator.eccentricSeconds
        let faults = repFaults(generator, at: bottom)
        #expect(faults == .none)
    }

    @Test func freeFallDescentFaultsLegs() {
        var generator = SyntheticSquat(repCount: 1)
        generator.eccentricSeconds = 0.35
        let midDescent = generator.pauseSeconds + generator.eccentricSeconds / 2
        let faults = repFaults(generator, at: midDescent)
        #expect(faults.leftLeg && faults.rightLeg)
    }
}

struct SmoothingTests {
    @Test func smoothingReducesJitter() {
        let clean = SyntheticSquat(repCount: 2, noise: 0).series()
        let noisy = SyntheticSquat(repCount: 2, noise: 0.01).series()
        let smoothed = JointSeriesSmoother.smoothed(noisy, window: 5)

        func meanError(_ series: JointSeries) -> Float {
            var total: Float = 0
            var count = 0
            for (frame, reference) in zip(series.frames, clean.frames) {
                for (joint, position) in frame.positions {
                    guard let ref = reference.positions[joint] else { continue }
                    total += simd_length(position - ref)
                    count += 1
                }
            }
            return total / Float(max(count, 1))
        }
        #expect(meanError(smoothed) < meanError(noisy))
    }
}
