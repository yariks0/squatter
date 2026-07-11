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

/// Bone lengths in *real* meters, measured camera-side: a standing joint's
/// image-y drop times the frame's LiDAR metric scale is its true vertical
/// extent, and standing femurs and shins are vertical. Unlike model-space
/// lengths (which ride Vision's 1.80 m body prior and its pose estimate),
/// these come from the 2D detector, which follows actual pixels — so they
/// can anchor the pose where the 3D model drifts. Best measured by a
/// dedicated standing scan in a controlled setup (`BodyGeometryProfile`);
/// a session's own standing frames are the fallback.
struct MetricBodyGeometry: Codable, Sendable, Equatable {
    var femurMeters: Double
    var shinMeters: Double
    /// Median absolute deviation of the femur samples over their median —
    /// the scan's noise level. Real scans sit at 0.02–0.06; above
    /// `AnalysisTuning.geometryScanQualityGate` the scan is unusable.
    var quality: Double

    /// Pooled (both sides) medians over standing frames with a LiDAR scale.
    /// Standing = the bones hang vertical, so the image-y drop *is* the
    /// length. nil without enough clean samples or outside human range.
    static func measure(from frames: [JointFrame]) -> MetricBodyGeometry? {
        var femurs: [Double] = []
        var shins: [Double] = []
        for frame in frames {
            guard let scale = frame.metersPerImageHeight else { continue }
            for (hip, knee, ankle) in [
                (BodyJoint.leftHip, BodyJoint.leftKnee, BodyJoint.leftAnkle),
                (.rightHip, .rightKnee, .rightAnkle),
            ] {
                if let h = frame.imagePoints[hip], let k = frame.imagePoints[knee] {
                    let drop = Double((h.y - k.y) * scale)
                    if drop > 0.1 { femurs.append(drop) }
                }
                if let k = frame.imagePoints[knee], let a = frame.imagePoints[ankle] {
                    let drop = Double((k.y - a.y) * scale)
                    if drop > 0.1 { shins.append(drop) }
                }
            }
        }
        guard femurs.count >= AnalysisTuning.geometryMinimumScanFrames,
              shins.count >= AnalysisTuning.geometryMinimumScanFrames
        else { return nil }
        let femur = median(of: femurs)
        let shin = median(of: shins)
        guard AnalysisTuning.geometryFemurRangeMeters.contains(femur) else { return nil }
        let quality = median(of: femurs.map { abs($0 - femur) }) / femur
        return MetricBodyGeometry(femurMeters: femur, shinMeters: shin, quality: quality)
    }

    private static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
