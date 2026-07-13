import CoreVideo
import QuartzCore
import Vision

/// Lightweight live check that the whole body is in frame before/while
/// recording, using 2D pose on a subset of camera frames, plus the pose
/// samples that drive the live rep counter. The heavy 3D analysis happens
/// offline after the set.
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

    /// Joints that must all be confidently inside the frame. A bench lifter
    /// lies down, so knees/ankles (which the bench itself often occludes)
    /// are dropped — but the head is required: the 2026-07-08 recording
    /// passed the old head-less check with the head out of frame the whole
    /// set, and the analysis was garbage.
    private static func joints(
        for activity: ActivityType
    ) -> [VNHumanBodyPoseObservation.JointName] {
        switch activity {
        case .squat:
            [.nose, .leftShoulder, .rightShoulder, .leftHip, .rightHip,
             .leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
        case .benchPress:
            [.nose, .leftShoulder, .rightShoulder, .leftElbow, .rightElbow,
             .leftWrist, .rightWrist, .leftHip, .rightHip]
        case .deadlift:
            // Full body plus the wrists: the bar-in-hands is the signal.
            [.nose, .leftShoulder, .rightShoulder, .leftWrist, .rightWrist,
             .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
        }
    }
    private static let confidenceThreshold: VNConfidence = 0.3
    private static let edgeMargin: CGFloat = 0.02

    private let queue = DispatchQueue(label: "com.yarik.squatter.framing", qos: .utility)
    private let onStatus: @Sendable (Status) -> Void
    private let onPose: (@Sendable (LivePoseSample) -> Void)?
    private let requiredJoints: [VNHumanBodyPoseObservation.JointName]
    private var busy = false
    private var frameCounter = 0

    init(
        activity: ActivityType = .squat,
        onStatus: @escaping @Sendable (Status) -> Void,
        onPose: (@Sendable (LivePoseSample) -> Void)? = nil
    ) {
        self.onStatus = onStatus
        self.onPose = onPose
        self.requiredJoints = Self.joints(for: activity)
    }

    /// Call with every camera frame; processes roughly every 3rd (~10 Hz at
    /// 30 fps capture — the cadence the rep counter needs) and skips while
    /// a request is in flight.
    func submit(_ pixelBuffer: CVPixelBuffer) {
        frameCounter += 1
        guard frameCounter % 3 == 0, !busy else { return }
        busy = true
        let time = CACurrentMediaTime()
        queue.async { [self] in
            let (status, sample) = Self.evaluate(pixelBuffer, at: time, requiredJoints: requiredJoints)
            onStatus(status)
            if let sample { onPose?(sample) }
            busy = false
        }
    }

    private static func evaluate(
        _ pixelBuffer: CVPixelBuffer,
        at time: TimeInterval,
        requiredJoints: [VNHumanBodyPoseObservation.JointName]
    ) -> (Status, LivePoseSample?) {
        let request = VNDetectHumanBodyPoseRequest()
        // Buffers arrive already rotated to portrait (videoRotationAngle = 90).
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              let joints = try? observation.recognizedPoints(.all)
        else { return (.noBody, nil) }

        var visible = 0
        for name in requiredJoints {
            guard let point = joints[name],
                  point.confidence >= confidenceThreshold,
                  point.location.x > edgeMargin, point.location.x < 1 - edgeMargin,
                  point.location.y > edgeMargin, point.location.y < 1 - edgeMargin
            else { continue }
            visible += 1
        }
        let status: Status = switch visible {
        case requiredJoints.count: .fullBodyVisible
        case 0 ... 2: .noBody
        default: .partiallyVisible
        }

        func confident(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let point = joints[name], point.confidence >= confidenceThreshold
            else { return nil }
            return point.location
        }
        func mid(
            _ a: VNHumanBodyPoseObservation.JointName,
            _ b: VNHumanBodyPoseObservation.JointName
        ) -> SIMD2<Double>? {
            let points = [confident(a), confident(b)].compactMap { $0 }
            guard !points.isEmpty else { return nil }
            let sum = points.reduce(SIMD2<Double>.zero) { $0 + SIMD2(Double($1.x), Double($1.y)) }
            return sum / Double(points.count)
        }
        let sample = LivePoseSample(
            time: time,
            hipMid: mid(.leftHip, .rightHip),
            kneeMid: mid(.leftKnee, .rightKnee),
            shoulderMid: mid(.leftShoulder, .rightShoulder),
            elbowMid: mid(.leftElbow, .rightElbow),
            wristMid: mid(.leftWrist, .rightWrist),
            noseY: confident(.nose).map { Double($0.y) },
            ankleMidY: mid(.leftAnkle, .rightAnkle)?.y
        )
        return (status, sample)
    }
}
