import Foundation
import simd
import Testing
@testable import Squatter

struct BenchSegmentationTests {
    @Test func countsCleanReps() {
        let series = SyntheticBench(repCount: 5).series()
        let reps = RepSegmenter.segment(series, activity: .benchPress)
        #expect(reps.count == 5)
    }

    @Test func countsNoisyReps() {
        let series = SyntheticBench(repCount: 8, noise: 0.008).series()
        let smoothed = JointSeriesSmoother.smoothed(series, window: AnalysisTuning.smoothingWindow)
        let reps = RepSegmenter.segment(smoothed, activity: .benchPress)
        #expect(reps.count == 8)
    }

    @Test func ignoresHoldingLockout() {
        var generator = SyntheticBench(repCount: 0)
        generator.pauseSeconds = 10
        let reps = RepSegmenter.segment(generator.series(), activity: .benchPress)
        #expect(reps.isEmpty)
    }
}

struct BenchAnalysisTests {
    @Test func cleanSetHasNoWarnings() {
        let analysis = SquatAnalyzer.analyze(
            SyntheticBench(repCount: 5).series(), activity: .benchPress
        )
        #expect(analysis.kind == .benchPress)
        #expect(analysis.reps.count == 5)
        #expect(!analysis.findings.contains { $0.severity > .info })
        #expect(analysis.score == 100)
    }

    @Test func cleanSetMeasuresBenchMetrics() {
        let analysis = SquatAnalyzer.analyze(
            SyntheticBench(repCount: 3).series(), activity: .benchPress
        )
        for rep in analysis.reps {
            // Bar to the chest: elbow well bent at the touch.
            #expect((rep.elbowFlexionDegrees ?? 180) <= AnalysisTuning.benchFullTouchElbowDegrees)
            // Tucked elbows in the clean configuration.
            #expect((rep.elbowFlareDegrees ?? 0) < AnalysisTuning.benchFlareWarningDegrees)
            // Full lockout between reps.
            #expect((rep.lockoutElbowDegrees ?? 0) >= AnalysisTuning.benchLockoutElbowDegrees)
            // J-curve: head-ward drift from touch to lockout, touch below
            // the shoulders (toward the feet).
            #expect((rep.barPathDriftRatio ?? -1) > 0)
            #expect((rep.touchOffsetRatio ?? 1) < 0)
        }
    }

    @Test func flagsFlaredElbows() {
        var generator = SyntheticBench(repCount: 5)
        // Elbows straight out from the shoulders at the touch — a T position
        // (the forearm tips inward so the bar still reaches press depth).
        generator.touchElbowOffset = SIMD3(0.30, -0.03, 0.0)
        generator.touchWristOffset = SIMD3(0.15, 0.206, 0.0)
        let analysis = SquatAnalyzer.analyze(generator.series(), activity: .benchPress)
        #expect(analysis.findings.contains {
            $0.title.localizedCaseInsensitiveContains("flare")
                || $0.title.localizedCaseInsensitiveContains("elbows")
        })
    }

    @Test func flagsOverTuckedElbows() {
        var generator = SyntheticBench(repCount: 5)
        // Upper arms pinned along the torso (~26° from the torso line).
        generator.touchElbowOffset = SIMD3(0.078, -0.098, 0.273)
        generator.touchWristOffset = SIMD3(0.028, 0.1775, 0.273)
        let analysis = SquatAnalyzer.analyze(generator.series(), activity: .benchPress)
        #expect(analysis.findings.contains { $0.title == "Elbows over-tucked" })
    }

    @Test func flagsTippedForearms() {
        var generator = SyntheticBench(repCount: 5)
        // Wrists well inside the elbows at the touch (~50° forearm tilt).
        generator.touchWristOffset = SIMD3(0.0105, 0.105, 0.186)
        let analysis = SquatAnalyzer.analyze(generator.series(), activity: .benchPress)
        #expect(analysis.findings.contains { $0.title == "Forearms not vertical" })
    }

    @Test func flagsCutHighReps() {
        var generator = SyntheticBench(repCount: 5)
        // The bar turns around well above the chest, elbows only ~122° bent.
        generator.touchElbowOffset = SIMD3(0.15, 0.26, 0.10)
        generator.touchWristOffset = SIMD3(0.05, 0.51, 0.06)
        let analysis = SquatAnalyzer.analyze(generator.series(), activity: .benchPress)
        #expect(analysis.findings.contains { $0.title == "Cutting the rep high" })
    }

    @Test func flagsSoftLockout() {
        // Elbows held slightly bent at the top of every rep (elbow ≈ 152°,
        // below the 160° lockout threshold).
        var generator = SyntheticBench(repCount: 5)
        generator.lockoutElbowOffset = SIMD3(0.12, 0.28, 0.09)
        generator.lockoutWristOffset = SIMD3(0.12, 0.53, 0.09)
        let analysis = SquatAnalyzer.analyze(generator.series(), activity: .benchPress)
        #expect(analysis.findings.contains { $0.title == "Not locking out" })
    }

    @Test func brokenTrackingSuppressesFormRules() {
        // Heavy per-joint noise = unstable bone lengths, the signature of a
        // skeleton Vision could not actually track.
        let analysis = SquatAnalyzer.analyze(
            SyntheticBench(repCount: 5, noise: 0.03).series(), activity: .benchPress
        )
        #expect(analysis.findings.count == 1)
        #expect(analysis.findings.first?.title == "Tracking too unstable to judge form")
    }

    @Test func cleanTrackingKeepsFormRules() {
        let analysis = SquatAnalyzer.analyze(
            SyntheticBench(repCount: 5).series(), activity: .benchPress
        )
        #expect(!analysis.findings.contains { $0.title == "Tracking too unstable to judge form" })
        #expect((analysis.trackingJitter ?? 1) < AnalysisTuning.trackingJitterGateRatio)
    }

    @Test func ignoresImplausiblyLongReps() {
        // A slow sag to the chest and back over ~13 s is a settling hold
        // under the bar (or several reps merged by noise), not a rep.
        var generator = SyntheticBench(repCount: 1)
        generator.eccentricSeconds = 6
        generator.concentricSeconds = 6
        generator.bottomPauseSeconds = 1
        let reps = RepSegmenter.segment(generator.series(), activity: .benchPress)
        #expect(reps.isEmpty)
    }

    @Test func preBenchAnalysisDecodesAsSquat() throws {
        // Sessions saved before bench support have no activity key.
        var analysis = SquatAnalyzer.analyze(SyntheticSquat(repCount: 2).series())
        analysis.activity = nil
        let data = try JSONEncoder().encode(analysis)
        let decoded = try JSONDecoder().decode(SquatAnalysis.self, from: data)
        #expect(decoded.kind == .squat)
    }
}
