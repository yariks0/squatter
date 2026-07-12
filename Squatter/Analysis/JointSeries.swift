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
    /// Metric scale at the lifter's depth plane: meters spanned by the full
    /// image height (LiDAR body depth × pixel height ÷ focal length), so
    /// Δmeters = Δnormalized-y × this. nil without LiDAR or when the depth
    /// reading was rejected; optional so old persisted analyses decode.
    var metersPerImageHeight: Float?
    /// 2D-detector confidence per joint (the 3D observation exposes none).
    /// A missing key means the joint's image point is the 3D re-projection —
    /// the 2D detector never reported it. nil = analyzed before confidence
    /// was stored; optional so old persisted analyses decode.
    var jointConfidences: [BodyJoint: Float]?
    /// Joints whose position/image point was repaired by `JointTrackRepair`
    /// (despiked, or bridged through a short dropout) rather than detected.
    /// Optional so old persisted analyses decode.
    var repairedJoints: Set<BodyJoint>?

    func position(_ joint: BodyJoint) -> SIMD3<Float>? { positions[joint] }

    /// Whether this joint's data is a hint rather than a detection: it was
    /// repaired by `JointTrackRepair`, or the 2D detector reported it below
    /// `AnalysisTuning.overlayConfidenceFloor` (a missing entry in a
    /// confidence-carrying frame means the image point is the drifting 3D
    /// re-projection). Frames saved before confidences existed count as
    /// certain, so old sessions keep their full-strength overlay.
    func isUncertain(_ joint: BodyJoint) -> Bool {
        if repairedJoints?.contains(joint) == true { return true }
        guard let jointConfidences else { return false }
        return (jointConfidences[joint] ?? 0) < AnalysisTuning.overlayConfidenceFloor
    }
}

/// One full-rate bar observation: the wrist midpoint's normalized image y
/// and the metric scale of its frame. The 2D detector is cheap enough to
/// run on every capture frame (30 fps), so bar velocity gets twice the
/// temporal resolution of the 3D joint series.
struct BarSample: Codable, Sendable, Equatable {
    var time: TimeInterval
    /// Wrist-midpoint image y, Vision-normalized (origin bottom-left).
    var y: Double
    /// Meters per full image height at the lifter's plane; nil without
    /// LiDAR (see `JointFrame.metersPerImageHeight`).
    var scale: Double?
}

struct JointSeries: Codable, Sendable {
    var frames: [JointFrame]
    /// Median body-height estimate in meters (more accurate with LiDAR depth).
    var bodyHeight: Float?
    /// Whether LiDAR depth contributed to the extraction.
    var usedDepth: Bool
    /// Full-capture-rate bar trajectory for velocity; optional so analyses
    /// saved before it existed still decode.
    var barTrack: [BarSample]?
    /// Video width / height. Normalized image x and y span different pixel
    /// counts, so horizontal metric measurements (shoulder width, T-pose arm
    /// lengths) need this to convert: Δmeters = Δx × aspect ×
    /// `metersPerImageHeight`. Optional so old analyses decode.
    var imageAspectRatio: Float?

    var duration: TimeInterval {
        guard let first = frames.first, let last = frames.last else { return 0 }
        return last.time - first.time
    }
}
