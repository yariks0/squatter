import CoreGraphics
import Foundation

/// Classifies and draws the tracked skeleton for a single frame — shared by
/// the playback overlay (SwiftUI Canvas) and the coach keyframe compositor
/// (CGContext), so both render the same rules: a bone with a repaired or
/// low-confidence endpoint dims to a hint and never draws red — a fault may
/// not be asserted from an invented joint.
enum SkeletonRenderer {
    enum SegmentState {
        case ok, fault, uncertain
    }

    struct Segments {
        var bones: [(from: CGPoint, to: CGPoint, state: SegmentState)] = []
        var joints: [(point: CGPoint, state: SegmentState)] = []
    }

    /// Line widths and dot radius shared by both renderers.
    static let okLineWidth: CGFloat = 3
    static let faultLineWidth: CGFloat = 4
    static let uncertainLineWidth: CGFloat = 2
    static let jointDotRadius: CGFloat = 4

    /// The frame's skeleton scaled to `size`, in top-left-origin coordinates
    /// (Vision image points are normalized with origin bottom-left).
    static func segments(frame: JointFrame, faults: FrameFaults, size: CGSize) -> Segments {
        func point(_ joint: BodyJoint) -> CGPoint? {
            guard let p = frame.imagePoints[joint] else { return nil }
            return CGPoint(x: CGFloat(p.x) * size.width, y: (1 - CGFloat(p.y)) * size.height)
        }
        var segments = Segments()
        for bone in BodyJoint.bones {
            guard let pa = point(bone.0), let pb = point(bone.1) else { continue }
            let state: SegmentState = frame.isUncertain(bone.0) || frame.isUncertain(bone.1)
                ? .uncertain
                : BodyJoint.faulted(bone, by: faults) ? .fault : .ok
            segments.bones.append((from: pa, to: pb, state: state))
        }
        for joint in BodyJoint.allCases {
            guard let p = point(joint) else { continue }
            let state: SegmentState = frame.isUncertain(joint)
                ? .uncertain
                : joint.faulted(by: faults) ? .fault : .ok
            segments.joints.append((point: p, state: state))
        }
        return segments
    }

    /// Strokes the skeleton into a top-left-origin CGContext (the compositor
    /// path; the SwiftUI overlay builds Paths from `segments` instead).
    static func draw(frame: JointFrame, faults: FrameFaults, in context: CGContext, size: CGSize) {
        let segments = segments(frame: frame, faults: faults, size: size)
        let green = CGColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)
        let red = CGColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)

        func stroke(_ state: SegmentState, color: CGColor, alpha: CGFloat, width: CGFloat) {
            let bones = segments.bones.filter { $0.state == state }
            guard !bones.isEmpty else { return }
            context.setStrokeColor(color.copy(alpha: alpha) ?? color)
            context.setLineWidth(width)
            context.setLineCap(.round)
            for bone in bones {
                context.move(to: bone.from)
                context.addLine(to: bone.to)
            }
            context.strokePath()
        }
        stroke(.ok, color: green, alpha: 0.8, width: okLineWidth)
        stroke(.fault, color: red, alpha: 0.9, width: faultLineWidth)
        stroke(.uncertain, color: green, alpha: 0.25, width: uncertainLineWidth)

        for joint in segments.joints {
            let color: CGColor
            switch joint.state {
            case .uncertain: color = green.copy(alpha: 0.25) ?? green
            case .fault: color = red
            case .ok: color = green
            }
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(
                x: joint.point.x - jointDotRadius, y: joint.point.y - jointDotRadius,
                width: jointDotRadius * 2, height: jointDotRadius * 2
            ))
        }
    }
}
