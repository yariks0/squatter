import AVFoundation
import UIKit

/// Pulls the frames worth showing the LLM: the bottom of every rep, plus a
/// mid-ascent frame for reps where the knees drifted, downscaled and
/// JPEG-encoded for the Messages API.
enum KeyframeExtractor {
    static func keyframes(
        for analysis: SquatAnalysis,
        videoURL: URL,
        maxDimension: CGFloat = 1024,
        compressionQuality: CGFloat = 0.7
    ) async throws -> [CoachPrompt.Keyframe] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var keyframes: [CoachPrompt.Keyframe] = []
        func append(_ label: String, at seconds: TimeInterval) async throws {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            guard let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: compressionQuality)
            else { return }
            keyframes.append(CoachPrompt.Keyframe(label: label, jpegData: jpeg))
        }

        for rep in analysis.reps {
            try await append("Rep \(rep.repNumber) — bottom position", at: rep.startTime + rep.eccentricSeconds)
            if rep.kneeValgusRatio >= AnalysisTuning.valgusWarningRatio {
                let midAscent = rep.startTime + rep.eccentricSeconds + rep.concentricSeconds / 2
                try await append("Rep \(rep.repNumber) — mid-ascent (check knee tracking)", at: midAscent)
            }
        }
        return keyframes
    }
}
