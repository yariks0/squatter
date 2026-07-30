import CoreGraphics
import Foundation
import Testing
@testable import Squatter

struct SkeletonRendererTests {
    /// A left-leg frame: hip → knee → ankle, tracked in image space.
    private func legFrame(repaired: Set<BodyJoint>? = nil) -> JointFrame {
        JointFrame(
            time: 0,
            positions: [:],
            imagePoints: [
                .leftHip: SIMD2(0.4, 0.6),
                .leftKnee: SIMD2(0.42, 0.4),
                .leftAnkle: SIMD2(0.42, 0.2),
            ],
            metersPerImageHeight: nil,
            jointConfidences: nil,
            repairedJoints: repaired
        )
    }

    /// Vision image points are normalized bottom-left; output pixels are
    /// top-left. y must flip, x must scale.
    @Test func coordinatesFlipToTopLeftOrigin() {
        let segments = SkeletonRenderer.segments(
            frame: legFrame(), faults: .none, size: CGSize(width: 100, height: 200)
        )
        let hip = segments.joints.first {
            $0.point == CGPoint(x: 40, y: 80) // x=0.4×100, y=(1−0.6)×200
        }
        #expect(hip != nil)
    }

    @Test func faultedLegDrawsFault() {
        var faults = FrameFaults()
        faults.leftLeg = true
        let segments = SkeletonRenderer.segments(
            frame: legFrame(), faults: faults, size: CGSize(width: 100, height: 100)
        )
        #expect(!segments.bones.isEmpty)
        #expect(segments.bones.allSatisfy { $0.state == .fault })
    }

    /// A repaired joint may never assert a fault: its bones dim to uncertain
    /// even while the leg is flagged.
    @Test func uncertainBeatsFault() {
        var faults = FrameFaults()
        faults.leftLeg = true
        let segments = SkeletonRenderer.segments(
            frame: legFrame(repaired: [.leftKnee]), faults: faults,
            size: CGSize(width: 100, height: 100)
        )
        // Both drawn bones touch the repaired knee.
        #expect(!segments.bones.isEmpty)
        #expect(segments.bones.allSatisfy { $0.state == .uncertain })
        let knee = segments.joints.first { $0.point.x == 42 && $0.point.y == 60 }
        #expect(knee?.state == .uncertain)
    }

    /// Compositing smoke test: drawing into a blank bitmap actually puts
    /// skeleton pixels down.
    @Test func drawPutsPixelsInTheContext() throws {
        let size = CGSize(width: 100, height: 100)
        let context = try #require(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        SkeletonRenderer.draw(frame: legFrame(), faults: .none, in: context, size: size)
        let data = try #require(context.data)
        let buffer = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * 100)
        let anyInk = (0 ..< context.bytesPerRow * 100).contains { buffer[$0] != 0 }
        #expect(anyInk)
    }
}
