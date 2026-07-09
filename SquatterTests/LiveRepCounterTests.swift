import Testing
import simd
@testable import Squatter

/// The online counter is a pure state machine over 2D pose samples, so it
/// tests with hand-built 10 Hz trajectories — no Vision, no camera.
/// Timing note: the live eccentric clock starts at the entry crossing
/// (~40–50% into the descent), so a "controlled" test descent must be
/// ≥ ~1.2 s to stay clear of `liveFastDescentSeconds`.
struct LiveRepCounterTests {
    private static let dt = 0.1

    private static func squatSample(
        time: Double, hipY: Double, kneeY: Double = 0.30,
        hipMissing: Bool = false, foldedTorso: Bool = false
    ) -> LivePoseSample {
        LivePoseSample(
            time: time,
            hipMid: hipMissing ? nil : SIMD2(0.5, hipY),
            kneeMid: SIMD2(0.5, kneeY),
            // A folded torso leans the shoulder ~53° off vertical from the
            // hip; the upright default sits directly above.
            shoulderMid: foldedTorso ? SIMD2(0.70, hipY + 0.15) : SIMD2(0.5, 0.70),
            wristMid: nil,
            noseY: 0.85,
            ankleMidY: 0.10
        )
    }

    /// Piecewise-linear hip height: 2 s standing, then per rep a descent,
    /// bottom hold, ascent, and a standing pause.
    private static func squatTrajectory(
        bottoms: [Double], standing: Double = 0.50,
        descentSeconds: Double = 1.2, holdSeconds: Double = 0.3,
        ascentSeconds: Double? = nil
    ) -> [Double] {
        var values = Array(repeating: standing, count: 20)
        for bottom in bottoms {
            let downSteps = Int(descentSeconds / dt)
            for step in 1 ... downSteps {
                values.append(standing + (bottom - standing) * Double(step) / Double(downSteps))
            }
            values.append(contentsOf: Array(repeating: bottom, count: Int(holdSeconds / dt)))
            let upSteps = Int((ascentSeconds ?? descentSeconds) / dt)
            for step in 1 ... upSteps {
                values.append(bottom + (standing - bottom) * Double(step) / Double(upSteps))
            }
            values.append(contentsOf: Array(repeating: standing, count: 10))
        }
        return values
    }

    private static func run(
        _ hipYs: [Double], kneeY: Double = 0.30, foldedTorso: Bool = false
    ) -> [LiveRepCounter.Event] {
        var counter = LiveRepCounter(activity: .squat)
        var events: [LiveRepCounter.Event] = []
        for (index, hipY) in hipYs.enumerated() {
            let sample = squatSample(
                time: Double(index) * dt, hipY: hipY, kneeY: kneeY, foldedTorso: foldedTorso
            )
            if let event = counter.ingest(sample) { events.append(event) }
        }
        return events
    }

    @Test func countsCleanSquatReps() {
        let events = Self.run(Self.squatTrajectory(bottoms: Array(repeating: 0.28, count: 5)))
        #expect(events.count == 5)
        #expect(events.last == .repCompleted(count: 5, faults: []))
    }

    @Test func flagsShallowRepAsHigh() {
        // Hip turns around above the knee (0.36 vs knee 0.30 + margin). The
        // slow 2 s descent keeps even the shallow rep's late entry crossing
        // clear of the fast-descent call, isolating the depth fault.
        let events = Self.run(Self.squatTrajectory(bottoms: [0.28, 0.36, 0.28], descentSeconds: 2.0))
        #expect(events.count == 3)
        #expect(events[0] == .repCompleted(count: 1, faults: []))
        #expect(events[1] == .repCompleted(count: 2, faults: [.shallowDepth]))
        #expect(events[2] == .repCompleted(count: 3, faults: []))
    }

    @Test func flagsFreeFallDescent() {
        // 0.3 s drop with a long enough bottom hold to still count as a rep.
        let events = Self.run(Self.squatTrajectory(
            bottoms: [0.28], descentSeconds: 0.3, holdSeconds: 0.6
        ))
        #expect(events == [.repCompleted(count: 1, faults: [.fastDescent])])
    }

    @Test func flagsGrindingAscent() {
        let events = Self.run(Self.squatTrajectory(
            bottoms: [0.28], ascentSeconds: 6.0
        ))
        #expect(events == [.repCompleted(count: 1, faults: [.slowAscent])])
    }

    @Test func flagsFoldedTorso() {
        let events = Self.run(Self.squatTrajectory(bottoms: [0.28]), foldedTorso: true)
        #expect(events == [.repCompleted(count: 1, faults: [.torsoFold])])
    }

    @Test func flagsLiftedElbows() {
        // Elbows swung up behind the shoulders (~97° off the torso-down
        // line) through the whole rep.
        var counter = LiveRepCounter(activity: .squat)
        var events: [LiveRepCounter.Event] = []
        for (index, hipY) in Self.squatTrajectory(bottoms: [0.28]).enumerated() {
            var sample = Self.squatSample(time: Double(index) * Self.dt, hipY: hipY)
            sample.elbowMid = sample.shoulderMid! + SIMD2(0.18, 0.02)
            if let event = counter.ingest(sample) { events.append(event) }
        }
        #expect(events == [.repCompleted(count: 1, faults: [.elbowsUp])])
    }

    @Test func ignoresJitterSpikes() {
        // A single-sample dip is far below the minimum rep duration.
        var values = Array(repeating: 0.50, count: 20)
        values.append(0.30)
        values.append(contentsOf: Array(repeating: 0.50, count: 20))
        #expect(Self.run(values).isEmpty)
    }

    @Test func holdsSignalThroughMissingJoints() {
        // Hip tracking drops out around the bottom; the held value must not
        // end the rep or double-count it.
        var counter = LiveRepCounter(activity: .squat)
        var events: [LiveRepCounter.Event] = []
        let values = Self.squatTrajectory(bottoms: [0.28])
        let bottomRange = 30 ..< 34 // inside the late descent / bottom hold
        for (index, hipY) in values.enumerated() {
            let sample = Self.squatSample(
                time: Double(index) * Self.dt, hipY: hipY,
                hipMissing: bottomRange.contains(index)
            )
            if let event = counter.ingest(sample) { events.append(event) }
        }
        #expect(events == [.repCompleted(count: 1, faults: [])])
    }

    private static func runBench(wristYs: [Double]) -> [LiveRepCounter.Event] {
        var counter = LiveRepCounter(activity: .benchPress)
        var events: [LiveRepCounter.Event] = []
        for (index, wristY) in wristYs.enumerated() {
            let sample = LivePoseSample(
                time: Double(index) * dt,
                shoulderMid: SIMD2(0.5, 0.5),
                wristMid: SIMD2(0.5, wristY)
            )
            if let event = counter.ingest(sample) { events.append(event) }
        }
        return events
    }

    /// One bench press: descend, hold, ascend, rest — wrist y against a
    /// shoulder at y 0.5 (so distance = wristY − 0.5).
    private static func benchRep(
        into wristYs: inout [Double], bottom: Double = 0.68,
        downSteps: Int = 12, holdSteps: Int = 3, upSteps: Int = 12
    ) {
        let top = 0.85
        for step in 1 ... downSteps { wristYs.append(top - (top - bottom) * Double(step) / Double(downSteps)) }
        wristYs.append(contentsOf: Array(repeating: bottom, count: holdSteps))
        for step in 1 ... upSteps { wristYs.append(bottom + (top - bottom) * Double(step) / Double(upSteps)) }
        wristYs.append(contentsOf: Array(repeating: top, count: 8))
    }

    @Test func countsBenchRepsAgainstRollingLockout() {
        // 2 s at lockout, then three controlled 1.2 s presses.
        var wristYs = Array(repeating: 0.85, count: 20)
        for _ in 0 ..< 3 { Self.benchRep(into: &wristYs) }
        let events = Self.runBench(wristYs: wristYs)
        #expect(events.count == 3)
        #expect(events.last == .repCompleted(count: 3, faults: []))
    }

    @Test func flagsBenchBounce() {
        // Controlled 1.6 s descent to just above the chest, then a single
        // 0.1 s spike to the true bottom — no dwell.
        var wristYs = Array(repeating: 0.85, count: 20)
        for step in 1 ... 16 { wristYs.append(0.85 - 0.13 * Double(step) / 16) }
        wristYs.append(0.68)
        for step in 1 ... 12 { wristYs.append(0.72 + 0.13 * Double(step) / 12) }
        wristYs.append(contentsOf: Array(repeating: 0.85, count: 8))
        let events = Self.runBench(wristYs: wristYs)
        #expect(events == [.repCompleted(count: 1, faults: [.bounce])])
    }

    @Test func flagsBenchRepCutHigh() {
        // Two full-depth presses, then one that turns around well above the
        // set's touch depth. Its slow 3 s descent keeps the late entry
        // crossing clear of the fast-descent call.
        var wristYs = Array(repeating: 0.85, count: 20)
        for _ in 0 ..< 2 { Self.benchRep(into: &wristYs) }
        Self.benchRep(into: &wristYs, bottom: 0.74, downSteps: 30)
        let events = Self.runBench(wristYs: wristYs)
        #expect(events.count == 3)
        #expect(events.last == .repCompleted(count: 3, faults: [.cutHigh]))
    }
}

struct CoachScriptTests {
    @Test func countsPlainAndPraisesEveryThird() {
        #expect(CoachScript.repLine(count: 1, faults: []) == "1")
        #expect(CoachScript.repLine(count: 3, faults: []) == "3. Good.")
        #expect(CoachScript.repLine(count: 6, faults: []) == "6. Strong.")
    }

    @Test func speaksOnlyTheTopPriorityCue() {
        let line = CoachScript.repLine(count: 2, faults: [.shallowDepth, .fastDescent])
        #expect(line == "2. Go deeper!")
    }
}
