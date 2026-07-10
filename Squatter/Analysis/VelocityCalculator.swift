import Foundation
import simd

/// Bar-speed metrics: the wrist midpoint's image trajectory (the 2D
/// detector locks onto the bar) times each frame's LiDAR metric scale
/// (`JointFrame.metersPerImageHeight`) gives bar height in meters, and the
/// concentric window of each rep gives velocity — the numbers lifters buy
/// dedicated VBT hardware for. Only available on LiDAR captures; nil
/// wherever the scale or wrists are missing.
enum VelocityCalculator {
    struct RepVelocity: Equatable {
        /// Mean concentric velocity in m/s — displacement over time from
        /// the rep's bottom to its top crossing. The headline VBT metric.
        var mean: Double
        /// Fastest instantaneous velocity inside the concentric: a
        /// Savitzky–Golay derivative over the 30 fps bar track when the
        /// capture recorded one; a coarser central difference over the
        /// 15 fps joint series otherwise.
        var peak: Double
    }

    /// Quadratic SG first-derivative weights, centered 5-sample window
    /// (multiply by 1/dt). Exact on any second-order trajectory.
    private static let sgDerivative: [Double] = [-2, -1, 0, 1, 2].map { $0 / 10 }

    /// Per-rep concentric velocities, index-aligned with `reps`.
    static func concentricVelocities(for reps: [Rep], in series: JointSeries) -> [RepVelocity?] {
        reps.map { rep in
            if let track = series.barTrack, let velocity = velocity(for: rep, track: track) {
                return velocity
            }
            return velocity(for: rep, in: series)
        }
    }

    /// Velocity from the full-rate bar track: rep boundary times are
    /// sub-frame precise, so the window is a time filter, not indices.
    private static func velocity(for rep: Rep, track: [BarSample]) -> RepVelocity? {
        var heights: [(time: TimeInterval, meters: Double)] = []
        var lastScale: Double?
        for sample in track where sample.time >= rep.bottomTime && sample.time <= rep.endTime {
            guard let scale = sample.scale ?? lastScale else { continue }
            lastScale = scale
            heights.append((sample.time, sample.y * scale))
        }
        guard heights.count >= 5, let first = heights.first, let last = heights.last
        else { return nil }
        let duration = last.time - first.time
        guard duration > 0.05 else { return nil }
        let mean = (last.meters - first.meters) / duration
        guard mean > 0 else { return nil }

        var peak = mean
        for index in 2 ..< heights.count - 2 {
            let dt = (heights[index + 2].time - heights[index - 2].time) / 4
            guard dt > 1e-6 else { continue }
            var derivative = 0.0
            for (offset, weight) in sgDerivative.enumerated() {
                derivative += heights[index - 2 + offset].meters * weight
            }
            peak = max(peak, derivative / dt)
        }
        return RepVelocity(mean: mean, peak: peak)
    }

    private static func velocity(for rep: Rep, in series: JointSeries) -> RepVelocity? {
        let frames = series.frames
        guard rep.endIndex > rep.bottomIndex + 1, rep.endIndex < frames.count else { return nil }
        var trail: [(time: TimeInterval, meters: Double)] = []
        for index in rep.bottomIndex ... rep.endIndex {
            let frame = frames[index]
            guard let scale = frame.metersPerImageHeight else { continue }
            let wrists = [frame.imagePoints[.leftWrist], frame.imagePoints[.rightWrist]]
                .compactMap { $0 }
            guard !wrists.isEmpty else { continue }
            let y = wrists.reduce(0.0) { $0 + Double($1.y) } / Double(wrists.count)
            trail.append((frame.time, y * Double(scale)))
        }
        guard trail.count >= 3, let first = trail.first, let last = trail.last else { return nil }

        let duration = last.time - first.time
        guard duration > 0.05 else { return nil }
        let mean = (last.meters - first.meters) / duration
        // A non-positive mean says the wrists never rose — scale noise or a
        // mistracked rep; no number beats a wrong number.
        guard mean > 0 else { return nil }

        var peak = mean
        for index in 1 ..< trail.count - 1 {
            let dt = trail[index + 1].time - trail[index - 1].time
            guard dt > 0 else { continue }
            peak = max(peak, (trail[index + 1].meters - trail[index - 1].meters) / dt)
        }
        return RepVelocity(mean: mean, peak: peak)
    }
}
