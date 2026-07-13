import Testing
@testable import Squatter

struct DeadliftAnalysisTests {
    @Test func cleanSetCountsAllPullsIncludingTheFirst() {
        // The set starts with the bar already on the floor — the setup hold
        // must not swallow the first pull the way a too-long window would.
        let analysis = SquatAnalyzer.analyze(
            SyntheticDeadlift(repCount: 4).series(), activity: .deadlift
        )
        #expect(analysis.reps.count == 4)
        #expect(!analysis.findings.contains { $0.severity == .risk })
        #expect(analysis.findings.contains { $0.title == "Neutral spine held" })
        for rep in analysis.reps {
            #expect((rep.spineFlexionDegrees ?? 0) > AnalysisTuning.deadliftSpineFlexionWarningDegrees)
        }
    }

    @Test func roundedBackIsRiskFlagged() {
        var set = SyntheticDeadlift(repCount: 3)
        set.spineRound = 0.10
        let analysis = SquatAnalyzer.analyze(set.series(), activity: .deadlift)
        #expect(analysis.findings.contains {
            $0.title == "Back rounding under load" && $0.severity == .risk
        })
        #expect((analysis.reps.first?.spineFlexionDegrees ?? 180)
            < AnalysisTuning.deadliftSpineFlexionRiskDegrees)
    }

    @Test func slightRoundingWarns() {
        var set = SyntheticDeadlift(repCount: 3)
        set.spineRound = 0.06
        let analysis = SquatAnalyzer.analyze(set.series(), activity: .deadlift)
        #expect(analysis.findings.contains { $0.title == "Back losing its line" })
        #expect(!analysis.findings.contains { $0.severity == .risk })
    }

    @Test func barSwingingAwayFlagged() {
        var set = SyntheticDeadlift(repCount: 3)
        set.barDrift = 0.22
        let analysis = SquatAnalyzer.analyze(set.series(), activity: .deadlift)
        #expect(analysis.findings.contains { $0.title == "Bar drifting off your legs" })
        #expect((analysis.reps.first?.barGapRatio ?? 0) > AnalysisTuning.deadliftBarGapWarningRatio)
    }

    @Test func hipsShootingUpFlagged() {
        var set = SyntheticDeadlift(repCount: 3)
        set.hipsShootFirst = true
        let analysis = SquatAnalyzer.analyze(set.series(), activity: .deadlift)
        #expect(analysis.findings.contains { $0.title == "Hips shooting up first" })
        #expect((analysis.reps.first?.hipShootRatio ?? 0) >= AnalysisTuning.deadliftHipShootRatio)
    }

    @Test func deadStopResetsAreNotCalledBounces() {
        let analysis = SquatAnalyzer.analyze(
            SyntheticDeadlift(repCount: 4, pauseSeconds: 1.0).series(), activity: .deadlift
        )
        #expect(!analysis.findings.contains { $0.title == "Bouncing off the floor" })
    }
}
