import Foundation
import simd

/// Pre-smoothing track repair: Hampel spike replacement plus bridging of
/// short (≤ `repairMaxGapFrames`) joint dropouts, on `positions` and
/// `imagePoints` independently. Runs on the raw series so the SG smoother
/// never smears a spike across its window — and on a fork *after*
/// `TrackingQuality` is measured, because cleaning first would mask the very
/// flicker the gate catches (the same ordering rule as `SkeletonCorrector`).
/// Every touched joint is flagged in `JointFrame.repairedJoints` so
/// downstream consumers can tell measured from repaired. Bounded by design:
/// clean footage must pass through bit-identical (the lesson behind the
/// removed bone-length constraint pass — never invent structure).
enum JointTrackRepair {
    static func repaired(_ series: JointSeries) -> JointSeries {
        guard series.frames.count >= 3 else { return series }
        var result = series
        for joint in BodyJoint.allCases {
            repairTrack(
                joint, in: &result, floor: AnalysisTuning.repairSpikeFloorMeters,
                read: { $0.positions[joint] },
                write: { $0.positions[joint] = $1 }
            )
            repairTrack(
                joint, in: &result, floor: AnalysisTuning.repairSpikeFloorImage,
                read: { $0.imagePoints[joint] },
                write: { $0.imagePoints[joint] = $1 }
            )
        }
        return result
    }

    private static func repairTrack<Value: SIMD>(
        _ joint: BodyJoint, in series: inout JointSeries, floor: Float,
        read: (JointFrame) -> Value?, write: (inout JointFrame, Value) -> Void
    ) where Value.Scalar == Float {
        // The original samples stay the reference for every window judgment
        // (batch Hampel) — replacements land in `repaired` and the frames.
        let original = series.frames.map(read)
        var repaired = original

        for index in original.indices {
            guard let value = original[index],
                  let center = spikeReplacement(for: value, at: index, in: original, floor: floor)
            else { continue }
            repaired[index] = center
            write(&series.frames[index], center)
            flag(joint, at: index, in: &series)
        }

        bridgeGaps(joint, track: repaired, in: &series, write: write)
    }

    /// The window's robust estimate of the sample when it deviates like a
    /// detector spike; nil for samples that look like real motion. The window
    /// is detrended with a median slope first — mid-rep joints move several
    /// window-widths per second, and that trend would otherwise inflate the
    /// MAD until real spikes slip under the gate. After detrending, steady
    /// motion of any speed has near-zero deviation everywhere, and a
    /// rep-bottom turnaround deviates by about one near-zero-velocity frame
    /// of curvature — far under the gate.
    private static func spikeReplacement<Value: SIMD>(
        for value: Value, at index: Int, in track: [Value?], floor: Float
    ) -> Value? where Value.Scalar == Float {
        let window = AnalysisTuning.repairSpikeWindow
        let lower = max(0, index - window)
        let upper = min(track.count - 1, index + window)
        let samples: [(offset: Float, value: Value)] = (lower ... upper).compactMap {
            guard let sample = track[$0] else { return nil }
            return (Float($0 - index), sample)
        }
        // Too few tracked samples to establish what "normal" looks like.
        guard samples.count >= window + 2 else { return nil }

        var center = Value.zero
        var isSpike = false
        for component in 0 ..< Value.scalarCount {
            // Median of consecutive per-frame slopes: a spike corrupts two
            // slopes, real motion sets the rest, the median follows the rest.
            let slopes = zip(samples, samples.dropFirst()).map {
                ($1.value[component] - $0.value[component]) / ($1.offset - $0.offset)
            }
            let slope = median(ofSorted: slopes.sorted())
            let detrended = samples.map { $0.value[component] - slope * $0.offset }.sorted()
            let median = median(ofSorted: detrended)
            let mad = self.median(ofSorted: detrended.map { abs($0 - median) }.sorted())
            // The window's estimate of this sample: detrended median back on
            // the trend line (offset 0 at the judged sample).
            center[component] = median
            if abs(value[component] - median)
                > AnalysisTuning.repairSpikeSigmas * max(mad, floor) {
                isSpike = true
            }
        }
        return isSpike ? center : nil
    }

    /// Linear time interpolation across runs of ≤ `repairMaxGapFrames`
    /// missing frames with tracked (post-despike) samples on both sides.
    /// Longer gaps and gaps touching the series ends are real occlusion and
    /// stay missing.
    private static func bridgeGaps<Value: SIMD>(
        _ joint: BodyJoint, track: [Value?], in series: inout JointSeries,
        write: (inout JointFrame, Value) -> Void
    ) where Value.Scalar == Float {
        var index = 0
        while index < track.count {
            guard track[index] == nil else {
                index += 1
                continue
            }
            var gapEnd = index
            while gapEnd + 1 < track.count, track[gapEnd + 1] == nil { gapEnd += 1 }
            defer { index = gapEnd + 1 }

            guard gapEnd - index + 1 <= AnalysisTuning.repairMaxGapFrames,
                  index > 0, gapEnd < track.count - 1,
                  let before = track[index - 1], let after = track[gapEnd + 1]
            else { continue }
            let beforeTime = series.frames[index - 1].time
            let afterTime = series.frames[gapEnd + 1].time
            guard afterTime > beforeTime else { continue }

            for frame in index ... gapEnd {
                let fraction = Float(
                    (series.frames[frame].time - beforeTime) / (afterTime - beforeTime)
                )
                write(&series.frames[frame], before + (after - before) * fraction)
                flag(joint, at: frame, in: &series)
            }
        }
    }

    private static func flag(_ joint: BodyJoint, at index: Int, in series: inout JointSeries) {
        var flagged = series.frames[index].repairedJoints ?? []
        flagged.insert(joint)
        series.frames[index].repairedJoints = flagged
    }

    private static func median(ofSorted values: [Float]) -> Float {
        values.count.isMultiple(of: 2)
            ? (values[values.count / 2 - 1] + values[values.count / 2]) / 2
            : values[values.count / 2]
    }
}
