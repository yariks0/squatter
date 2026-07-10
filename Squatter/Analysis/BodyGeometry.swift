import Foundation
import simd

/// The lifter's scanned skeleton: median bone lengths measured from the
/// standing frames of a session, where Vision tracks reliably. Real bones
/// don't change length mid-set, so these calibrated lengths let
/// `SkeletonCorrector` pull mis-projected joints — the pelvis at the bottom
/// of a deep squat — back onto the body that was actually scanned.
struct BodyGeometry: Codable, Sendable, Equatable {
    struct Bone: Codable, Sendable, Equatable {
        var from: BodyJoint
        var to: BodyJoint
        var meters: Float
    }

    var bones: [Bone]

    /// Bones the scan measures: the pelvis–leg–torso chain the hip
    /// mis-projection corrupts. Arms are left free — wrists follow the bar
    /// and elbows hinge fast, so constraining them buys nothing for the
    /// joints that actually drift.
    static let scannedBones: [(BodyJoint, BodyJoint)] = [
        (.root, .leftHip), (.root, .rightHip), (.leftHip, .rightHip),
        (.leftHip, .leftKnee), (.rightHip, .rightKnee),
        (.leftKnee, .leftAnkle), (.rightKnee, .rightAnkle),
        (.root, .spine), (.spine, .centerShoulder),
        (.centerShoulder, .leftShoulder), (.centerShoulder, .rightShoulder),
    ]

    func length(_ from: BodyJoint, _ to: BodyJoint) -> Float? {
        bones.first {
            ($0.from == from && $0.to == to) || ($0.from == to && $0.to == from)
        }?.meters
    }

    /// Median length of every scanned bone across the given frames; nil
    /// unless the full chain was measured in enough frames — a partial scan
    /// (legs cropped, shoulders occluded) can't anchor a correction.
    static func measure(from frames: [JointFrame]) -> BodyGeometry? {
        guard frames.count >= AnalysisTuning.geometryMinimumScanFrames else { return nil }
        var bones: [Bone] = []
        for (from, to) in scannedBones {
            var lengths: [Float] = []
            for frame in frames {
                guard let a = frame.position(from), let b = frame.position(to) else { continue }
                let length = simd_length(a - b)
                if length > 1e-4 { lengths.append(length) }
            }
            guard lengths.count >= AnalysisTuning.geometryMinimumScanFrames else { return nil }
            lengths.sort()
            bones.append(Bone(from: from, to: to, meters: lengths[lengths.count / 2]))
        }
        return BodyGeometry(bones: bones)
    }
}
