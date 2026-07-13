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
/// (lockout ≈ arm length, bar at the chest ≈ near zero); deadlift =
/// wrist-to-ankle midpoint distance (bar on the floor ≈ shin height,
/// lockout ≈ hip height). Signals must be distances, not axis projections:
/// model space is not world-aligned for a lying body (verified on real
/// footage 2026-07-08, where the Y projection collapsed to noise), and
/// distances are invariant to the model-space orientation.
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
        case .benchPress, .deadlift:
            // These signals only span part of their full anatomical range
            // (bench: lockout → chest touch; deadlift: lockout → bar at the
            // shins), so thresholds are normalized to the observed range.
            let floor = touchFloor(of: signal)
            let range = baseline - floor
            guard range >= baseline * AnalysisTuning.benchMinimumRangeFraction else { return [] }
            entry = floor + range * AnalysisTuning.benchEntryRangeFraction
            exit = floor + range * AnalysisTuning.benchExitRangeFraction
            standing = floor + range * AnalysisTuning.benchStandingRangeFraction
            // Crossing the entry threshold already proves depth.
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
            // Find the bottom and the exit crossing. A deadlift dwells on a
            // flat floor plateau, so its bottom is the *last* minimum (the
            // moment before the pull); the other lifts keep the first.
            var bottom = index
            var end = index
            while end < signal.count - 1, signal[end] < exit {
                end += 1
                if signal[end] < signal[bottom]
                    || (activity == .deadlift && signal[end] <= signal[bottom]) {
                    bottom = end
                }
            }
            // Walk forward to the first frame back at standing height.
            while end < signal.count - 1, signal[end] < standing {
                end += 1
            }

            let depth = baseline - signal[bottom]
            var repStart = start
            var duration = frames[end].time - frames[repStart].time
            var minimumDuration = AnalysisTuning.minimumRepDuration
            if activity == .deadlift {
                // A deadlift set starts with the bar already on the floor,
                // so the pre-lift setup would swallow the first pull via the
                // duration gate. Judge the window on its ascent and cap the
                // eccentric-plus-floor time folded into the rep.
                duration = frames[end].time - frames[bottom].time
                minimumDuration = AnalysisTuning.deadliftMinimumAscentSeconds
                while repStart < bottom,
                      frames[bottom].time - frames[repStart].time
                          > AnalysisTuning.deadliftMaxEccentricSeconds {
                    repStart += 1
                }
            }
            // A window whose end never rose back through the exit threshold
            // is a cut-off tail (recording stopped at the bottom, or the
            // series ends on the deadlift's final lowering), not a rep.
            if depth >= minimumDepth,
               signal[end] >= exit,
               duration >= minimumDuration,
               duration <= maximumDuration {
                // Sub-frame timing: boundary times snap to the analysis
                // frame grid (±33 ms at 15 fps) unless the exact threshold
                // crossings are interpolated; the bottom instant comes from
                // a parabola through the minimum. Tempo and velocity windows
                // inherit the precision. Indices stay on the grid.
                reps.append(Rep(
                    startIndex: repStart,
                    bottomIndex: bottom,
                    endIndex: end,
                    startTime: crossingTime(
                        signal: signal, frames: frames, from: repStart,
                        threshold: standing, descending: true
                    ),
                    bottomTime: parabolicMinimumTime(signal: signal, frames: frames, at: bottom),
                    endTime: crossingTime(
                        signal: signal, frames: frames, from: end,
                        threshold: standing, descending: false
                    )
                ))
            }
            searchStart = end
            index = end + 1
        }
        return reps
    }

    /// The instant the signal crossed `threshold` next to a boundary frame,
    /// linearly interpolated between that frame and its neighbor toward the
    /// rep. `descending` = the rep's start (signal about to fall through the
    /// threshold); otherwise its end (signal just rose through it). Falls
    /// back to the frame time when there is no clean crossing (a deadlift's
    /// first pull starts below every threshold).
    private static func crossingTime(
        signal: [Double], frames: [JointFrame], from index: Int,
        threshold: Double, descending: Bool
    ) -> TimeInterval {
        let neighbor = descending ? index + 1 : index - 1
        guard neighbor >= 0, neighbor < signal.count else { return frames[index].time }
        let outside = signal[index]
        let inside = signal[neighbor]
        guard outside >= threshold, inside < threshold, outside - inside > 1e-9 else {
            return frames[index].time
        }
        let fraction = (outside - threshold) / (outside - inside)
        let clamped = max(0, min(1, fraction))
        return frames[index].time + (frames[neighbor].time - frames[index].time) * clamped
    }

    /// The bottom instant from a parabola through the minimum and its
    /// neighbors; the frame time when the bottom is a flat plateau.
    private static func parabolicMinimumTime(
        signal: [Double], frames: [JointFrame], at index: Int
    ) -> TimeInterval {
        guard index > 0, index < signal.count - 1 else { return frames[index].time }
        let left = signal[index - 1]
        let center = signal[index]
        let right = signal[index + 1]
        let curvature = left - 2 * center + right
        guard curvature > 1e-9 else { return frames[index].time }
        // Vertex offset in frame units, bounded to the neighboring frames.
        let offset = max(-1, min(1, (left - right) / (2 * curvature)))
        let dt = (frames[index + 1].time - frames[index - 1].time) / 2
        return frames[index].time + offset * dt
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
        case .deadlift: wristAnkleDistanceSignal(series)
        }
    }

    /// Wrist-midpoint to ankle-midpoint distance per frame — bar height for
    /// a deadlift (bar on the floor ≈ shin height, lockout ≈ hip height).
    /// Falls back to the previous value when either end is untracked.
    static func wristAnkleDistanceSignal(_ series: JointSeries) -> [Double] {
        var signal: [Double] = []
        signal.reserveCapacity(series.frames.count)
        var last = 0.0
        for frame in series.frames {
            let wrists = [frame.position(.leftWrist), frame.position(.rightWrist)]
                .compactMap { $0 }
            let ankles = [frame.position(.leftAnkle), frame.position(.rightAnkle)]
                .compactMap { $0 }
            if !wrists.isEmpty, !ankles.isEmpty {
                let wristMid = wrists.reduce(SIMD3<Float>.zero, +) / Float(wrists.count)
                let ankleMid = ankles.reduce(SIMD3<Float>.zero, +) / Float(ankles.count)
                last = Double(simd_length(wristMid - ankleMid))
            }
            signal.append(last)
        }
        return signal
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
