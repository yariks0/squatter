import CoreVideo
import Vision

/// Lightweight live check that the whole body is in frame before/while
/// recording, using 2D pose on a subset of camera frames. The heavy 3D
/// analysis happens offline after the set.
final class FramingChecker: @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case noBody
        case partiallyVisible
        case fullBodyVisible

        var message: String {
            switch self {
            case .noBody: "Step back until your whole body is visible"
            case .partiallyVisible: "Move the phone so your whole body fits"
            case .fullBodyVisible: "Framing looks good"
            }
        }
    }

    /// Joints that must all be confidently inside the frame.
    private static let requiredJoints: [VNHumanBodyPoseObservation.JointName] = [
        .nose, .leftShoulder, .rightShoulder, .leftHip, .rightHip,
        .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
    ]
    private static let confidenceThreshold: VNConfidence = 0.3
    private static let edgeMargin: CGFloat = 0.02

    private let queue = DispatchQueue(label: "com.yarik.squatter.framing", qos: .utility)
    private let onStatus: @Sendable (Status) -> Void
    private var busy = false
    private var frameCounter = 0

    init(onStatus: @escaping @Sendable (Status) -> Void) {
        self.onStatus = onStatus
    }

    /// Call with every camera frame; processes roughly every 10th and skips
    /// while a request is in flight.
    func submit(_ pixelBuffer: CVPixelBuffer) {
        frameCounter += 1
        guard frameCounter % 10 == 0, !busy else { return }
        busy = true
        queue.async { [self] in
            let status = Self.evaluate(pixelBuffer)
            onStatus(status)
            busy = false
        }
    }

    private static func evaluate(_ pixelBuffer: CVPixelBuffer) -> Status {
        let request = VNDetectHumanBodyPoseRequest()
        // Buffers arrive already rotated to portrait (videoRotationAngle = 90).
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first
        else { return .noBody }

        guard let joints = try? observation.recognizedPoints(.all) else { return .noBody }
        var visible = 0
        for name in requiredJoints {
            guard let point = joints[name],
                  point.confidence >= confidenceThreshold,
                  point.location.x > edgeMargin, point.location.x < 1 - edgeMargin,
                  point.location.y > edgeMargin, point.location.y < 1 - edgeMargin
            else { continue }
            visible += 1
        }
        switch visible {
        case requiredJoints.count: return .fullBodyVisible
        case 0 ... 2: return .noBody
        default: return .partiallyVisible
        }
    }
}
