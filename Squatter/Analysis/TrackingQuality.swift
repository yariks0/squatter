import Foundation
import simd

/// Detects broken pose tracking from bone-length stability. A real skeleton
/// has constant bone lengths; when Vision loses the body (occlusion, bad
/// framing, lying poses) the per-frame joint estimates jump and the measured
/// "bones" stretch frame to frame. Real sessions separate cleanly: well-framed
/// squats measure 0.0002–0.0009 median frame-to-frame jitter, while the first
/// bench recording (head and hips out of frame) measured 0.0099.
enum TrackingQuality {
    private static let limbBones: [(BodyJoint, BodyJoint)] = [
        (.leftShoulder, .leftElbow), (.rightShoulder, .rightElbow),
        (.leftElbow, .leftWrist), (.rightElbow, .rightWrist),
        (.leftHip, .leftKnee), (.rightHip, .rightKnee),
        (.leftKnee, .leftAnkle), (.rightKnee, .rightAnkle),
    ]

    /// Bones tracked in fewer frames than this carry no signal.
    private static let minimumSamples = 10

    /// Median across limb bones of the median frame-to-frame relative change
    /// in the bone's length. Frame-to-frame (not deviation from the bone's
    /// median) so slow real articulation reads as stable while tracking
    /// flicker — joints jumping between frames — reads as jitter. Infinite
    /// when no bone was tracked long enough to measure.
    static func boneLengthJitter(of series: JointSeries) -> Double {
        var jitters: [Double] = []
        for (from, to) in limbBones {
            let lengths: [Double?] = series.frames.map { frame in
                guard let a = frame.position(from), let b = frame.position(to) else { return nil }
                return Double(simd_length(a - b))
            }
            let tracked = lengths.compactMap { $0 }
            guard tracked.count >= minimumSamples else { continue }
            let reference = median(of: tracked)
            guard reference > 0 else { continue }
            var deltas: [Double] = []
            for (previous, current) in zip(lengths, lengths.dropFirst()) {
                if let previous, let current {
                    deltas.append(abs(current - previous) / reference)
                }
            }
            guard deltas.count >= minimumSamples else { continue }
            jitters.append(median(of: deltas))
        }
        guard !jitters.isEmpty else { return .infinity }
        return median(of: jitters)
    }

    private static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
