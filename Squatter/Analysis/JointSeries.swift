import Foundation
import simd

/// Body joints tracked by the analysis pipeline. Mirrors Vision's 17-joint
/// 3D body skeleton but keeps the analysis code independent of Vision so it
/// can be unit-tested with synthetic data.
enum BodyJoint: String, Codable, CaseIterable, Sendable {
    case root, spine, centerShoulder, centerHead, topHead
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle

    /// Skeleton edges for drawing overlays.
    static let bones: [(BodyJoint, BodyJoint)] = [
        (.root, .spine), (.spine, .centerShoulder), (.centerShoulder, .centerHead),
        (.centerHead, .topHead),
        (.centerShoulder, .leftShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.centerShoulder, .rightShoulder), (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.root, .leftHip), (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.root, .rightHip), (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]
}

/// One analyzed video frame: model-space joint positions (meters, relative to
/// the root joint, y up) plus normalized image-space points (Vision
/// convention: origin bottom-left) for overlay rendering.
struct JointFrame: Codable, Sendable {
    var time: TimeInterval
    var positions: [BodyJoint: SIMD3<Float>]
    var imagePoints: [BodyJoint: SIMD2<Float>]

    func position(_ joint: BodyJoint) -> SIMD3<Float>? { positions[joint] }
}

struct JointSeries: Codable, Sendable {
    var frames: [JointFrame]
    /// Median body-height estimate in meters (more accurate with LiDAR depth).
    var bodyHeight: Float?
    /// Whether LiDAR depth contributed to the extraction.
    var usedDepth: Bool

    var duration: TimeInterval {
        guard let first = frames.first, let last = frames.last else { return 0 }
        return last.time - first.time
    }
}
