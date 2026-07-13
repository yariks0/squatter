import Testing
import simd
@testable import Squatter

/// The measurement-precision upgrades: Savitzky–Golay smoothing keeps the
/// extremes the metrics are read at, rep boundaries interpolate off the
/// frame grid, and the 30 fps bar track sharpens velocity.
struct PrecisionTests {
    @Test func smoothingPreservesCurvatureExactly() {
        // A quadratic passes an SG quadratic filter unchanged — the property
        // the old moving average lacked (it dragged every bottom toward
        // mid-rep values). Track a parabola with its vertex mid-series.
        let frames = (0 ..< 21).map { index -> JointFrame in
            let t = Double(index) / 15
            let y = Float(0.5 - 0.8 * (t - 0.667) * (t - 0.667))
            return JointFrame(
                time: t,
                positions: [.root: SIMD3(0, y, 0)],
                imagePoints: [:]
            )
        }
        let series = JointSeries(frames: frames, bodyHeight: nil, usedDepth: false)
        let smoothed = JointSeriesSmoother.smoothed(series)
        for index in 2 ..< frames.count - 2 {
            let original = frames[index].positions[.root]!.y
            let filtered = smoothed.frames[index].positions[.root]!.y
            #expect(abs(original - filtered) < 1e-4)
        }
    }

    @Test func repBoundariesInterpolateOffTheFrameGrid() {
        // Triangle hip-height signal with threshold crossings deliberately
        // between frames: standing 0.9 m for 1 s, down to 0.45 over 1 s,
        // back up, repeated. The standing threshold (97% of the 0.9
        // baseline) is crossed at t = descentStart + 0.06 exactly.
        var frames: [JointFrame] = []
        let dt = 1.0 / 15
        var time = 0.0
        func add(_ duration: Double, _ height: @escaping (Double) -> Double) {
            let steps = Int(duration / dt)
            for step in 0 ..< steps {
                let progress = Double(step) / Double(steps)
                frames.append(JointFrame(
                    time: time,
                    positions: [
                        .root: SIMD3(0, 0, 0),
                        .leftAnkle: SIMD3(-0.1, Float(-height(progress)), 0),
                        .rightAnkle: SIMD3(0.1, Float(-height(progress)), 0),
                    ],
                    imagePoints: [:]
                ))
                time += dt
            }
        }
        for _ in 0 ..< 3 {
            add(1.0) { _ in 0.9 }
            add(1.0) { 0.9 - 0.45 * $0 }
            add(1.0) { 0.45 + 0.45 * $0 }
        }
        add(1.0) { _ in 0.9 }

        // No smoothing: the timing claim is the segmenter's alone.
        let series = JointSeries(frames: frames, bodyHeight: nil, usedDepth: false)
        let reps = RepSegmenter.segment(series, activity: .squat)
        #expect(reps.count == 3)
        for (index, rep) in reps.enumerated() {
            let descentStart = 1.0 + Double(index) * 3.0
            // 0.9 → 0.873 (97% of baseline) at 0.45 m/s takes 60 ms.
            let expectedStart = descentStart + 0.06
            #expect(abs(rep.startTime - expectedStart) < 0.02)
            // The triangle's true bottom is one second into the descent.
            #expect(abs(rep.bottomTime - (descentStart + 1.0)) < dt)
        }
    }

    @Test func barTrackDrivesVelocityAtFullRate() {
        // Sparse 15 fps joint frames but a 30 fps bar track rising 0.1
        // image-heights/s at 3 m per image height → 0.30 m/s throughout.
        let frames = (0 ..< 10).map { index in
            JointFrame(time: Double(index) / 15, positions: [:], imagePoints: [:])
        }
        let track = (0 ..< 20).map { index -> BarSample in
            let t = Double(index) / 30
            return BarSample(time: t, y: 0.3 + 0.1 * t, scale: 3.0)
        }
        let series = JointSeries(
            frames: frames, bodyHeight: nil, usedDepth: true, barTrack: track
        )
        let rep = Rep(
            startIndex: 0, bottomIndex: 0, endIndex: 9,
            startTime: 0, bottomTime: 0, endTime: 19.0 / 30
        )
        let velocity = try! #require(
            VelocityCalculator.concentricVelocities(for: [rep], in: series)[0]
        )
        #expect(abs(velocity.mean - 0.30) < 0.001)
        #expect(abs(velocity.peak - 0.30) < 0.001)
    }

    @Test func barTrackSpikeDoesNotFakePeakVelocity() {
        // The 0.30 m/s ramp with one mislocked wrist sample: +0.15 image
        // heights for one frame reads as a multi-m/s instant without the
        // consumption-time despike.
        let frames = (0 ..< 10).map { index in
            JointFrame(time: Double(index) / 15, positions: [:], imagePoints: [:])
        }
        var track = (0 ..< 20).map { index -> BarSample in
            let t = Double(index) / 30
            return BarSample(time: t, y: 0.3 + 0.1 * t, scale: 3.0)
        }
        track[10].y += 0.15
        let series = JointSeries(
            frames: frames, bodyHeight: nil, usedDepth: true, barTrack: track
        )
        let rep = Rep(
            startIndex: 0, bottomIndex: 0, endIndex: 9,
            startTime: 0, bottomTime: 0, endTime: 19.0 / 30
        )
        let velocity = try! #require(
            VelocityCalculator.concentricVelocities(for: [rep], in: series)[0]
        )
        #expect(abs(velocity.mean - 0.30) < 0.001)
        #expect(abs(velocity.peak - 0.30) < 0.001)
    }

    @Test func barTrackScaleGlitchRejected() {
        // One sample's LiDAR scale doubles (depth hole hit the background) —
        // a direct velocity multiplier without the despike.
        let frames = (0 ..< 10).map { index in
            JointFrame(time: Double(index) / 15, positions: [:], imagePoints: [:])
        }
        var track = (0 ..< 20).map { index -> BarSample in
            let t = Double(index) / 30
            return BarSample(time: t, y: 0.3 + 0.1 * t, scale: 3.0)
        }
        track[10].scale = 6.0
        let series = JointSeries(
            frames: frames, bodyHeight: nil, usedDepth: true, barTrack: track
        )
        let rep = Rep(
            startIndex: 0, bottomIndex: 0, endIndex: 9,
            startTime: 0, bottomTime: 0, endTime: 19.0 / 30
        )
        let velocity = try! #require(
            VelocityCalculator.concentricVelocities(for: [rep], in: series)[0]
        )
        #expect(abs(velocity.mean - 0.30) < 0.001)
        #expect(abs(velocity.peak - 0.30) < 0.001)
    }

    @Test func barTrackHoldsScaleThroughGaps() {
        // Scale known only on the first sample (the 3D pass's frame); the
        // in-between 2D-only samples inherit it.
        let frames = [JointFrame(time: 0, positions: [:], imagePoints: [:])]
        let track = (0 ..< 12).map { index -> BarSample in
            let t = Double(index) / 30
            return BarSample(time: t, y: 0.3 + 0.2 * t, scale: index == 0 ? 2.0 : nil)
        }
        let series = JointSeries(
            frames: frames, bodyHeight: nil, usedDepth: true, barTrack: track
        )
        let rep = Rep(
            startIndex: 0, bottomIndex: 0, endIndex: 0,
            startTime: 0, bottomTime: 0, endTime: 11.0 / 30
        )
        let velocity = try! #require(
            VelocityCalculator.concentricVelocities(for: [rep], in: series)[0]
        )
        #expect(abs(velocity.mean - 0.40) < 0.001)
    }
}
