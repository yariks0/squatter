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
        // Elbows straight out from the shoulders at the touch — a T position.
        generator.touchElbowOffset = SIMD3(0.30, -0.03, 0.0)
        let analysis = SquatAnalyzer.analyze(generator.series(), activity: .benchPress)
        #expect(analysis.findings.contains {
            $0.title.localizedCaseInsensitiveContains("flare")
                || $0.title.localizedCaseInsensitiveContains("elbows")
        })
    }

    @Test func flagsCutHighReps() {
        var generator = SyntheticBench(repCount: 5)
        // The bar turns around well above the chest with the arms barely bent.
        generator.touchWristOffset = SIMD3(0.02, 0.30, 0.05)
        generator.touchElbowOffset = SIMD3(0.01, 0.155, 0.03)
        let analysis = SquatAnalyzer.analyze(generator.series(), activity: .benchPress)
        #expect(analysis.findings.contains { $0.title == "Cutting the rep high" })
    }

    @Test func flagsSoftLockout() {
        // restProgress runs through the easing curve, so 0.4 holds the arms
        // ~35% short of lockout between reps (elbow ≈ 135°).
        let analysis = SquatAnalyzer.analyze(
            SyntheticBench(repCount: 5, restProgress: 0.4).series(), activity: .benchPress
        )
        #expect(analysis.findings.contains { $0.title == "Not locking out" })
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
