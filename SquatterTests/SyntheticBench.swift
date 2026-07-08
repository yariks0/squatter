import Foundation
import simd
@testable import Squatter

/// Generates synthetic bench-press joint series in Vision's model-space
/// convention (root at origin, y up, meters). The lifter lies along -z
/// (head away from the pelvis), so the press axis is world-up and the bar
/// height signal is the wrist midpoint above the shoulder midpoint.
struct SyntheticBench {
    var repCount = 5
    /// Press progress held between reps: 0 = full lockout, >0 = the lifter
    /// never straightens the arms.
    var restProgress = 0.0
    var eccentricSeconds = 1.2
    var concentricSeconds = 1.0
    /// Hold with the bar at the chest (0 = touch-and-go).
    var bottomPauseSeconds = 0.3
    /// Lockout hold between reps.
    var pauseSeconds = 1.0
    var frameRate = 15.0
    var noise = 0.0
    var seed: UInt64 = 7

    // Arm endpoints relative to each shoulder, mirrored in x per side.
    /// Wrist at the touch: directly above the touch elbow (vertical
    /// forearm), at a lower-chest touch point.
    var touchWristOffset = SIMD3<Float>(0.225, 0.205, 0.186)
    /// Elbow at the touch: tucked ~52° from the torso line.
    var touchElbowOffset = SIMD3<Float>(0.225, -0.075, 0.186)
    var lockoutWristOffset = SIMD3<Float>(0, 0.58, 0)
    var lockoutElbowOffset = SIMD3<Float>(0, 0.30, 0)

    let torsoLength: Float = 0.52
    let shoulderHalfWidth: Float = 0.18
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
                frames.append(frame(at: time, pressProgress: phase(progress), rng: &rng))
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

    /// `pressProgress` 0 = lockout, 1 = bar at the chest.
    private func frame(at time: Double, pressProgress: Double, rng: inout SplitMix64) -> JointFrame {
        let eased = Float(0.5 - 0.5 * cos(pressProgress * .pi))

        var positions: [BodyJoint: SIMD3<Float>] = [:]
        positions[.root] = .zero
        // Torso lies flat along -z with the head past the shoulders.
        positions[.spine] = SIMD3(0, 0, -torsoLength / 2)
        positions[.centerShoulder] = SIMD3(0, 0, -torsoLength)
        positions[.centerHead] = SIMD3(0, 0.02, -torsoLength - 0.15)
        positions[.topHead] = SIMD3(0, 0.03, -torsoLength - 0.3)

        for (side, sign) in [("left", Float(-1)), ("right", Float(1))] {
            let shoulder = positions[.centerShoulder]! + SIMD3(sign * shoulderHalfWidth, 0, 0)
            let mirror = SIMD3<Float>(sign, 1, 1)
            let elbow = shoulder
                + (lockoutElbowOffset + (touchElbowOffset - lockoutElbowOffset) * eased) * mirror
            let wrist = shoulder
                + (lockoutWristOffset + (touchWristOffset - lockoutWristOffset) * eased) * mirror
            // Legs bent, feet planted past the bench.
            let hip = SIMD3(sign * hipHalfWidth, 0, 0)
            let knee = hip + SIMD3(sign * 0.03, 0.08, 0.4)
            let ankle = knee + SIMD3(sign * 0.02, -0.45, 0.1)

            positions[BodyJoint(rawValue: "\(side)Shoulder")!] = shoulder
            positions[BodyJoint(rawValue: "\(side)Elbow")!] = elbow
            positions[BodyJoint(rawValue: "\(side)Wrist")!] = wrist
            positions[BodyJoint(rawValue: "\(side)Hip")!] = hip
            positions[BodyJoint(rawValue: "\(side)Knee")!] = knee
            positions[BodyJoint(rawValue: "\(side)Ankle")!] = ankle
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
