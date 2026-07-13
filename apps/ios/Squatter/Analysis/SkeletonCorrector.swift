import Foundation
import simd

/// Re-poses each frame's pelvis to match what the camera actually saw.
///
/// Vision's real-footage failure mode (measured on pulled sessions): at the
/// bottom of a deep squat the 3D skeleton stays internally consistent —
/// bone lengths hold to ~0.02% — but the whole pose is estimated too
/// shallow, pelvis high, because deep flexion is rare in the model's prior.
/// Length constraints are therefore blind to it. The 2D detector still
/// follows the actual pixels, so the femur's true elevation is measurable
/// without knowing the camera direction:
///
///     sin(elevation) = metric vertical drop of hip vs knee / femur length
///
/// where the drop is image-y difference × the frame's LiDAR metric scale
/// and the femur length comes from the scanned `MetricBodyGeometry` (the
/// pre-scan profile, or this session's standing frames). The pelvis (root
/// and both hips, rigid) is translated so each model femur takes the
/// image-measured elevation at its model-space length, keeping its
/// horizontal bearing — image azimuth is view-dependent, elevation is not,
/// with the camera held level.
///
/// Two asymmetric trust rules, both from real footage:
/// - **Deepen only.** The 3D prior never exaggerates depth, while the image
///   reading goes shallow under camera pitch or a 2D hip glitch — a pulled
///   tilted-camera session lost 30° on good reps when the image was trusted
///   both ways. The deeper of the two estimates is the better one.
/// - **Only at depth.** The anchor engages only when the model already sits
///   in the bottom half of a squat — the sole region the mis-projection
///   exists in — so 2D glitches on standing frames can't invent descents
///   (and phantom reps) out of nothing.
enum SkeletonCorrector {
    /// The rigid pelvis: the joints Vision poses too high at depth.
    private static let pelvis: [BodyJoint] = [.root, .leftHip, .rightHip]

    static func corrected(
        _ series: JointSeries, geometry: BodyGeometry, metric: MetricBodyGeometry?
    ) -> JointSeries {
        // A noisy metric scan would anchor the pose to garbage.
        guard let metric, metric.quality <= AnalysisTuning.geometryScanQualityGate
        else { return series }
        var result = series
        for index in result.frames.indices {
            anchorPelvisToImage(&result.frames[index], geometry: geometry, metric: metric)
        }
        return result
    }

    private static func anchorPelvisToImage(
        _ frame: inout JointFrame, geometry: BodyGeometry, metric: MetricBodyGeometry
    ) {
        guard let scale = frame.metersPerImageHeight else { return }
        var shifts: [SIMD3<Float>] = []
        for (hip, knee) in [(BodyJoint.leftHip, BodyJoint.leftKnee), (.rightHip, .rightKnee)] {
            guard let hipImage = frame.imagePoints[hip], let kneeImage = frame.imagePoints[knee],
                  let hipModel = frame.positions[hip], let kneeModel = frame.positions[knee],
                  let femurLength = geometry.length(hip, knee)
            else { continue }
            let drop = Double((kneeImage.y - hipImage.y) * scale)
            let sine = Float(max(-1, min(1, drop / metric.femurMeters)))
            let femur = hipModel - kneeModel
            let modelSine = -femur.y / max(simd_length(femur), 1e-5)
            guard modelSine > AnalysisTuning.geometryAnchorModelSineFloor,
                  sine > modelSine + 0.02 else { continue }
            let horizontal = SIMD3<Float>(femur.x, 0, femur.z)
            let horizontalLength = simd_length(horizontal)
            // Near-vertical femur: the elevation is ±90° no matter what,
            // and the bearing is undefined — nothing to fix.
            guard horizontalLength > 0.02 else { continue }
            let target = kneeModel
                + horizontal / horizontalLength * (femurLength * sqrt(max(0, 1 - sine * sine)))
                - SIMD3<Float>(0, femurLength * sine, 0)
            shifts.append(target - hipModel)
        }
        guard !shifts.isEmpty else { return }
        var shift = shifts.reduce(.zero, +) / Float(shifts.count)
        let magnitude = simd_length(shift)
        if magnitude > AnalysisTuning.geometryAnchorMaxShiftMeters {
            shift *= AnalysisTuning.geometryAnchorMaxShiftMeters / magnitude
        }
        for joint in pelvis { frame.positions[joint]? += shift }
        // Keep the documented convention: model space stays root-anchored.
        if let root = frame.positions[.root], root != .zero {
            for joint in frame.positions.keys { frame.positions[joint]! -= root }
        }
    }
}
