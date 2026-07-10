import Foundation
import simd

/// Pulls each frame's skeleton back onto the lifter's scanned bone lengths
/// (`BodyGeometry`).
///
/// Vision's 3D pose projects the pelvis markedly too high at the bottom of
/// a deep squat — the hip crease disappears between thigh and torso — so
/// knee flexion and hip-below-knee read shallow on full-depth reps. A
/// raised pelvis is geometrically inconsistent with the scanned body: it
/// stretches the femurs and compresses the root→spine→shoulder chain. The
/// corrector translates the pelvis (root and both hips, kept rigid) until
/// those calibrated lengths hold again against the joints Vision tracks
/// reliably through a squat (knees, shoulder center), with the spine as a
/// free point in between. Only segment *lengths* are enforced, never chain
/// straightness, so real articulation — deadlift spine flexion — survives.
enum SkeletonCorrector {
    /// The rigid pelvis: the joints Vision drags together at depth.
    private static let pelvis: [BodyJoint] = [.root, .leftHip, .rightHip]

    static func corrected(_ series: JointSeries, geometry: BodyGeometry) -> JointSeries {
        var result = series
        for index in result.frames.indices {
            correct(&result.frames[index], geometry: geometry)
        }
        return result
    }

    static func correct(_ frame: inout JointFrame, geometry: BodyGeometry) {
        var positions = frame.positions

        for _ in 0 ..< AnalysisTuning.geometrySolverIterations {
            // Bones tying the pelvis to trusted joints: each length error
            // translates the whole pelvis toward agreement. Gauss–Seidel —
            // consecutive constraints see each other's updates.
            for (pelvisJoint, outside, pelvisShare) in [
                (BodyJoint.leftHip, BodyJoint.leftKnee, Float(1)),
                (.rightHip, .rightKnee, 1),
                // The spine end is itself mobile; split the error so the
                // spine keeps propagating the shoulder anchor downward.
                (.root, .spine, 0.5),
            ] {
                guard let target = geometry.length(pelvisJoint, outside),
                      let p = positions[pelvisJoint], let q = positions[outside]
                else { continue }
                let delta = q - p
                let length = simd_length(delta)
                guard length > 1e-5 else { continue }
                let error = delta / length * (length - target)
                for joint in pelvis { positions[joint]? += error * pelvisShare }
                if pelvisShare < 1 { positions[outside] = q - error * (1 - pelvisShare) }
            }
            // Spine: a free point pushed off the trusted shoulder center to
            // its calibrated distance.
            if let target = geometry.length(.spine, .centerShoulder),
               let spine = positions[.spine], let shoulder = positions[.centerShoulder] {
                let delta = spine - shoulder
                let length = simd_length(delta)
                if length > 1e-5 {
                    positions[.spine] = shoulder + delta / length * target
                }
            }
        }

        // Keep the documented convention: model space stays root-anchored.
        if let root = positions[.root], root != .zero {
            for joint in positions.keys { positions[joint]! -= root }
        }
        frame.positions = positions
    }
}
