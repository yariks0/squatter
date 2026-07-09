import Foundation
import simd

struct RepMetrics: Codable, Sendable, Identifiable {
    var repNumber: Int
    var id: Int { repNumber }

    var startTime: TimeInterval
    var endTime: TimeInterval
    var eccentricSeconds: Double
    var concentricSeconds: Double

    /// Fraction of standing hip-above-ankle height lost at the bottom.
    var depthFraction: Double
    /// Knee flexion angle at the bottom, degrees (180 = straight leg).
    var kneeFlexionDegrees: Double
    /// Femur angle vs horizontal at the bottom, degrees. Positive means the
    /// hip crease is below the knee (below parallel).
    var hipBelowKneeDegrees: Double
    /// Trunk angle from vertical at the bottom, degrees.
    var torsoLeanDegrees: Double
    /// Peak medial knee deviation during the ascent, as a fraction of hip width.
    var kneeValgusRatio: Double
    /// Left/right knee-angle difference at the bottom, degrees.
    var asymmetryDegrees: Double
    // Optional so sessions analyzed before these metrics existed still decode.
    /// Ankle separation / shoulder width, standing at the start of the rep.
    var stanceWidthRatio: Double?
    /// Horizontal pelvis drift while at the bottom, as a fraction of hip
    /// width ("butt wiggle" — the bottom position should be held still).
    var bottomHipShiftRatio: Double?
    /// Best (max) knee extension reached between this rep's top and the next
    /// descent, degrees (180 = straight). Low = never stood up fully.
    var lockoutKneeDegrees: Double?
    /// Shin angle from vertical at the bottom; with torso lean it gives the
    /// trunk–tibia balance (near-parallel = load centered).
    var shinAngleDegrees: Double?
    /// Horizontal bar-over-midfoot offset at the bottom (shoulder center vs
    /// ankle midpoint), as a fraction of hip width. Coach context.
    var balanceDriftRatio: Double?
    /// Upper-arm angle from the torso line at the bottom (0° = arm hanging
    /// along the torso). The "elbows down" measurement for a barbell squat:
    /// a high-bar grip sits ~30–50°, lifted elbows swing past 70°.
    var elbowLiftDegrees: Double?

    // MARK: Bench press (optional so squat sessions and old JSON decode;
    // squat-only fields above carry neutral values on bench reps and are
    // never shown for them)
    /// Average elbow flexion at the touch, degrees (180 = straight arm).
    var elbowFlexionDegrees: Double?
    /// Upper-arm angle from the torso line at the touch, degrees
    /// (0 = pinned to the side, 90 = T position).
    var elbowFlareDegrees: Double?
    /// Dwell time with the bar at the bottom of the rep.
    var touchPauseSeconds: Double?
    /// Best average elbow extension reached at the top (180 = locked out).
    var lockoutElbowDegrees: Double?
    /// Signed head-ward wrist drift from touch to lockout / shoulder width.
    /// Positive = correct J-curve toward the shoulders.
    var barPathDriftRatio: Double?
    /// Head-ward offset of the wrists from the shoulders at the touch /
    /// shoulder width (negative = toward the feet, i.e. lower chest).
    var touchOffsetRatio: Double?
    /// Average forearm angle from vertical at the touch (0 = bar stacked
    /// over wrist over elbow).
    var forearmTiltDegrees: Double?
    /// Where the ascent was slowest (the sticking region), as a fraction of
    /// the rep's travel above the touch. Coach context, not a rule.
    var stickingHeightFraction: Double?
}

enum MetricsCalculator {
    static func metrics(
        for reps: [Rep], in series: JointSeries, activity: ActivityType = .squat
    ) -> [RepMetrics] {
        let signal = RepSegmenter.liftSignal(series, activity: activity)
        let baseline = RepSegmenter.standingBaseline(of: signal)
        return reps.enumerated().map { offset, rep in
            // Lockout is judged on the best extension reached before the
            // next rep begins (or the series ends).
            let lockoutSearchEnd = offset + 1 < reps.count
                ? reps[offset + 1].startIndex : series.frames.count - 1
            return switch activity {
            case .squat:
                metrics(
                    for: rep, number: offset + 1, in: series, signal: signal,
                    standingHeight: baseline, lockoutSearchEnd: lockoutSearchEnd
                )
            case .benchPress:
                benchMetrics(
                    for: rep, number: offset + 1, in: series, signal: signal,
                    lockoutHeight: baseline, lockoutSearchEnd: lockoutSearchEnd
                )
            }
        }
    }

    // MARK: - Bench press

    private static func benchMetrics(
        for rep: Rep,
        number: Int,
        in series: JointSeries,
        signal: [Double],
        lockoutHeight: Double,
        lockoutSearchEnd: Int
    ) -> RepMetrics {
        let frames = series.frames
        let bottom = frames[rep.bottomIndex]

        let elbowLeft = jointAngle(bottom, .leftShoulder, .leftElbow, .leftWrist)
        let elbowRight = jointAngle(bottom, .rightShoulder, .rightElbow, .rightWrist)
        let elbowAngles = [elbowLeft, elbowRight].compactMap { $0 }

        let path = barPath(frames: frames, rep: rep)

        return RepMetrics(
            repNumber: number,
            startTime: rep.startTime,
            endTime: rep.endTime,
            eccentricSeconds: rep.bottomTime - rep.startTime,
            concentricSeconds: rep.endTime - rep.bottomTime,
            depthFraction: lockoutHeight > 0
                ? (lockoutHeight - signal[rep.bottomIndex]) / lockoutHeight : 0,
            // Neutral values for the squat-only fields; the UI and rules
            // never read them for bench reps.
            kneeFlexionDegrees: 180,
            hipBelowKneeDegrees: 0,
            torsoLeanDegrees: 0,
            kneeValgusRatio: 0,
            asymmetryDegrees: (elbowLeft != nil && elbowRight != nil)
                ? abs(elbowLeft! - elbowRight!) : 0,
            stanceWidthRatio: nil,
            bottomHipShiftRatio: nil,
            lockoutKneeDegrees: nil,
            elbowFlexionDegrees: elbowAngles.isEmpty
                ? nil : elbowAngles.reduce(0, +) / Double(elbowAngles.count),
            elbowFlareDegrees: elbowFlare(bottom),
            touchPauseSeconds: touchPause(
                rep: rep, signal: signal, lockoutHeight: lockoutHeight, frames: frames
            ),
            lockoutElbowDegrees: lockoutElbow(frames: frames, from: rep.endIndex, to: lockoutSearchEnd),
            barPathDriftRatio: path?.drift,
            touchOffsetRatio: path?.touchOffset,
            forearmTiltDegrees: forearmTilt(bottom),
            stickingHeightFraction: stickingHeight(rep: rep, signal: signal, frames: frames)
        )
    }

    /// Average forearm (elbow→wrist) angle from vertical at the touch.
    /// Vertical forearms put the bar straight over the elbow.
    private static func forearmTilt(_ frame: JointFrame) -> Double? {
        var values: [Double] = []
        for (elbow, wrist) in [(BodyJoint.leftElbow, BodyJoint.leftWrist),
                               (.rightElbow, .rightWrist)] {
            guard let elbowPos = frame.position(elbow),
                  let wristPos = frame.position(wrist) else { continue }
            let forearm = wristPos - elbowPos
            guard simd_length(forearm) > 1e-6 else { continue }
            let horizontal = sqrt(forearm.x * forearm.x + forearm.z * forearm.z)
            values.append(Double(atan2(horizontal, forearm.y)) * 180 / .pi)
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Height (fraction of the rep's travel above the touch) where the bar
    /// moved slowest on the way up — the sticking region. The edges of the
    /// ascent are excluded: the bar is legitimately slow leaving the chest
    /// and approaching lockout.
    private static func stickingHeight(
        rep: Rep, signal: [Double], frames: [JointFrame]
    ) -> Double? {
        guard rep.endIndex - rep.bottomIndex >= 4 else { return nil }
        let travel = signal[rep.endIndex] - signal[rep.bottomIndex]
        guard travel > 1e-6 else { return nil }
        var slowest: (velocity: Double, height: Double)?
        for index in (rep.bottomIndex + 1) ..< rep.endIndex {
            let height = (signal[index] - signal[rep.bottomIndex]) / travel
            guard height > 0.15, height < 0.85 else { continue }
            let dt = frames[index + 1].time - frames[index - 1].time
            guard dt > 0 else { continue }
            let velocity = (signal[index + 1] - signal[index - 1]) / dt
            if slowest == nil || velocity < slowest!.velocity {
                slowest = (velocity, height)
            }
        }
        return slowest?.height
    }

    /// Upper-arm angle from the torso line, averaged over both arms. The
    /// torso line points from the shoulder center toward the pelvis, so
    /// 0° = upper arm along the torso. Serves two lifts: bench elbow flare
    /// (90° = a T) and squat elbow lift (90° = elbows swung up to bar height).
    private static func elbowFlare(_ frame: JointFrame) -> Double? {
        guard let root = frame.position(.root),
              let shoulderCenter = frame.position(.centerShoulder) else { return nil }
        let torso = root - shoulderCenter
        guard simd_length(torso) > 1e-6 else { return nil }
        var values: [Double] = []
        for (shoulder, elbow) in [(BodyJoint.leftShoulder, BodyJoint.leftElbow),
                                  (.rightShoulder, .rightElbow)] {
            guard let shoulderPos = frame.position(shoulder),
                  let elbowPos = frame.position(elbow) else { continue }
            let upperArm = elbowPos - shoulderPos
            guard simd_length(upperArm) * simd_length(torso) > 1e-6 else { continue }
            values.append(Double(
                atan2(simd_length(simd_cross(upperArm, torso)), simd_dot(upperArm, torso))
            ) * 180 / .pi)
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Dwell time within the bottom window — how long the bar stayed at the
    /// chest. Near zero on a touch that bounces.
    private static func touchPause(
        rep: Rep, signal: [Double], lockoutHeight: Double, frames: [JointFrame]
    ) -> Double {
        let ceiling = signal[rep.bottomIndex] + lockoutHeight * AnalysisTuning.bottomWindowFraction
        var first = rep.bottomIndex
        while first > rep.startIndex, signal[first - 1] <= ceiling { first -= 1 }
        var last = rep.bottomIndex
        while last < rep.endIndex, signal[last + 1] <= ceiling { last += 1 }
        return frames[last].time - frames[first].time
    }

    /// Best average elbow extension reached between the rep's top crossing
    /// and the next descent — the lockout the lifter actually finished at.
    private static func lockoutElbow(frames: [JointFrame], from: Int, to: Int) -> Double? {
        var best: Double?
        for index in from ... min(max(to, from), frames.count - 1) {
            let frame = frames[index]
            let angles = [
                jointAngle(frame, .leftShoulder, .leftElbow, .leftWrist),
                jointAngle(frame, .rightShoulder, .rightElbow, .rightWrist),
            ].compactMap { $0 }
            guard !angles.isEmpty else { continue }
            let average = angles.reduce(0, +) / Double(angles.count)
            best = max(best ?? -.infinity, average)
        }
        return best
    }

    /// Head-ward wrist travel between the touch and the top of the rep,
    /// plus where the touch sits relative to the shoulders — both as signed
    /// fractions of shoulder width (positive = toward the head).
    private static func barPath(
        frames: [JointFrame], rep: Rep
    ) -> (drift: Double, touchOffset: Double)? {
        func horizontalOffset(_ frame: JointFrame) -> (offset: SIMD3<Float>, headward: SIMD3<Float>, shoulderWidth: Float)? {
            guard let root = frame.position(.root),
                  let shoulderCenter = frame.position(.centerShoulder),
                  let leftShoulder = frame.position(.leftShoulder),
                  let rightShoulder = frame.position(.rightShoulder),
                  let leftWrist = frame.position(.leftWrist),
                  let rightWrist = frame.position(.rightWrist) else { return nil }
            let shoulderWidth = simd_length(leftShoulder - rightShoulder)
            guard shoulderWidth > 1e-6 else { return nil }
            // Head-ward direction: shoulders away from pelvis, flattened to
            // the horizontal plane (the press axis is world-up on a bench).
            var headward = shoulderCenter - root
            headward.y = 0
            let headLength = simd_length(headward)
            guard headLength > 1e-6 else { return nil }
            var offset = (leftWrist + rightWrist) / 2 - (leftShoulder + rightShoulder) / 2
            offset.y = 0
            return (offset, headward / headLength, shoulderWidth)
        }
        guard let touch = horizontalOffset(frames[rep.bottomIndex]),
              let top = horizontalOffset(frames[rep.endIndex]) else { return nil }
        let touchOffset = Double(simd_dot(touch.offset, touch.headward) / touch.shoulderWidth)
        let topOffset = Double(simd_dot(top.offset, top.headward) / top.shoulderWidth)
        return (drift: topOffset - touchOffset, touchOffset: touchOffset)
    }

    private static func metrics(
        for rep: Rep,
        number: Int,
        in series: JointSeries,
        signal: [Double],
        standingHeight: Double,
        lockoutSearchEnd: Int
    ) -> RepMetrics {
        let frames = series.frames
        let bottom = frames[rep.bottomIndex]

        let kneeLeft = jointAngle(bottom, .leftHip, .leftKnee, .leftAnkle)
        let kneeRight = jointAngle(bottom, .rightHip, .rightKnee, .rightAnkle)
        let kneeAngles = [kneeLeft, kneeRight].compactMap { $0 }

        return RepMetrics(
            repNumber: number,
            startTime: rep.startTime,
            endTime: rep.endTime,
            eccentricSeconds: rep.bottomTime - rep.startTime,
            concentricSeconds: rep.endTime - rep.bottomTime,
            depthFraction: standingHeight > 0
                ? (standingHeight - signal[rep.bottomIndex]) / standingHeight : 0,
            kneeFlexionDegrees: kneeAngles.isEmpty ? 180 : kneeAngles.reduce(0, +) / Double(kneeAngles.count),
            hipBelowKneeDegrees: hipBelowKnee(bottom),
            torsoLeanDegrees: torsoLean(bottom) ?? 0,
            kneeValgusRatio: maxValgus(frames: frames, from: rep.bottomIndex, to: rep.endIndex),
            asymmetryDegrees: (kneeLeft != nil && kneeRight != nil) ? abs(kneeLeft! - kneeRight!) : 0,
            stanceWidthRatio: stanceWidth(frames[rep.startIndex]),
            bottomHipShiftRatio: bottomHipShift(rep: rep, signal: signal, standingHeight: standingHeight, frames: frames),
            lockoutKneeDegrees: lockoutKnee(frames: frames, from: rep.endIndex, to: lockoutSearchEnd),
            shinAngleDegrees: shinAngle(bottom),
            balanceDriftRatio: balanceDrift(bottom),
            elbowLiftDegrees: elbowFlare(bottom)
        )
    }

    /// Ankle separation over shoulder separation, taken standing at the rep
    /// start. Roughly 1.0 = heels at shoulder width, ~0.75 = hip width.
    private static func stanceWidth(_ frame: JointFrame) -> Double? {
        guard let leftAnkle = frame.position(.leftAnkle),
              let rightAnkle = frame.position(.rightAnkle),
              let leftShoulder = frame.position(.leftShoulder),
              let rightShoulder = frame.position(.rightShoulder) else { return nil }
        let shoulderWidth = simd_length(leftShoulder - rightShoulder)
        guard shoulderWidth > 1e-6 else { return nil }
        return Double(simd_length(leftAnkle - rightAnkle) / shoulderWidth)
    }

    /// Horizontal pelvis drift across the bottom window, as a fraction of hip
    /// width. Model space is root-anchored, so pelvis motion over planted feet
    /// shows up as the ankle midpoint moving under the root.
    private static func bottomHipShift(
        rep: Rep,
        signal: [Double],
        standingHeight: Double,
        frames: [JointFrame]
    ) -> Double? {
        let ceiling = signal[rep.bottomIndex] + standingHeight * AnalysisTuning.bottomWindowFraction
        var first = rep.bottomIndex
        while first > rep.startIndex, signal[first - 1] <= ceiling { first -= 1 }
        var last = rep.bottomIndex
        while last < rep.endIndex, signal[last + 1] <= ceiling { last += 1 }

        var minX = Float.infinity, maxX = -Float.infinity
        var minZ = Float.infinity, maxZ = -Float.infinity
        var hipWidths: [Float] = []
        for index in first ... last {
            let frame = frames[index]
            guard let root = frame.position(.root) else { continue }
            let ankles = [frame.position(.leftAnkle), frame.position(.rightAnkle)].compactMap { $0 }
            guard !ankles.isEmpty else { continue }
            let mid = ankles.reduce(SIMD3<Float>.zero, +) / Float(ankles.count)
            minX = min(minX, root.x - mid.x); maxX = max(maxX, root.x - mid.x)
            minZ = min(minZ, root.z - mid.z); maxZ = max(maxZ, root.z - mid.z)
            if let leftHip = frame.position(.leftHip), let rightHip = frame.position(.rightHip) {
                hipWidths.append(simd_length(leftHip - rightHip))
            }
        }
        guard minX.isFinite, let hipWidth = hipWidths.max(), hipWidth > 1e-6 else { return nil }
        let drift = (Double(maxX - minX) * Double(maxX - minX)
            + Double(maxZ - minZ) * Double(maxZ - minZ)).squareRoot()
        return drift / Double(hipWidth)
    }

    /// Best average knee extension reached between the rep's top and the next
    /// descent. The rep's end index is only the 97%-of-standing crossing, so
    /// the knees are still bent there; a lifter who stands up fully peaks near
    /// 180° somewhere in this window, one who bounces straight into the next
    /// rep never does.
    private static func lockoutKnee(frames: [JointFrame], from: Int, to: Int) -> Double? {
        var best: Double?
        for index in from ... min(max(to, from), frames.count - 1) {
            let frame = frames[index]
            let angles = [
                jointAngle(frame, .leftHip, .leftKnee, .leftAnkle),
                jointAngle(frame, .rightHip, .rightKnee, .rightAnkle),
            ].compactMap { $0 }
            guard !angles.isEmpty else { continue }
            let average = angles.reduce(0, +) / Double(angles.count)
            best = max(best ?? -.infinity, average)
        }
        return best
    }

    /// Angle at `vertex` between `a` and `b`, in degrees. Computed as
    /// atan2(|u×v|, u·v), which stays precise near 0° and 180° where the
    /// clamped-cosine form loses resolution — exactly the range lockout
    /// angles live in.
    static func jointAngle(_ frame: JointFrame, _ a: BodyJoint, _ vertex: BodyJoint, _ b: BodyJoint) -> Double? {
        guard let pa = frame.position(a), let pv = frame.position(vertex), let pb = frame.position(b)
        else { return nil }
        let u = pa - pv, v = pb - pv
        guard simd_length(u) * simd_length(v) > 1e-6 else { return nil }
        return Double(atan2(simd_length(simd_cross(u, v)), simd_dot(u, v))) * 180 / .pi
    }

    /// Femur angle vs horizontal, averaged over both legs. Positive when the
    /// hip is below the knee.
    private static func hipBelowKnee(_ frame: JointFrame) -> Double {
        var values: [Double] = []
        for (hip, knee) in [(BodyJoint.leftHip, BodyJoint.leftKnee), (.rightHip, .rightKnee)] {
            guard let hipPos = frame.position(hip), let kneePos = frame.position(knee) else { continue }
            let femur = hipPos - kneePos
            let length = simd_length(femur)
            guard length > 1e-6 else { continue }
            // Angle of the knee→hip vector above horizontal; negate so that
            // "hip below knee" is positive.
            values.append(-Double(asin(max(-1, min(1, femur.y / length)))) * 180 / .pi)
        }
        return values.isEmpty ? -90 : values.reduce(0, +) / Double(values.count)
    }

    /// Trunk (root → shoulder center) angle from vertical.
    private static func torsoLean(_ frame: JointFrame) -> Double? {
        guard let root = frame.position(.root), let shoulders = frame.position(.centerShoulder)
        else { return nil }
        let trunk = shoulders - root
        guard simd_length(trunk) > 1e-6 else { return nil }
        let horizontal = sqrt(trunk.x * trunk.x + trunk.z * trunk.z)
        return Double(atan2(horizontal, trunk.y)) * 180 / .pi
    }

    /// Shin (ankle → knee) angle from vertical at the bottom, averaged over
    /// both legs. Together with torso lean this describes the trunk–tibia
    /// balance: near-parallel trunk and shins keep the load centered.
    private static func shinAngle(_ frame: JointFrame) -> Double? {
        var values: [Double] = []
        for (knee, ankle) in [(BodyJoint.leftKnee, BodyJoint.leftAnkle),
                              (.rightKnee, .rightAnkle)] {
            guard let kneePos = frame.position(knee),
                  let anklePos = frame.position(ankle) else { continue }
            let shin = kneePos - anklePos
            guard simd_length(shin) > 1e-6 else { continue }
            let horizontal = sqrt(shin.x * shin.x + shin.z * shin.z)
            values.append(Double(atan2(horizontal, shin.y)) * 180 / .pi)
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Horizontal offset of the bar (shoulder center, where a high-bar
    /// squat carries it) from the ankle midpoint at the bottom, as a
    /// fraction of hip width. Zero = bar balanced over the midfoot;
    /// forward drift adds a lumbar moment arm.
    private static func balanceDrift(_ frame: JointFrame) -> Double? {
        guard let shoulders = frame.position(.centerShoulder),
              let leftHip = frame.position(.leftHip),
              let rightHip = frame.position(.rightHip) else { return nil }
        let ankles = [frame.position(.leftAnkle), frame.position(.rightAnkle)].compactMap { $0 }
        guard !ankles.isEmpty else { return nil }
        let hipWidth = simd_length(leftHip - rightHip)
        guard hipWidth > 1e-6 else { return nil }
        let ankleMid = ankles.reduce(SIMD3<Float>.zero, +) / Float(ankles.count)
        var offset = shoulders - ankleMid
        offset.y = 0
        return Double(simd_length(offset) / hipWidth)
    }

    /// Peak medial deviation of either knee from its hip–ankle line during
    /// the ascent, normalized by hip width. Knees caving inward on the way up
    /// is the classic injury-risk pattern.
    private static func maxValgus(frames: [JointFrame], from: Int, to: Int) -> Double {
        var worst = 0.0
        for index in from ... min(to, frames.count - 1) {
            let frame = frames[index]
            guard let leftHip = frame.position(.leftHip),
                  let rightHip = frame.position(.rightHip) else { continue }
            let hipWidth = simd_length(leftHip - rightHip)
            guard hipWidth > 1e-6 else { continue }

            for (hip, knee, ankle, otherHip) in [
                (leftHip, BodyJoint.leftKnee, BodyJoint.leftAnkle, rightHip),
                (rightHip, .rightKnee, .rightAnkle, leftHip),
            ] {
                guard let kneePos = frame.position(knee), let anklePos = frame.position(ankle)
                else { continue }
                let leg = anklePos - hip
                let legLength = simd_length_squared(leg)
                guard legLength > 1e-6 else { continue }
                // Knee's perpendicular offset from the hip–ankle line.
                let t = simd_dot(kneePos - hip, leg) / legLength
                let closest = hip + t * leg
                let deviation = kneePos - closest
                // Medial direction: from this hip toward the other hip,
                // perpendicular to the leg line.
                var medial = otherHip - hip
                medial -= leg * (simd_dot(medial, leg) / legLength)
                let medialLength = simd_length(medial)
                guard medialLength > 1e-6 else { continue }
                let medialDeviation = simd_dot(deviation, medial / medialLength)
                worst = max(worst, Double(medialDeviation / hipWidth))
            }
        }
        return worst
    }
}
