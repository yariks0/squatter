import Foundation
import Testing
@testable import Squatter

struct KeyframePlannerTests {
    private func imageCount(_ plan: [KeyframePlanner.PlannedFrame]) -> Int {
        plan.reduce(0) { $0 + $1.images.imageCount }
    }

    @Test func squatPlanPairsBottomsAndAddsLockouts() {
        let analysis = SquatAnalyzer.analyze(SyntheticSquat(repCount: 2).series())
        let plan = KeyframePlanner.plan(analysis: analysis)
        let bottoms = plan.filter { $0.phase == .bottom }
        #expect(bottoms.count == 2)
        #expect(bottoms.allSatisfy { $0.images == .pair && $0.tier == 1 })
        #expect(plan.filter { $0.phase == .lockout }.count == 2)
        #expect(!plan.contains { $0.phase == .midAscent })
    }

    @Test func squatValgusAddsMidAscentFrame() {
        var analysis = SquatAnalyzer.analyze(SyntheticSquat(repCount: 2).series())
        analysis.reps[0].kneeValgusRatio = AnalysisTuning.valgusWarningRatio + 0.01
        let plan = KeyframePlanner.plan(analysis: analysis)
        let midAscents = plan.filter { $0.phase == .midAscent }
        #expect(midAscents.map(\.repNumber) == [analysis.reps[0].repNumber])
    }

    /// Valgus is a squat metric; the old extractor ran its gate on every
    /// activity and could emit "check knee tracking" frames for bench reps.
    @Test func valgusGateIsSquatOnly() {
        var analysis = SquatAnalyzer.analyze(
            SyntheticBench().series(), activity: .benchPress
        )
        for index in analysis.reps.indices {
            analysis.reps[index].kneeValgusRatio = 1.0
        }
        let plan = KeyframePlanner.plan(analysis: analysis)
        #expect(!plan.contains { $0.phase == .midAscent })
    }

    @Test func benchPlanCoversSetupTouchLockout() {
        let analysis = SquatAnalyzer.analyze(
            SyntheticBench().series(), activity: .benchPress
        )
        let plan = KeyframePlanner.plan(analysis: analysis)
        for rep in analysis.reps {
            let phases = plan.filter { $0.repNumber == rep.repNumber }.map(\.phase)
            #expect(phases.contains(.setup))
            #expect(phases.contains(.touch))
            #expect(phases.contains(.lockout))
        }
        #expect(plan.filter { $0.phase == .touch }.allSatisfy { $0.images == .pair })
    }

    @Test func deadliftPlanCoversSetupLiftoffLockout() {
        let analysis = SquatAnalyzer.analyze(
            SyntheticDeadlift().series(), activity: .deadlift
        )
        let plan = KeyframePlanner.plan(analysis: analysis)
        for rep in analysis.reps {
            let phases = plan.filter { $0.repNumber == rep.repNumber }.map(\.phase)
            #expect(phases.contains(.setup))
            #expect(phases.contains(.liftoff))
            #expect(phases.contains(.lockout))
        }
        // Liftoff sits inside the concentric, after the floor.
        for frame in plan where frame.phase == .liftoff {
            let rep = analysis.reps.first { $0.repNumber == frame.repNumber }!
            #expect(frame.time > rep.startTime + rep.eccentricSeconds)
            #expect(frame.time < rep.endTime)
        }
    }

    /// A long set degrades to the image budget while the keystone reps
    /// (first, last, worst jitter) keep their raw+overlay verification pairs.
    @Test func longSetDegradesToBudgetKeepingKeystonePairs() {
        var analysis = SquatAnalyzer.analyze(
            SyntheticBench(repCount: 12).series(), activity: .benchPress
        )
        #expect(analysis.reps.count == 12)
        for index in analysis.reps.indices {
            analysis.reps[index].trackingJitter = 0.001
        }
        analysis.reps[5].trackingJitter = 0.05

        for budget in [30, 20, 10] {
            let plan = KeyframePlanner.plan(analysis: analysis, budget: budget)
            #expect(imageCount(plan) <= budget)
            for keystone in [
                analysis.reps.first!.repNumber,
                analysis.reps.last!.repNumber,
                analysis.reps[5].repNumber,
            ] {
                #expect(plan.contains { $0.repNumber == keystone && $0.images == .pair },
                        "budget \(budget): keystone rep \(keystone) lost its pair")
            }
        }
    }
}
