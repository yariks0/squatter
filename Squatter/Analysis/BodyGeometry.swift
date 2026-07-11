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
    /// Hip line to shoulder line, standing — the upper-body length, from
    /// the same vertical-drop trick as the legs. Optional: profiles saved
    /// before it existed decode without it.
    var torsoMeters: Double? = nil
    /// Median absolute deviation of the femur samples over their median —
    /// the scan's noise level. Real scans sit at 0.02–0.06; above
    /// `AnalysisTuning.geometryScanQualityGate` the scan is unusable.
    var quality: Double
    // Frontal-segment measurements: horizontal image spans × aspect ratio ×
    // metric scale, taken only on frames where the lifter faces the camera.
    // All optional — a side-on-only scan (or a profile saved before these
    // existed) simply doesn't have them.
    var shoulderWidthMeters: Double? = nil
    var hipWidthMeters: Double? = nil
    // T-pose measurements: arm segments measured while held straight out to
    // the sides, where they lie in the frontal plane. A barbell grip never
    // qualifies (elbows drop below the shoulder line), so in-session scans
    // won't record garbage arms.
    var upperArmMeters: Double? = nil
    var forearmMeters: Double? = nil
    /// Hip-below-knee at the scan's deep unloaded hold, measured with the
    /// same image-drop formula the pelvis anchor uses — the lifter's own
    /// full-depth reference, with whatever residual 2D hip-keypoint bias
    /// their body produces baked in. Only the dedicated scan flow measures
    /// it (a session's own bottoms are loaded and are the thing being
    /// judged, so calibrating on them would be circular).
    var deepestHipBelowKneeDegrees: Double? = nil

    /// Pooled (both sides) medians over standing frames with a LiDAR scale.
    /// Standing = the leg bones hang vertical, so the image-y drop *is* the
    /// length; widths and arms additionally need the aspect ratio and
    /// qualifying (frontal / arms-out) frames. nil without enough clean leg
    /// samples or outside human range.
    static func measure(
        from frames: [JointFrame], aspectRatio: Float?, deepFrames: [JointFrame] = []
    ) -> MetricBodyGeometry? {
        var femurs: [Double] = []
        var shins: [Double] = []
        var torsos: [Double] = []
        var shoulders: [Double] = []
        var hips: [Double] = []
        var upperArms: [Double] = []
        var forearms: [Double] = []
        for frame in frames {
            guard let scale = frame.metersPerImageHeight else { continue }
            var femurImageLength: Float = 0
            for (hip, knee, ankle) in [
                (BodyJoint.leftHip, BodyJoint.leftKnee, BodyJoint.leftAnkle),
                (.rightHip, .rightKnee, .rightAnkle),
            ] {
                if let h = frame.imagePoints[hip], let k = frame.imagePoints[knee] {
                    let drop = Double((h.y - k.y) * scale)
                    if drop > 0.1 { femurs.append(drop) }
                    femurImageLength = max(femurImageLength, simd_length(h - k))
                }
                if let k = frame.imagePoints[knee], let a = frame.imagePoints[ankle] {
                    let drop = Double((k.y - a.y) * scale)
                    if drop > 0.1 { shins.append(drop) }
                }
            }
            // Upper body: hip line to shoulder line, vertical while standing
            // like the legs, so it works from any camera bearing.
            let hipYs = [frame.imagePoints[.leftHip], frame.imagePoints[.rightHip]]
                .compactMap { $0?.y }
            let shoulderYs = [frame.imagePoints[.leftShoulder], frame.imagePoints[.rightShoulder]]
                .compactMap { $0?.y }
            if !hipYs.isEmpty, !shoulderYs.isEmpty {
                let drop = Double((shoulderYs.reduce(0, +) / Float(shoulderYs.count)
                    - hipYs.reduce(0, +) / Float(hipYs.count)) * scale)
                if drop > 0.15 { torsos.append(drop) }
            }
            guard let aspectRatio, femurImageLength > 1e-4 else { continue }

            func widthMeters(_ left: BodyJoint, _ right: BodyJoint) -> Double? {
                guard let l = frame.imagePoints[left], let r = frame.imagePoints[right]
                else { return nil }
                return Double(abs(l.x - r.x) * aspectRatio * scale)
            }
            // Frontal gate: same criterion the stance metric uses — from the
            // side the shoulder span collapses below the femur's image length.
            if let leftShoulder = frame.imagePoints[.leftShoulder],
               let rightShoulder = frame.imagePoints[.rightShoulder],
               abs(leftShoulder.x - rightShoulder.x)
                   > femurImageLength * AnalysisTuning.stanceViewGateRatio {
                if let width = widthMeters(.leftShoulder, .rightShoulder) { shoulders.append(width) }
                if let width = widthMeters(.leftHip, .rightHip) { hips.append(width) }

                // Arms held straight out: each segment near-horizontal
                // (within ~20° — a hanging or bar-gripping arm fails).
                for (shoulder, elbow, wrist) in [
                    (BodyJoint.leftShoulder, BodyJoint.leftElbow, BodyJoint.leftWrist),
                    (.rightShoulder, .rightElbow, .rightWrist),
                ] {
                    guard let s = frame.imagePoints[shoulder], let e = frame.imagePoints[elbow],
                          let w = frame.imagePoints[wrist] else { continue }
                    func horizontalMeters(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Double? {
                        let dx = abs(a.x - b.x) * aspectRatio
                        let dy = abs(a.y - b.y)
                        guard dx > 0.02, dy < dx * 0.36 else { return nil }
                        return Double(sqrt(dx * dx + dy * dy) * scale)
                    }
                    if let upper = horizontalMeters(s, e), let fore = horizontalMeters(e, w) {
                        upperArms.append(upper)
                        forearms.append(fore)
                    }
                }
            }
        }
        guard femurs.count >= AnalysisTuning.geometryMinimumScanFrames,
              shins.count >= AnalysisTuning.geometryMinimumScanFrames
        else { return nil }
        let femur = median(of: femurs)
        let shin = median(of: shins)
        guard AnalysisTuning.geometryFemurRangeMeters.contains(femur) else { return nil }
        let minimum = AnalysisTuning.geometryMinimumScanFrames

        // Deep-hold stage: the same drop formula the pelvis anchor applies,
        // evaluated at the lifter's own deepest unloaded position.
        var deepAngles: [Double] = []
        for frame in deepFrames {
            guard let scale = frame.metersPerImageHeight else { continue }
            for (hip, knee) in [(BodyJoint.leftHip, BodyJoint.leftKnee), (.rightHip, .rightKnee)] {
                guard let h = frame.imagePoints[hip], let k = frame.imagePoints[knee]
                else { continue }
                let sine = Double((k.y - h.y) * scale) / femur
                guard abs(sine) <= 1 else { continue }
                deepAngles.append(asin(sine) * 180 / .pi)
            }
        }

        return MetricBodyGeometry(
            femurMeters: femur,
            shinMeters: shin,
            torsoMeters: torsos.count >= minimum ? median(of: torsos) : nil,
            quality: median(of: femurs.map { abs($0 - femur) }) / femur,
            shoulderWidthMeters: shoulders.count >= minimum ? median(of: shoulders) : nil,
            hipWidthMeters: hips.count >= minimum ? median(of: hips) : nil,
            upperArmMeters: upperArms.count >= minimum ? median(of: upperArms) : nil,
            forearmMeters: forearms.count >= minimum ? median(of: forearms) : nil,
            deepestHipBelowKneeDegrees: deepAngles.count >= minimum ? median(of: deepAngles) : nil
        )
    }

    private static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
