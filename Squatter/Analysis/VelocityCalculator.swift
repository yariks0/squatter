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

    /// Quadratic SG smoothing weights, centered 5-sample window — any
    /// second-order trajectory passes unchanged (same weights as
    /// `JointSeriesSmoother`).
    private static let sgSmooth: [Double] = [-3, 12, 17, 12, -3].map { $0 / 35 }

    /// Per-rep concentric velocities, index-aligned with `reps`.
    static func concentricVelocities(for reps: [Rep], in series: JointSeries) -> [RepVelocity?] {
        let cleaned = series.barTrack.map(cleanedTrack)
        return reps.map { rep in
            if let cleaned, let velocity = velocity(for: rep, track: cleaned) {
                return velocity
            }
            return velocity(for: rep, in: series)
        }
    }

    /// Hampel-despiked, lightly SG-smoothed copy of the bar track. The
    /// stored track stays raw — re-analysis is idempotent — and cleaning
    /// happens at consumption: a single mislocked wrist sample otherwise
    /// enters the SG derivative with weight 0.2/dt and fakes a ~2 m/s peak.
    /// Edge samples (first/last 2) are despiked but never smoothed — a
    /// shrunken edge window would bias the endpoints that mean velocity is
    /// measured between.
    private static func cleanedTrack(_ track: [BarSample]) -> [BarSample] {
        guard track.count >= 5 else { return track }
        var cleaned = track

        let rawY = track.map(\.y)
        var y = rawY
        for index in rawY.indices {
            if let estimate = spikeReplacement(
                at: index, in: rawY, floor: AnalysisTuning.barTrackSpikeFloor
            ) {
                y[index] = estimate
            }
        }
        for index in y.indices {
            if index >= 2, index < y.count - 2 {
                var value = 0.0
                for (offset, weight) in sgSmooth.enumerated() {
                    value += y[index - 2 + offset] * weight
                }
                cleaned[index].y = value
            } else {
                cleaned[index].y = y[index]
            }
        }

        // A scale glitch multiplies velocity directly; judge the non-nil
        // subsequence only, and only when there is enough of it (a lone
        // scale inherited across a 2D-only stretch must survive).
        let scaleIndices = track.indices.filter { track[$0].scale != nil }
        if scaleIndices.count >= 5 {
            let scales = scaleIndices.map { track[$0].scale! }
            let floor = median(of: scales) * AnalysisTuning.barTrackScaleSpikeFloorFraction
            for (position, index) in scaleIndices.enumerated() {
                if let estimate = spikeReplacement(at: position, in: scales, floor: floor) {
                    cleaned[index].scale = estimate
                }
            }
        }
        return cleaned
    }

    /// Detrended Hampel judgment for one sample: the window's median
    /// consecutive slope is removed first (real bar motion is trend and must
    /// not inflate the MAD), then deviations beyond sigmas × max(MAD, floor)
    /// flag a spike. Returns the window's estimate of the sample, nil when
    /// it looks like real motion. Scalar twin of `JointTrackRepair`'s
    /// judgment.
    private static func spikeReplacement(
        at index: Int, in track: [Double], floor: Double
    ) -> Double? {
        let half = 2
        let lower = max(0, index - half)
        let upper = min(track.count - 1, index + half)
        guard upper - lower + 1 >= 4 else { return nil }
        let values = Array(track[lower ... upper])
        let slopes = zip(values, values.dropFirst()).map { $1 - $0 }
        let slope = median(of: slopes)
        let detrended = values.enumerated().map { $1 - slope * Double(lower + $0 - index) }
        let center = median(of: detrended)
        let mad = median(of: detrended.map { abs($0 - center) })
        guard abs(track[index] - center)
            > AnalysisTuning.barTrackSpikeSigmas * max(mad, floor) else { return nil }
        return center
    }

    private static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]
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
