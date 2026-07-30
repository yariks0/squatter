import AVFoundation
import UIKit

/// One image bound for the coach: which rep and phase it shows, when it was
/// actually extracted, and the tracked-skeleton metadata that lets the model
/// name joints in it. Overlay renditions carry the skeleton drawn on the
/// pixels so the model can verify tracking against the footage.
struct CoachKeyframe: Sendable {
    var repNumber: Int
    var phase: KeyframePlanner.Phase
    /// The generator's actual extraction time (movie timeline) — not the
    /// requested time; the skeleton metadata is looked up at this instant.
    var time: TimeInterval
    var pixelSize: CGSize
    var isOverlay: Bool
    /// Key tracked joints in this image, top-left-origin pixels.
    var jointPixels: [(joint: BodyJoint, point: CGPoint)]
    /// Joints whose position is a hint, not a detection, and why.
    var uncertainJoints: [(joint: BodyJoint, reason: String)]
    var jpegData: Data
}

/// Extracts the frames `KeyframePlanner` chose, compositing the tracked
/// skeleton onto overlay renditions with the same drawing rules as the
/// playback overlay.
enum KeyframeExtractor {
    static func keyframes(
        for analysis: SquatAnalysis,
        videoURL: URL,
        maxDimension: CGFloat = 1024,
        compressionQuality: CGFloat = 0.7
    ) async throws -> [CoachKeyframe] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let keyJoints = Self.keyJoints(for: analysis.kind)
        var keyframes: [CoachKeyframe] = []

        for planned in KeyframePlanner.plan(analysis: analysis) {
            let requested = CMTime(seconds: planned.time, preferredTimescale: 600)
            guard let result = try? await generator.image(at: requested) else { continue }
            let cgImage = result.image
            // The generator lands within ±0.1 s of the request; the skeleton
            // must match the pixels it actually returned, not the ones asked
            // for, or the overlay desyncs from the frame.
            let actualTime = result.actualTime.seconds
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            let jointFrame = analysis.series.nearestFrame(to: actualTime)

            var jointPixels: [(joint: BodyJoint, point: CGPoint)] = []
            var uncertainJoints: [(joint: BodyJoint, reason: String)] = []
            if let jointFrame {
                for joint in keyJoints {
                    guard let p = jointFrame.imagePoints[joint] else { continue }
                    jointPixels.append((joint: joint, point: CGPoint(
                        x: (CGFloat(p.x) * size.width).rounded(),
                        y: ((1 - CGFloat(p.y)) * size.height).rounded()
                    )))
                    if jointFrame.isUncertain(joint) {
                        let repaired = jointFrame.repairedJoints?.contains(joint) == true
                        uncertainJoints.append((
                            joint: joint,
                            reason: repaired
                                ? "position repaired, not detected"
                                : "low detection confidence"
                        ))
                    }
                }
            }

            func append(_ image: UIImage, isOverlay: Bool) {
                guard let jpeg = image.jpegData(compressionQuality: compressionQuality) else { return }
                keyframes.append(CoachKeyframe(
                    repNumber: planned.repNumber,
                    phase: planned.phase,
                    time: actualTime,
                    pixelSize: size,
                    isOverlay: isOverlay,
                    jointPixels: jointPixels,
                    uncertainJoints: uncertainJoints,
                    jpegData: jpeg
                ))
            }

            // A frame with no tracked skeleton nearby can't carry an overlay;
            // fall back to the raw pixels rather than dropping the moment.
            let wantsOverlay = planned.images != .raw && jointFrame != nil
            if planned.images != .overlay || jointFrame == nil {
                append(UIImage(cgImage: cgImage), isOverlay: false)
            }
            if wantsOverlay, let jointFrame {
                let faults = FormFaultDetector.faults(
                    in: jointFrame, at: jointFrame.time,
                    reps: analysis.reps, activity: analysis.kind
                )
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let composited = UIGraphicsImageRenderer(size: size, format: format)
                    .image { context in
                        UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
                        SkeletonRenderer.draw(
                            frame: jointFrame, faults: faults,
                            in: context.cgContext, size: size
                        )
                    }
                append(composited, isOverlay: true)
            }
        }
        return keyframes
    }

    /// The joints worth naming next to an image — enough for the model to
    /// cross-check the skeleton without all 17 joints of token noise.
    static func keyJoints(for activity: ActivityType) -> [BodyJoint] {
        switch activity {
        case .squat:
            [.centerShoulder, .spine, .root, .leftHip, .rightHip,
             .leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
        case .benchPress:
            [.centerHead, .centerShoulder, .leftShoulder, .rightShoulder,
             .leftElbow, .rightElbow, .leftWrist, .rightWrist]
        case .deadlift:
            [.centerShoulder, .spine, .root, .leftHip, .rightHip,
             .leftKnee, .rightKnee, .leftAnkle, .rightAnkle, .leftWrist, .rightWrist]
        }
    }
}
