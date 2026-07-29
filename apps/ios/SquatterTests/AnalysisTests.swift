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

    /// Frames before the first tracked sample (lifter walking into frame)
    /// carry no signal: they used to emit 0.0 — "deepest possible position" —
    /// and segment a phantom rep out of thin air.
    @Test func leadingUntrackedFramesDoNotSegmentPhantomRep() {
        var series = SyntheticSquat(repCount: 3).series()
        for index in series.frames.indices where series.frames[index].time < 1.0 {
            series.frames[index].positions = [:]
        }
        let signal = RepSegmenter.hipAboveAnkleSignal(series)
        #expect(signal.prefix(15).allSatisfy { $0 == nil })
        let reps = RepSegmenter.segment(series)
        #expect(reps.count == 3)
    }

    /// A dropout longer than the hold limit *inside* a rep is occlusion,
    /// not the end of the window: the rep survives with its true tempo
    /// instead of being dropped or split into a fragment whose collapsed
    /// eccentric would read as a free-fall descent.
    @Test func interiorOcclusionDoesNotDropOrSplitReps() throws {
        let generator = SyntheticSquat(repCount: 3)
        var series = generator.series()
        let cycle = generator.eccentricSeconds + generator.concentricSeconds
            + generator.pauseSeconds
        // A ~0.4 s ankle gap in the middle of rep 2's descent…
        let rep2DescentMid = generator.pauseSeconds + cycle + generator.eccentricSeconds / 2
        // …and another in the middle of rep 3's ascent, spanning territory
        // the exit walk must cross.
        let rep3AscentMid = generator.pauseSeconds + 2 * cycle
            + generator.eccentricSeconds + generator.concentricSeconds / 2
        for index in series.frames.indices
        where abs(series.frames[index].time - rep2DescentMid) < 0.2
            || abs(series.frames[index].time - rep3AscentMid) < 0.2 {
            series.frames[index].positions.removeValue(forKey: .leftAnkle)
            series.frames[index].positions.removeValue(forKey: .rightAnkle)
        }
        let reps = RepSegmenter.segment(series)
        #expect(reps.count == 3)
        for rep in reps {
            #expect(abs((rep.bottomTime - rep.startTime) - generator.eccentricSeconds) < 0.4)
        }
    }

    /// Short interior dropouts hold the last value (the same limit
    /// `JointTrackRepair` bridges); longer ones are real occlusion and go
    /// missing instead of freezing the signal.
    @Test func interiorDropoutsHoldBrieflyThenGoMissing() throws {
        var series = SyntheticSquat(repCount: 1).series()
        // A 2-frame gap at the standing plateau: held.
        for index in 5 ... 6 {
            series.frames[index].positions.removeValue(forKey: .leftAnkle)
            series.frames[index].positions.removeValue(forKey: .rightAnkle)
        }
        let held = RepSegmenter.hipAboveAnkleSignal(series)
        let standing = try #require(held[4])
        #expect(held[5] == standing && held[6] == standing)

        // A 5-frame gap: beyond the bridge limit, so missing.
        series = SyntheticSquat(repCount: 1).series()
        for index in 5 ... 9 {
            series.frames[index].positions.removeValue(forKey: .leftAnkle)
            series.frames[index].positions.removeValue(forKey: .rightAnkle)
        }
        let missing = RepSegmenter.hipAboveAnkleSignal(series)
        #expect(missing[5] != nil && missing[6] != nil) // within the limit, held
        #expect(missing[7] == nil && missing[8] == nil && missing[9] == nil)
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
            #expect(try #require(rep.hipBelowKneeDegrees) > AnalysisTuning.parallelToleranceDegrees)
        }
    }

    @Test func shallowSquatIsAboveParallel() throws {
        let all = metrics(SyntheticSquat(repCount: 3, maxFemurAngle: 55))
        #expect(all.count == 3)
        for rep in all {
            // 55° femur angle leaves the hip well above the knee.
            #expect(try #require(rep.hipBelowKneeDegrees) < AnalysisTuning.parallelToleranceDegrees)
        }
    }

    /// No femur tracked at the bottom = no depth measurement at all (nil),
    /// and the depth rules stay silent instead of calling the rep shallow.
    @Test func missingFemursYieldNoDepthJudgment() throws {
        let generator = SyntheticSquat(repCount: 2)
        var series = generator.series()
        // Knock out the hip joints around each rep's bottom, like a lifter
        // whose legs leave the frame at depth.
        for rep in 0 ..< generator.repCount {
            let bottom = generator.pauseSeconds
                + Double(rep) * (generator.eccentricSeconds + generator.concentricSeconds
                    + generator.pauseSeconds)
                + generator.eccentricSeconds
            for index in series.frames.indices
            where abs(series.frames[index].time - bottom) < 0.2 {
                series.frames[index].positions.removeValue(forKey: .leftHip)
                series.frames[index].positions.removeValue(forKey: .rightHip)
            }
        }
        let reps = RepSegmenter.segment(series)
        let all = MetricsCalculator.metrics(for: reps, in: series)
        #expect(all.count == 2)
        for rep in all {
            #expect(rep.hipBelowKneeDegrees == nil)
        }
        let findings = FormRules.findings(for: all)
        #expect(!findings.contains {
            ["Good depth", "Close to full depth", "Shallow depth", "Depth in reserve"]
                .contains($0.title)
        })
    }

    /// With some bottoms unmeasured, depth praise speaks only for the reps
    /// it measured instead of claiming "every rep" from a subset.
    @Test func depthPraiseScopedToMeasuredReps() throws {
        let generator = SyntheticSquat(repCount: 2, maxFemurAngle: 105)
        var series = generator.series()
        // Knock out rep 2's hips at the bottom: rep 1 full depth, rep 2
        // unmeasured.
        let bottom = generator.pauseSeconds
            + (generator.eccentricSeconds + generator.concentricSeconds
                + generator.pauseSeconds)
            + generator.eccentricSeconds
        for index in series.frames.indices
        where abs(series.frames[index].time - bottom) < 0.2 {
            series.frames[index].positions.removeValue(forKey: .leftHip)
            series.frames[index].positions.removeValue(forKey: .rightHip)
        }
        let reps = MetricsCalculator.metrics(for: RepSegmenter.segment(series), in: series)
        #expect(reps.count == 2)
        #expect(reps[0].hipBelowKneeDegrees != nil)
        #expect(reps[1].hipBelowKneeDegrees == nil)
        let good = try #require(FormRules.findings(for: reps).first { $0.title == "Good depth" })
        #expect(good.repNumbers == [1])
        #expect(!good.detail.contains("every rep"))
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
        // Stance is judged from the 2D image spans, so the synthetic camera
        // must be frontal enough and emitting image points.
        var generator = SyntheticSquat(repCount: 2)
        generator.metersPerImageHeight = 2.2
        for (scale, expectNarrow, expectWide) in [(1.0, false, false), (0.5, true, false), (2.5, false, true)] {
            generator.stanceScale = scale
            for rep in metrics(generator) {
                let ratio = try #require(rep.stanceWidthRatio)
                #expect((ratio < AnalysisTuning.stanceNarrowRatio) == expectNarrow)
                #expect((ratio > AnalysisTuning.stanceWideRatio) == expectWide)
            }
        }
    }

    /// From a side view the shoulder span collapses and stance cannot be
    /// judged honestly — the metric must go silent instead of guessing.
    @Test func stanceUnjudgedFromSideView() {
        var generator = SyntheticSquat(repCount: 2, stanceScale: 2.5)
        generator.metersPerImageHeight = 2.2
        generator.imageYawDegrees = 90
        for rep in metrics(generator) {
            #expect(rep.stanceWidthRatio == nil)
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
        generator.metersPerImageHeight = 2.2
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
        #expect(decoded.trackingJitter == nil)
    }

    @Test func jointConfidencesRoundTrip() throws {
        var series = SyntheticSquat(repCount: 1).series()
        series.frames[3].jointConfidences = [.leftKnee: 0.9, .rightWrist: 0.2]
        series.frames[3].repairedJoints = [.leftHip]
        let data = try JSONEncoder().encode(series)
        let decoded = try JSONDecoder().decode(JointSeries.self, from: data)
        #expect(decoded.frames[3].jointConfidences == [.leftKnee: 0.9, .rightWrist: 0.2])
        #expect(decoded.frames[3].repairedJoints == [.leftHip])
    }

    /// Frames saved before per-joint confidence and track repair existed must
    /// still decode (the new fields are optional).
    @Test func frameSavedBeforeConfidenceStillDecodes() throws {
        let legacy = """
        {"time":0.5,"positions":["leftKnee",[0.1,0.2,0.3]],
        "imagePoints":["leftKnee",[0.4,0.5]]}
        """
        let decoded = try JSONDecoder().decode(JointFrame.self, from: Data(legacy.utf8))
        #expect(decoded.jointConfidences == nil)
        #expect(decoded.repairedJoints == nil)
    }
}

struct TrackingGateTests {
    /// Gaussian joint noise injected only into frames inside `window` —
    /// someone walking through the frame mid-set.
    private func corrupt(
        _ series: inout JointSeries, window: ClosedRange<TimeInterval>, seed: UInt64
    ) {
        var rng = SplitMix64(seed: seed)
        for index in series.frames.indices
        where window.contains(series.frames[index].time) {
            for key in series.frames[index].positions.keys {
                series.frames[index].positions[key]! += SIMD3(
                    Float(rng.nextGaussian() * 0.03),
                    Float(rng.nextGaussian() * 0.03),
                    Float(rng.nextGaussian() * 0.03)
                )
            }
        }
    }

    /// Clean 5-rep squat whose third rep (7.4–9.6 s) flickers.
    private func seriesWithBrokenRep3() -> JointSeries {
        var series = SyntheticSquat(repCount: 5).series()
        corrupt(&series, window: 7.5 ... 9.5, seed: 11)
        return series
    }

    @Test func frameJitterLocalizesBrokenStretch() {
        let smoothed = JointSeriesSmoother.smoothed(seriesWithBrokenRep3())
        // The whole-series median never sees the short bad stretch…
        #expect(
            TrackingQuality.boneLengthJitter(of: smoothed)
                <= AnalysisTuning.trackingJitterGateRatio
        )
        // …the timeline pins it to the corrupted band.
        let timeline = TrackingQuality.frameJitterTimeline(of: smoothed)
        let inside = zip(smoothed.frames, timeline)
            .filter { (8.0 ... 9.0).contains($0.0.time) }.compactMap(\.1).sorted()
        let outside = zip(smoothed.frames, timeline)
            .filter { $0.0.time < 6.5 || $0.0.time > 10.5 }.compactMap(\.1)
        #expect(!inside.isEmpty && !outside.isEmpty)
        #expect(inside[inside.count / 2] > AnalysisTuning.repTrackingJitterGateRatio)
        #expect(outside.max()! < AnalysisTuning.repTrackingJitterGateRatio)
    }

    @Test func badStretchSuppressesOnlyAffectedReps() throws {
        let analysis = SquatAnalyzer.analyze(seriesWithBrokenRep3())
        #expect(analysis.reps.count == 5)
        let rep3 = try #require(analysis.reps.first { $0.repNumber == 3 })
        #expect((rep3.trackingJitter ?? 0) > AnalysisTuning.repTrackingJitterGateRatio)
        // The suppressed rep is named in one info finding, and no form rule
        // cites it — its angles are noise, not faults.
        let partial = try #require(analysis.findings.first {
            $0.title.contains("couldn't be tracked")
        })
        #expect(partial.severity == .info)
        #expect(partial.repNumbers == [3])
        #expect(analysis.findings.allSatisfy {
            !$0.repNumbers.contains(3) || $0.title.contains("couldn't be tracked")
        })
    }

    /// A rep window with too few tracked bones to measure jitter (nil, not a
    /// small number) must not pass the per-rep gate as "clean" — unmeasurable
    /// is untrusted, so the rep is suppressed like one over the gate.
    @Test func unmeasurableRepJitterIsNotTrusted() throws {
        // Rep cycle = 1.2 + 1.0 + 4 s; rep 2 runs roughly 10.2–12.4 s. Strip
        // everything but the shins there: fewer than the timeline's minimum
        // 3 bones stay tracked, so the window's jitter is unmeasurable while
        // the hip-above-ankle signal (root + ankles) still segments the rep.
        var series = SyntheticSquat(repCount: 2, pauseSeconds: 4).series()
        for index in series.frames.indices
        where (10.0 ... 12.6).contains(series.frames[index].time) {
            series.frames[index].positions = series.frames[index].positions.filter {
                [.root, .leftKnee, .leftAnkle, .rightKnee, .rightAnkle].contains($0.key)
            }
        }
        let analysis = SquatAnalyzer.analyze(series)
        #expect(analysis.reps.count == 2)
        let rep2 = try #require(analysis.reps.first { $0.repNumber == 2 })
        #expect(rep2.trackingJitter == nil)
        let partial = try #require(analysis.findings.first {
            $0.title.contains("couldn't be tracked")
        })
        #expect(partial.repNumbers == [2])
        #expect(analysis.findings.allSatisfy {
            !$0.repNumbers.contains(2) || $0.title.contains("couldn't be tracked")
        })
    }

    @Test func allRepsUntrackableFallsBackToGlobalFinding() {
        // Long clean pauses keep the whole-series median under the global
        // gate while both rep windows flicker (rep cycle = 1.2 + 1.0 + 4 s).
        var series = SyntheticSquat(repCount: 2, pauseSeconds: 4).series()
        corrupt(&series, window: 4.1 ... 6.1, seed: 12)
        corrupt(&series, window: 10.3 ... 12.3, seed: 13)
        let analysis = SquatAnalyzer.analyze(series)
        #expect(analysis.findings.count == 1)
        #expect(analysis.findings.first?.title == "Tracking too unstable to judge form")
    }

    @Test func cleanSetHasNoSuppressedReps() {
        let analysis = SquatAnalyzer.analyze(SyntheticSquat(repCount: 5).series())
        #expect(analysis.reps.allSatisfy {
            ($0.trackingJitter ?? 0) <= AnalysisTuning.repTrackingJitterGateRatio
        })
        #expect(!analysis.findings.contains { $0.title.contains("couldn't be tracked") })
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

    /// No femur tracked at the bottom = no depth call: the legs stay green
    /// instead of lighting up on a fabricated "shallow" value.
    @Test func unmeasuredDepthKeepsLegsGreen() {
        let generator = SyntheticSquat(repCount: 1, maxFemurAngle: 55)
        var series = generator.series()
        let bottom = generator.pauseSeconds + generator.eccentricSeconds
        for index in series.frames.indices
        where abs(series.frames[index].time - bottom) < 0.2 {
            series.frames[index].positions.removeValue(forKey: .leftHip)
            series.frames[index].positions.removeValue(forKey: .rightHip)
        }
        let reps = MetricsCalculator.metrics(for: RepSegmenter.segment(series), in: series)
        #expect(reps.first?.hipBelowKneeDegrees == nil)
        let frame = series.frames.min { abs($0.time - bottom) < abs($1.time - bottom) }!
        let faults = FormFaultDetector.faults(in: frame, at: frame.time, reps: reps)
        #expect(faults == .none)
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
