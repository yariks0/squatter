import Foundation
import simd

struct Rep: Codable, Sendable, Equatable {
    var startIndex: Int
    var bottomIndex: Int
    var endIndex: Int
    var startTime: TimeInterval
    var bottomTime: TimeInterval
    var endTime: TimeInterval
}

/// Splits a joint series into reps.
///
/// Vision's model space is root-anchored (the pelvis is the origin of every
/// frame), so absolute positions are not observable — every signal is a
/// distance between tracked joints that contracts as the lifter descends:
/// squat = hip height above the ankle midpoint (standing ≈ leg length,
/// bottom ≈ half of it); bench = wrist-to-shoulder midpoint distance
/// (lockout ≈ arm length, bar at the chest ≈ near zero). The bench signal
/// must be a distance, not an axis projection: model space is not
/// world-aligned for a lying body (verified on real footage 2026-07-08,
/// where the Y projection collapsed to noise), and distances are invariant
/// to the model-space orientation.
enum RepSegmenter {
    static func segment(_ series: JointSeries, activity: ActivityType = .squat) -> [Rep] {
        let signal = liftSignal(series, activity: activity)
        guard signal.count > 4 else { return [] }

        let baseline = standingBaseline(of: signal)
        guard baseline > 0 else { return [] }

        let entry: Double
        let exit: Double
        let standing: Double
        let minimumDepth: Double
        let maximumDuration: TimeInterval
        switch activity {
        case .squat:
            // The hip-above-ankle signal spans standing → near zero, so
            // thresholds are fractions of the standing baseline.
            entry = baseline * AnalysisTuning.descentEntryFraction
            exit = baseline * AnalysisTuning.ascentExitFraction
            standing = baseline * AnalysisTuning.standingFraction
            minimumDepth = baseline * AnalysisTuning.minimumRepDepthFraction
            maximumDuration = .infinity
        case .benchPress:
            // The wrist–shoulder distance only spans lockout → chest touch
            // (~60–100% of arm length on a clean skeleton), so thresholds
            // are normalized to the observed press range instead.
            let floor = touchFloor(of: signal)
            let range = baseline - floor
            guard range >= baseline * AnalysisTuning.benchMinimumRangeFraction else { return [] }
            entry = floor + range * AnalysisTuning.benchEntryRangeFraction
            exit = floor + range * AnalysisTuning.benchExitRangeFraction
            standing = floor + range * AnalysisTuning.benchStandingRangeFraction
            // Crossing the entry threshold already proves press depth.
            minimumDepth = 0
            maximumDuration = AnalysisTuning.benchMaximumRepDuration
        }
        let frames = series.frames

        var reps: [Rep] = []
        var index = 0
        var searchStart = 0
        while index < signal.count {
            guard signal[index] < entry else {
                index += 1
                continue
            }
            // Walk back to the last frame where the lifter was still standing;
            // stopping at the first local bump would swallow the rest pause
            // into the eccentric time.
            var start = index
            while start > searchStart, signal[start] < standing {
                start -= 1
            }
            // Find the bottom and the exit crossing.
            var bottom = index
            var end = index
            while end < signal.count - 1, signal[end] < exit {
                end += 1
                if signal[end] < signal[bottom] { bottom = end }
            }
            // Walk forward to the first frame back at standing height.
            while end < signal.count - 1, signal[end] < standing {
                end += 1
            }

            let depth = baseline - signal[bottom]
            let duration = frames[end].time - frames[start].time
            if depth >= minimumDepth,
               duration >= AnalysisTuning.minimumRepDuration,
               duration <= maximumDuration {
                reps.append(Rep(
                    startIndex: start,
                    bottomIndex: bottom,
                    endIndex: end,
                    startTime: frames[start].time,
                    bottomTime: frames[bottom].time,
                    endTime: frames[end].time
                ))
            }
            searchStart = end
            index = end + 1
        }
        return reps
    }

    /// Standing height baseline: 90th percentile of the signal, robust to
    /// both the descent phases and occasional tracking spikes.
    static func standingBaseline(of signal: [Double]) -> Double {
        percentile(of: signal, 0.9)
    }

    /// Touch floor for range-normalized signals (bench): 10th percentile ≈
    /// the bar at the chest, robust to compressed-skeleton noise below it.
    static func touchFloor(of signal: [Double]) -> Double {
        percentile(of: signal, 0.1)
    }

    private static func percentile(of signal: [Double], _ fraction: Double) -> Double {
        guard !signal.isEmpty else { return 0 }
        let sorted = signal.sorted()
        return sorted[min(signal.count - 1, Int(Double(signal.count) * fraction))]
    }

    /// The contracting rep signal for an activity.
    static func liftSignal(_ series: JointSeries, activity: ActivityType) -> [Double] {
        switch activity {
        case .squat: hipAboveAnkleSignal(series)
        case .benchPress: wristShoulderDistanceSignal(series)
        }
    }

    /// Wrist-midpoint to shoulder-midpoint distance per frame — the bar
    /// height signal for a lifter lying on a bench (lockout ≈ arm length,
    /// bar at the chest ≈ near zero). Falls back to the previous value when
    /// wrists are not tracked.
    static func wristShoulderDistanceSignal(_ series: JointSeries) -> [Double] {
        var signal: [Double] = []
        signal.reserveCapacity(series.frames.count)
        var last = 0.0
        for frame in series.frames {
            let wrists = [frame.position(.leftWrist), frame.position(.rightWrist)]
                .compactMap { $0 }
            let shoulders = [frame.position(.leftShoulder), frame.position(.rightShoulder)]
                .compactMap { $0 }
            if !wrists.isEmpty, !shoulders.isEmpty {
                let wristMid = wrists.reduce(SIMD3<Float>.zero, +) / Float(wrists.count)
                let shoulderMid = shoulders.reduce(SIMD3<Float>.zero, +) / Float(shoulders.count)
                last = Double(simd_length(wristMid - shoulderMid))
            }
            signal.append(last)
        }
        return signal
    }

    /// Hip height above the ankle midpoint per frame; falls back to the
    /// previous value when ankles are not tracked.
    static func hipAboveAnkleSignal(_ series: JointSeries) -> [Double] {
        var signal: [Double] = []
        signal.reserveCapacity(series.frames.count)
        var last = 0.0
        for frame in series.frames {
            let root = frame.position(.root) ?? .zero
            let ankles = [frame.position(.leftAnkle), frame.position(.rightAnkle)]
                .compactMap { $0 }
            if !ankles.isEmpty {
                let mid = ankles.reduce(SIMD3<Float>.zero, +) / Float(ankles.count)
                last = Double(root.y - mid.y)
            }
            signal.append(last)
        }
        return signal
    }
}
