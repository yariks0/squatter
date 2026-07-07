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
}

enum MetricsCalculator {
    static func metrics(for reps: [Rep], in series: JointSeries) -> [RepMetrics] {
        let signal = RepSegmenter.hipAboveAnkleSignal(series)
        let baseline = RepSegmenter.standingBaseline(of: signal)
        return reps.enumerated().map { offset, rep in
            metrics(
                for: rep, number: offset + 1, in: series, signal: signal,
                standingHeight: baseline,
                // Lockout is judged on the best extension reached before the
                // next rep begins (or the series ends).
                lockoutSearchEnd: offset + 1 < reps.count
                    ? reps[offset + 1].startIndex : series.frames.count - 1
            )
        }
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
            lockoutKneeDegrees: lockoutKnee(frames: frames, from: rep.endIndex, to: lockoutSearchEnd)
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

    /// Angle at `vertex` between `a` and `b`, in degrees.
    static func jointAngle(_ frame: JointFrame, _ a: BodyJoint, _ vertex: BodyJoint, _ b: BodyJoint) -> Double? {
        guard let pa = frame.position(a), let pv = frame.position(vertex), let pb = frame.position(b)
        else { return nil }
        let u = pa - pv, v = pb - pv
        let lengths = simd_length(u) * simd_length(v)
        guard lengths > 1e-6 else { return nil }
        let cosine = max(-1, min(1, simd_dot(u, v) / lengths))
        return Double(acos(cosine)) * 180 / .pi
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
        let length = simd_length(trunk)
        guard length > 1e-6 else { return nil }
        return Double(acos(max(-1, min(1, trunk.y / length)))) * 180 / .pi
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
