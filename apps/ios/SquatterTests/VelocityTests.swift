import Foundation
import Testing
import simd
@testable import Squatter

struct VelocityCalculatorTests {
    /// 15 fps frames whose wrist midpoint rises at a constant normalized
    /// rate under a fixed metric scale.
    private static func series(
        riseNormPerSecond: Double, metersPerImageHeight: Float?, frameCount: Int = 20
    ) -> JointSeries {
        let frames = (0 ..< frameCount).map { index -> JointFrame in
            let time = Double(index) / 15
            let y = Float(0.3 + riseNormPerSecond * time)
            return JointFrame(
                time: time,
                positions: [:],
                imagePoints: [.leftWrist: SIMD2(0.4, y), .rightWrist: SIMD2(0.6, y)],
                metersPerImageHeight: metersPerImageHeight
            )
        }
        return JointSeries(frames: frames, bodyHeight: 1.8, usedDepth: true)
    }

    private static func rep(frameCount: Int = 20) -> Rep {
        Rep(
            startIndex: 0, bottomIndex: 0, endIndex: frameCount - 1,
            startTime: 0, bottomTime: 0, endTime: Double(frameCount - 1) / 15
        )
    }

    @Test func measuresConstantVelocityExactly() {
        // 0.1 image-heights/s at 3 m per image height = 0.30 m/s.
        let series = Self.series(riseNormPerSecond: 0.1, metersPerImageHeight: 3.0)
        let velocities = VelocityCalculator.concentricVelocities(for: [Self.rep()], in: series)
        let velocity = try! #require(velocities[0])
        #expect(abs(velocity.mean - 0.30) < 0.005)
        #expect(abs(velocity.peak - 0.30) < 0.01)
    }

    @Test func missingScaleYieldsNoVelocity() {
        let series = Self.series(riseNormPerSecond: 0.1, metersPerImageHeight: nil)
        let velocities = VelocityCalculator.concentricVelocities(for: [Self.rep()], in: series)
        #expect(velocities[0] == nil)
    }

    @Test func descendingWristYieldsNoVelocity() {
        let series = Self.series(riseNormPerSecond: -0.1, metersPerImageHeight: 3.0)
        let velocities = VelocityCalculator.concentricVelocities(for: [Self.rep()], in: series)
        #expect(velocities[0] == nil)
    }

    @Test func oldSeriesJSONStillDecodes() throws {
        // A frame encoded before metersPerImageHeight existed.
        let legacy = JointFrame(time: 1, positions: [.root: SIMD3(0, 0, 0)], imagePoints: [:])
        var encoded = try JSONEncoder().encode(legacy)
        // Round-trip through a dictionary to drop the new key entirely.
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "metersPerImageHeight")
        encoded = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(JointFrame.self, from: encoded)
        #expect(decoded.metersPerImageHeight == nil)
    }
}

struct LoadVelocityProfileTests {
    @Test func fitsExactLineAndEstimatesOneRepMax() {
        let profile = try! #require(LoadVelocityProfile.fit(points: [
            (loadKg: 60, velocity: 0.8), (loadKg: 80, velocity: 0.6), (loadKg: 100, velocity: 0.4),
        ]))
        #expect(abs(profile.slope - -0.01) < 1e-9)
        #expect(abs(profile.intercept - 1.4) < 1e-9)
        // 0.30 m/s minimal velocity → 110 kg.
        #expect(abs(profile.estimatedOneRepMax(atMinimalVelocity: 0.3) - 110) < 1e-6)
    }

    @Test func keepsBestVelocityPerLoad() {
        // Two sessions at 80 kg: the fresher, faster one defines the load.
        let profile = try! #require(LoadVelocityProfile.fit(points: [
            (60, 0.8), (80, 0.5), (80, 0.6), (100, 0.4),
        ]))
        #expect(abs(profile.predictedVelocity(atLoad: 80) - 0.6) < 0.01)
    }

    @Test func needsThreeDistinctLoadsWithSpread() {
        #expect(LoadVelocityProfile.fit(points: [(60, 0.8), (80, 0.6)]) == nil)
        // Three loads bucketed within 5 kg collapse to too few points.
        #expect(LoadVelocityProfile.fit(points: [(60, 0.8), (61, 0.75), (62, 0.7)]) == nil)
        // An uphill "profile" is noise, not physiology.
        #expect(LoadVelocityProfile.fit(points: [(60, 0.4), (80, 0.6), (100, 0.8)]) == nil)
    }
}
