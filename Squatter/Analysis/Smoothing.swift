import Foundation
import simd

/// Centered moving-average smoothing of joint tracks. Pose estimates jitter
/// frame to frame; metrics (angles at the bottom of a rep, valgus deviation)
/// need the underlying motion, not the noise.
enum JointSeriesSmoother {
    static func smoothed(_ series: JointSeries, window: Int = 5) -> JointSeries {
        guard window > 1, series.frames.count > 1 else { return series }
        let half = window / 2
        // Image points drive the overlay, where a wide window visibly lags
        // fast-moving joints mid-rep; keep their window tighter.
        let imageHalf = max(1, half - 1)
        let frames = series.frames
        var result = series

        for index in frames.indices {
            var positionSums: [BodyJoint: (SIMD3<Float>, Int)] = [:]
            var imageSums: [BodyJoint: (SIMD2<Float>, Int)] = [:]
            for neighbor in max(0, index - half) ... min(frames.count - 1, index + half) {
                for (joint, position) in frames[neighbor].positions {
                    let entry = positionSums[joint] ?? (.zero, 0)
                    positionSums[joint] = (entry.0 + position, entry.1 + 1)
                }
            }
            for neighbor in max(0, index - imageHalf) ... min(frames.count - 1, index + imageHalf) {
                for (joint, point) in frames[neighbor].imagePoints {
                    let entry = imageSums[joint] ?? (.zero, 0)
                    imageSums[joint] = (entry.0 + point, entry.1 + 1)
                }
            }
            // Only smooth joints present in the current frame; do not invent
            // joints the detector didn't see.
            for joint in frames[index].positions.keys {
                if let (sum, count) = positionSums[joint], count > 0 {
                    result.frames[index].positions[joint] = sum / Float(count)
                }
            }
            for joint in frames[index].imagePoints.keys {
                if let (sum, count) = imageSums[joint], count > 0 {
                    result.frames[index].imagePoints[joint] = sum / Float(count)
                }
            }
        }
        return result
    }
}
