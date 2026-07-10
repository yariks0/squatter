import Foundation
import simd
@testable import Squatter

/// Generates synthetic conventional-deadlift joint series in Vision's
/// model-space convention (root at origin, y up, meters). World-space poses
/// are built per pull-progress, then root-anchored, so segmentation,
/// metrics, and rules test deterministically without real recordings.
struct SyntheticDeadlift {
    var repCount = 4
    /// Pre-set hold with the bar on the floor before the first pull.
    var setupSeconds = 3.0
    var pullSeconds = 1.5
    var lockoutHoldSeconds = 0.8
    var lowerSeconds = 1.2
    /// Floor dwell between reps (dead-stop style).
    var pauseSeconds = 1.0
    /// Backward bow of the spine joint off the hip–shoulder chord, meters.
    /// 0 = a dead-straight line; ~0.06 reads ~152° (warning), ~0.10 reads
    /// ~135° (risk).
    var spineRound = 0.0
    /// Extra forward bar swing mid-pull, meters (bar drifting off the legs).
    var barDrift = 0.0
    /// Hips rise ahead of the shoulders off the floor (the stripper pull).
    var hipsShootFirst = false
    var frameRate = 15.0

    func series() -> JointSeries {
        var frames: [JointFrame] = []
        var time = 0.0
        let dt = 1.0 / frameRate

        func addPhase(_ duration: Double, _ pull: @escaping (Double) -> Double) {
            let steps = max(1, Int(duration / dt))
            for step in 0 ..< steps {
                let progress = Double(step) / Double(max(steps - 1, 1))
                frames.append(frame(at: time, pull: pull(progress)))
                time += dt
            }
        }

        addPhase(setupSeconds) { _ in 0 }
        for _ in 0 ..< repCount {
            addPhase(pullSeconds) { $0 }
            addPhase(lockoutHoldSeconds) { _ in 1 }
            addPhase(lowerSeconds) { 1 - $0 }
            addPhase(pauseSeconds) { _ in 0 }
        }
        return JointSeries(frames: frames, bodyHeight: 1.8, usedDepth: false)
    }

    /// One frame at pull progress `p` (0 = bar on the floor, 1 = lockout).
    private func frame(at time: Double, pull p: Double) -> JointFrame {
        let hipP = hipsShootFirst ? min(1, p * 1.8) : p
        let shoulderP = hipsShootFirst ? max(0, (p - 0.45) / 0.55) : p

        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Float {
            Float(a + (b - a) * t)
        }

        let halfStance: Float = 0.14
        let hip = SIMD3<Float>(0, lerp(0.62, 1.00, hipP), lerp(-0.22, 0, hipP))
        // Rigid torso pivoting at the hip (constant length, or the
        // bone-length jitter gate eats the findings): a clean pull
        // straightens the hinge with the hips; the stripper pull pins the
        // shoulders low — the torso tips further — while the hips rise.
        let torsoLength: Float = 0.484
        let hingeAngle: Float
        if hipsShootFirst {
            let pinnedCos = max(-1, min(1, (0.92 - hip.y) / torsoLength))
            hingeAngle = acos(pinnedCos) * Float(1 - shoulderP)
        } else {
            hingeAngle = Float(52.0 * Double.pi / 180) * Float(1 - shoulderP)
        }
        let shoulderCenter = hip + torsoLength * SIMD3(0, cos(hingeAngle), sin(hingeAngle))
        let barY = lerp(0.24, 0.93, p)
        let barZ = Float(0.10 + barDrift * sin(p * .pi))
        let knee = SIMD3<Float>(0, lerp(0.34, 0.50, hipP), lerp(0.13, 0, hipP))

        var world: [BodyJoint: SIMD3<Float>] = [:]
        world[.root] = hip
        world[.leftHip] = hip + SIMD3(-halfStance, 0, 0)
        world[.rightHip] = hip + SIMD3(halfStance, 0, 0)
        world[.leftKnee] = knee + SIMD3(-halfStance, 0, 0)
        world[.rightKnee] = knee + SIMD3(halfStance, 0, 0)
        world[.leftAnkle] = SIMD3(-halfStance, 0.07, 0)
        world[.rightAnkle] = SIMD3(halfStance, 0.07, 0)
        world[.centerShoulder] = shoulderCenter
        world[.leftShoulder] = shoulderCenter + SIMD3(-0.18, 0, 0)
        world[.rightShoulder] = shoulderCenter + SIMD3(0.18, 0, 0)
        world[.centerHead] = shoulderCenter + SIMD3(0, 0.14, 0.05)
        world[.topHead] = shoulderCenter + SIMD3(0, 0.28, 0.05)

        // Spine: the hip–shoulder chord midpoint, bowed off the chord in the
        // sagittal plane when rounding.
        let chord = shoulderCenter - hip
        var spine = (hip + shoulderCenter) / 2
        let chordLength = simd_length(chord)
        if spineRound > 0, chordLength > 1e-6 {
            let normal = simd_normalize(SIMD3<Float>(0, chord.z, -chord.y))
            spine += normal * Float(spineRound)
        }
        world[.spine] = spine

        // Arms hang from the shoulders to the bar.
        let leftWrist = SIMD3<Float>(-0.20, barY, barZ)
        let rightWrist = SIMD3<Float>(0.20, barY, barZ)
        world[.leftWrist] = leftWrist
        world[.rightWrist] = rightWrist
        world[.leftElbow] = (world[.leftShoulder]! + leftWrist) / 2
        world[.rightElbow] = (world[.rightShoulder]! + rightWrist) / 2

        // Root-anchor: Vision's model space keeps the pelvis at the origin.
        var positions: [BodyJoint: SIMD3<Float>] = [:]
        for (joint, position) in world {
            positions[joint] = position - hip
        }
        return JointFrame(time: time, positions: positions, imagePoints: [:])
    }
}
