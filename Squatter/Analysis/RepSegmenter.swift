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
        let minimumDepthFraction = switch activity {
        case .squat: AnalysisTuning.minimumRepDepthFraction
        case .benchPress: AnalysisTuning.benchMinimumRepDepthFraction
        }
        guard signal.count > 4 else { return [] }

        let baseline = standingBaseline(of: signal)
        guard baseline > 0 else { return [] }

        let (entryFraction, exitFraction, standingFraction) = switch activity {
        case .squat: (
            AnalysisTuning.descentEntryFraction,
            AnalysisTuning.ascentExitFraction,
            AnalysisTuning.standingFraction
        )
        case .benchPress: (
            AnalysisTuning.benchDescentEntryFraction,
            AnalysisTuning.benchAscentExitFraction,
            AnalysisTuning.benchStandingFraction
        )
        }
        let entry = baseline * entryFraction
        let exit = baseline * exitFraction
        let standing = baseline * standingFraction
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
            if depth >= baseline * minimumDepthFraction,
               duration >= AnalysisTuning.minimumRepDuration {
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
        guard !signal.isEmpty else { return 0 }
        let sorted = signal.sorted()
        return sorted[min(signal.count - 1, Int(Double(signal.count) * 0.9))]
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
