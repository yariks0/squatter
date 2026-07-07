import Foundation
import simd
@testable import Squatter

/// Generates synthetic squat joint series in Vision's model-space convention
/// (root at origin, y up, meters) so segmentation, metrics, and rules can be
/// tested deterministically without real recordings.
struct SyntheticSquat {
    var repCount = 5
    /// Peak femur angle from vertical, degrees. ~95° is just below parallel,
    /// ~50° is a clearly shallow squat.
    var maxFemurAngle = 95.0
    /// Peak medial knee shift, meters (0 = perfect tracking).
    var valgusShift = 0.0
    /// Torso lean from vertical at the bottom, degrees.
    var maxTorsoLean = 35.0
    /// Ankle separation as a multiple of hip width (1 = heels under hips).
    var stanceScale = 1.0
    /// Lateral pelvis-over-feet oscillation amplitude near the bottom, meters.
    var bottomWobbleMeters = 0.0
    /// Squat progress held between reps: 0 = full lockout, >0 = the lifter
    /// never stands up fully.
    var restProgress = 0.0
    var eccentricSeconds = 1.2
    var concentricSeconds = 1.0
    /// Hold at the bottom of each rep (0 = touch-and-go).
    var bottomPauseSeconds = 0.0
    var pauseSeconds = 1.0
    var frameRate = 15.0
    var noise = 0.0
    var seed: UInt64 = 7

    let femurLength: Float = 0.45
    let shinLength: Float = 0.42
    let torsoLength: Float = 0.52
    let hipHalfWidth: Float = 0.14

    func series() -> JointSeries {
        var frames: [JointFrame] = []
        var rng = SplitMix64(seed: seed)
        let dt = 1.0 / frameRate
        var time = 0.0

        func addPhase(duration: Double, phase: @escaping (Double) -> Double) {
            let steps = Int(duration / dt)
            for step in 0 ..< steps {
                let progress = Double(step) / Double(max(steps - 1, 1))
                frames.append(frame(at: time, squatProgress: phase(progress), rng: &rng))
                time += dt
            }
        }

        let rest = restProgress
        addPhase(duration: pauseSeconds) { _ in rest }
        for _ in 0 ..< repCount {
            addPhase(duration: eccentricSeconds) { rest + $0 * (1 - rest) }
            addPhase(duration: bottomPauseSeconds) { _ in 1 }
            addPhase(duration: concentricSeconds) { 1 - $0 * (1 - rest) }
            addPhase(duration: pauseSeconds) { _ in rest }
        }
        return JointSeries(frames: frames, bodyHeight: 1.78, usedDepth: false)
    }

    /// `squatProgress` 0 = standing, 1 = bottom.
    private func frame(at time: Double, squatProgress: Double, rng: inout SplitMix64) -> JointFrame {
        // Ease for a natural velocity profile.
        let eased = 0.5 - 0.5 * cos(squatProgress * .pi)
        let femurAngle = Float(eased * maxFemurAngle * .pi / 180)
        let shinAngle = min(femurAngle * 0.45, Float(35.0 * .pi / 180))
        let torsoAngle = Float(eased * maxTorsoLean * .pi / 180)
        // Valgus appears in the deep half of the movement.
        let valgus = Float(max(0, eased - 0.5) * 2 * valgusShift)
        // Pelvis-over-feet wobble only while sitting in the bottom; in
        // root-anchored space it shows up as both ankles shifting laterally.
        // Slow enough (1.2 Hz) to survive the pipeline's smoothing window,
        // matching how real hip rocking looks.
        let wobbleGate = min(max((eased - 0.85) / 0.15, 0), 1)
        let wobble = Float(wobbleGate * bottomWobbleMeters * sin(time * 2 * .pi * 1.2))

        var positions: [BodyJoint: SIMD3<Float>] = [:]
        positions[.root] = .zero
        positions[.spine] = SIMD3(0, torsoLength / 2 * cos(torsoAngle), torsoLength / 2 * sin(torsoAngle))
        positions[.centerShoulder] = SIMD3(0, torsoLength * cos(torsoAngle), torsoLength * sin(torsoAngle))
        positions[.centerHead] = positions[.centerShoulder]! + SIMD3(0, 0.12, 0)
        positions[.topHead] = positions[.centerShoulder]! + SIMD3(0, 0.28, 0)

        for (side, sign) in [("left", Float(-1)), ("right", Float(1))] {
            let hip = SIMD3(sign * hipHalfWidth, 0, 0)
            // Non-default stances move the ankle off the hip line; the knee
            // splits the difference so it still tracks the hip–ankle line.
            let stanceOffset = sign * hipHalfWidth * Float(stanceScale - 1)
            var knee = hip + SIMD3(0, -femurLength * cos(femurAngle), femurLength * sin(femurAngle))
            knee.x -= sign * valgus // medial shift: toward the body midline
            knee.x += stanceOffset / 2
            let ankle = knee + SIMD3(
                sign * valgus + stanceOffset / 2 + wobble, // planted under the stance line
                -shinLength * cos(shinAngle),
                -shinLength * sin(shinAngle)
            )
            let prefix = side
            positions[BodyJoint(rawValue: "\(prefix)Hip")!] = hip
            positions[BodyJoint(rawValue: "\(prefix)Knee")!] = knee
            positions[BodyJoint(rawValue: "\(prefix)Ankle")!] = ankle
            positions[BodyJoint(rawValue: "\(prefix)Shoulder")!] =
                positions[.centerShoulder]! + SIMD3(sign * 0.18, 0, 0)
        }

        if noise > 0 {
            for key in positions.keys {
                positions[key]! += SIMD3(
                    Float(rng.nextGaussian() * noise),
                    Float(rng.nextGaussian() * noise),
                    Float(rng.nextGaussian() * noise)
                )
            }
        }
        return JointFrame(time: time, positions: positions, imagePoints: [:])
    }
}

/// Deterministic RNG so tests are reproducible.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextUniform() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func nextGaussian() -> Double {
        // Box–Muller.
        let u = max(nextUniform(), 1e-12)
        let v = nextUniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}
