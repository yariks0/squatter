import Foundation
import Testing
import simd
@testable import Squatter

struct TrackRepairTests {
    /// The guarantee the removed bone-length pass failed: clean footage
    /// passes through repair bit-identical, with nothing flagged.
    @Test func cleanMotionSurvivesRepairUntouched() {
        let series = SyntheticSquat(repCount: 2, metersPerImageHeight: 2.2).series()
        let repaired = JointTrackRepair.repaired(series)
        for (original, result) in zip(series.frames, repaired.frames) {
            #expect(result.repairedJoints == nil)
            #expect(result.positions == original.positions)
            #expect(result.imagePoints == original.imagePoints)
        }
    }

    @Test func spikeReplacedWithLocalMedian() {
        var series = SyntheticSquat(repCount: 1).series()
        let spiked = midDescentIndex(of: series)
        let clean = series.frames[spiked].positions[.leftKnee]!
        series.frames[spiked].positions[.leftKnee]! += SIMD3(0.4, 0, 0)

        let repaired = JointTrackRepair.repaired(series)
        let value = repaired.frames[spiked].positions[.leftKnee]!
        #expect(simd_distance(value, clean) < 0.02)
        #expect(repaired.frames[spiked].repairedJoints == [.leftKnee])
        // Neighbors see the spike in their windows but stay untouched.
        #expect(repaired.frames[spiked - 1].repairedJoints == nil)
        #expect(repaired.frames[spiked + 1].repairedJoints == nil)
    }

    @Test func imagePointSpikeRepaired() {
        var series = SyntheticSquat(repCount: 1, metersPerImageHeight: 2.2).series()
        let spiked = midDescentIndex(of: series)
        let clean = series.frames[spiked].imagePoints[.leftHip]!
        series.frames[spiked].imagePoints[.leftHip]! += SIMD2(0, 0.2)

        let repaired = JointTrackRepair.repaired(series)
        let value = repaired.frames[spiked].imagePoints[.leftHip]!
        #expect(simd_distance(value, clean) < 0.02)
        #expect(repaired.frames[spiked].repairedJoints == [.leftHip])
    }

    @Test func shortDropoutBridged() {
        var series = SyntheticSquat(repCount: 1).series()
        let gapStart = midDescentIndex(of: series)
        let clean = (gapStart ... gapStart + 1).map { series.frames[$0].positions[.leftKnee]! }
        for index in gapStart ... gapStart + 1 {
            series.frames[index].positions.removeValue(forKey: .leftKnee)
        }

        let repaired = JointTrackRepair.repaired(series)
        for (offset, index) in (gapStart ... gapStart + 1).enumerated() {
            let bridged = repaired.frames[index].positions[.leftKnee]
            #expect(bridged != nil)
            if let bridged {
                #expect(simd_distance(bridged, clean[offset]) < 0.02)
            }
            #expect(repaired.frames[index].repairedJoints == [.leftKnee])
        }
    }

    @Test func longDropoutStaysMissing() {
        var series = SyntheticSquat(repCount: 1).series()
        let gapStart = midDescentIndex(of: series)
        for index in gapStart ..< gapStart + 5 {
            series.frames[index].positions.removeValue(forKey: .leftKnee)
        }

        let repaired = JointTrackRepair.repaired(series)
        for index in gapStart ..< gapStart + 5 {
            #expect(repaired.frames[index].positions[.leftKnee] == nil)
            #expect(repaired.frames[index].repairedJoints == nil)
        }
    }

    /// A fault may not be asserted from repaired joints: knee valgus present
    /// only in repair-flagged frames must read as zero (seen on a real
    /// session, where despiking made a broken stretch's degenerate frames
    /// pass the valgus sanity guards).
    @Test func repairedFramesCannotAssertValgus() {
        let generator = SyntheticSquat(repCount: 1, valgusShift: 0.09)
        var series = generator.series()
        for index in series.frames.indices {
            series.frames[index].repairedJoints = [.leftKnee, .rightKnee]
        }
        let reps = RepSegmenter.segment(series, activity: .squat)
        let flagged = MetricsCalculator.metrics(for: reps, in: series, activity: .squat)
        let unflagged = MetricsCalculator.metrics(
            for: reps, in: generator.series(), activity: .squat
        )
        #expect(unflagged.allSatisfy { $0.kneeValgusRatio > 0 })
        #expect(flagged.allSatisfy { $0.kneeValgusRatio == 0 })
    }

    @Test func uncertainJointPredicateHonorsConfidenceAndRepairFlags() {
        var frame = JointFrame(time: 0, positions: [:], imagePoints: [:])
        // No confidence data at all (pre-upgrade session): everything certain.
        #expect(!frame.isUncertain(.leftKnee))

        frame.jointConfidences = [.leftKnee: 0.9, .rightKnee: 0.31]
        #expect(!frame.isUncertain(.leftKnee))
        // Above the extraction gate but below the overlay floor.
        #expect(frame.isUncertain(.rightKnee))
        // Present in a confidence-carrying frame without an entry = the
        // drifting 3D re-projection.
        #expect(frame.isUncertain(.leftHip))

        // Repair flags dim regardless of confidence.
        frame.repairedJoints = [.leftKnee]
        #expect(frame.isUncertain(.leftKnee))
    }

    /// A frame index safely inside the first rep's descent, away from both
    /// the series edges and the bottom turnaround.
    private func midDescentIndex(of series: JointSeries) -> Int {
        let generator = SyntheticSquat(repCount: 1)
        let target = generator.pauseSeconds + generator.eccentricSeconds / 2
        return series.frames.indices.min {
            abs(series.frames[$0].time - target) < abs(series.frames[$1].time - target)
        }!
    }
}
