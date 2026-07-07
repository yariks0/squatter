import Foundation
import simd

/// Which parts of the body are out of position in a single frame, judged with
/// the same thresholds the rules engine uses. Drives the overlay coloring:
/// faulted parts draw red instead of green.
struct FrameFaults: Equatable, Sendable {
    var torso = false
    var leftLeg = false
    var rightLeg = false

    static let none = FrameFaults()
}

enum FormFaultDetector {
    /// Window around a shallow rep's bottom during which the missed depth is
    /// shown on the legs.
    private static let shallowBottomWindow: TimeInterval = 0.35

    /// Frame faults with rep context: instantaneous checks (torso, valgus)
    /// plus rep-level ones mapped to the moment they happen — missed depth
    /// lights the legs around the bottom, a free-fall descent lights them
    /// through the drop.
    static func faults(in frame: JointFrame, at time: TimeInterval, reps: [RepMetrics]) -> FrameFaults {
        var faults = faults(in: frame)
        guard let rep = reps.first(where: { time >= $0.startTime && time <= $0.endTime })
        else { return faults }
        let bottomTime = rep.startTime + rep.eccentricSeconds
        let shallow = rep.hipBelowKneeDegrees < AnalysisTuning.parallelToleranceDegrees
        if shallow, abs(time - bottomTime) <= shallowBottomWindow {
            faults.leftLeg = true
            faults.rightLeg = true
        }
        let freeFall = rep.eccentricSeconds < AnalysisTuning.minimumEccentricSeconds
        if freeFall, time <= bottomTime {
            faults.leftLeg = true
            faults.rightLeg = true
        }
        return faults
    }

    static func faults(in frame: JointFrame) -> FrameFaults {
        var faults = FrameFaults()

        if let root = frame.position(.root), let shoulders = frame.position(.centerShoulder) {
            let trunk = shoulders - root
            let length = simd_length(trunk)
            if length > 1e-6 {
                let lean = Double(acos(max(-1, min(1, trunk.y / length)))) * 180 / .pi
                faults.torso = lean >= AnalysisTuning.torsoLeanWarningDegrees
            }
        }

        if let leftHip = frame.position(.leftHip), let rightHip = frame.position(.rightHip) {
            let hipWidth = simd_length(leftHip - rightHip)
            if hipWidth > 1e-6 {
                faults.leftLeg = valgusRatio(
                    frame, hip: leftHip, knee: .leftKnee, ankle: .leftAnkle,
                    otherHip: rightHip, hipWidth: hipWidth
                ) >= AnalysisTuning.valgusWarningRatio
                faults.rightLeg = valgusRatio(
                    frame, hip: rightHip, knee: .rightKnee, ankle: .rightAnkle,
                    otherHip: leftHip, hipWidth: hipWidth
                ) >= AnalysisTuning.valgusWarningRatio
            }
        }
        return faults
    }

    /// Medial deviation of the knee from its hip–ankle line, as a fraction of
    /// hip width — the same construction as `MetricsCalculator.maxValgus`,
    /// for one leg in one frame.
    private static func valgusRatio(
        _ frame: JointFrame,
        hip: SIMD3<Float>,
        knee: BodyJoint,
        ankle: BodyJoint,
        otherHip: SIMD3<Float>,
        hipWidth: Float
    ) -> Double {
        guard let kneePos = frame.position(knee), let anklePos = frame.position(ankle)
        else { return 0 }
        let leg = anklePos - hip
        let legLength = simd_length_squared(leg)
        guard legLength > 1e-6 else { return 0 }
        let t = simd_dot(kneePos - hip, leg) / legLength
        let deviation = kneePos - (hip + t * leg)
        var medial = otherHip - hip
        medial -= leg * (simd_dot(medial, leg) / legLength)
        let medialLength = simd_length(medial)
        guard medialLength > 1e-6 else { return 0 }
        return Double(simd_dot(deviation, medial / medialLength) / hipWidth)
    }
}

extension BodyJoint {
    private static let torsoJoints: Set<BodyJoint> = [.root, .spine, .centerShoulder]
    private static let leftLegJoints: Set<BodyJoint> = [.leftHip, .leftKnee, .leftAnkle]
    private static let rightLegJoints: Set<BodyJoint> = [.rightHip, .rightKnee, .rightAnkle]

    /// Whether a bone belongs to a part that is out of position. Leg checks
    /// skip pelvis links (`root–hip`) — the caving part is the knee line.
    static func faulted(_ bone: (BodyJoint, BodyJoint), by faults: FrameFaults) -> Bool {
        if faults.torso, torsoJoints.contains(bone.0), torsoJoints.contains(bone.1) {
            return true
        }
        let legBone = bone.0 != .root && bone.1 != .root
        if faults.leftLeg, legBone,
           leftLegJoints.contains(bone.0) || leftLegJoints.contains(bone.1) {
            return true
        }
        if faults.rightLeg, legBone,
           rightLegJoints.contains(bone.0) || rightLegJoints.contains(bone.1) {
            return true
        }
        return false
    }

    /// Whether a single joint dot belongs to a part that is out of position.
    func faulted(by faults: FrameFaults) -> Bool {
        (faults.torso && Self.torsoJoints.contains(self))
            || (faults.leftLeg && Self.leftLegJoints.contains(self))
            || (faults.rightLeg && Self.rightLegJoints.contains(self))
    }
}
