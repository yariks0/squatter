import Foundation
import simd

/// Savitzky–Golay smoothing of joint tracks (quadratic fit over a sliding
/// window). Pose estimates jitter frame to frame; metrics need the
/// underlying motion. Unlike the moving average this replaced, a quadratic
/// SG filter reproduces curvature exactly — the bottom of a rep keeps its
/// true depth and angles instead of being dragged toward mid-rep values,
/// and derivatives (bar velocity) keep their peaks.
enum JointSeriesSmoother {
    /// Quadratic SG convolution weights for a centered 5-sample window.
    /// Any second-order polynomial passes through unchanged.
    private static let weights: [Float] = [-3, 12, 17, 12, -3].map { $0 / 35 }

    static func smoothed(_ series: JointSeries, window: Int = 5) -> JointSeries {
        guard window > 1, series.frames.count > 1 else { return series }
        let half = weights.count / 2
        // Image points drive the overlay, where a wide window visibly lags
        // fast-moving joints mid-rep; keep their window tighter.
        let imageHalf = max(1, half - 1)
        let frames = series.frames
        var result = series

        for index in frames.indices {
            for joint in frames[index].positions.keys {
                if let value: SIMD3<Float> = filtered(
                    at: index, half: half, in: frames, of: { $0.positions[joint] }
                ) {
                    result.frames[index].positions[joint] = value
                }
            }
            for joint in frames[index].imagePoints.keys {
                if let value: SIMD2<Float> = filtered(
                    at: index, half: imageHalf, in: frames, of: { $0.imagePoints[joint] }
                ) {
                    result.frames[index].imagePoints[joint] = value
                }
            }
        }
        return result
    }

    /// SG when the full centered window is available for the joint; plain
    /// average of whatever is present near the series edges or through
    /// detection dropouts — do not invent joints the detector didn't see.
    private static func filtered<Value: SIMD>(
        at index: Int, half: Int, in frames: [JointFrame],
        of track: (JointFrame) -> Value?
    ) -> Value? where Value.Scalar == Float {
        let lower = index - half
        let upper = index + half
        if half == weights.count / 2, lower >= 0, upper < frames.count {
            let values = (lower ... upper).compactMap { track(frames[$0]) }
            if values.count == weights.count {
                var smoothed = Value.zero
                for (offset, value) in values.enumerated() {
                    smoothed += value * weights[offset]
                }
                return smoothed
            }
        }
        var sum = Value.zero
        var count = 0
        for neighbor in max(0, lower) ... min(frames.count - 1, upper) {
            guard let value = track(frames[neighbor]) else { continue }
            sum += value
            count += 1
        }
        guard count > 0 else { return nil }
        return sum / Float(count)
    }
}
