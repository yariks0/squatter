import Foundation
import SwiftData

/// A saved set: pointers to the video (and optional depth sidecar) plus the
/// full analysis encoded as JSON, so reports re-render without re-extracting
/// pose and can be re-scored after threshold tuning.
@Model
final class WorkoutSession {
    var date: Date
    var videoFileName: String
    var depthFileName: String?
    var score: Int
    var repCount: Int
    var usedLiDAR: Bool
    var analysisData: Data
    /// Raw ActivityType; defaulted so pre-bench sessions migrate as squats.
    var activityRaw: String = ActivityType.squat.rawValue

    var activity: ActivityType { ActivityType(rawValue: activityRaw) ?? .squat }

    init(date: Date, recording: RecordingResult, analysis: SquatAnalysis) throws {
        self.date = date
        self.videoFileName = recording.videoURL.lastPathComponent
        self.depthFileName = recording.depthSidecarURL?.lastPathComponent
        self.score = analysis.score
        self.repCount = analysis.reps.count
        self.usedLiDAR = analysis.usedDepth
        self.analysisData = try JSONEncoder().encode(analysis)
        self.activityRaw = analysis.kind.rawValue
    }

    var videoURL: URL? {
        try? FileLocations.recordingsDirectory().appendingPathComponent(videoFileName)
    }

    func analysis() -> SquatAnalysis? {
        try? JSONDecoder().decode(SquatAnalysis.self, from: analysisData)
    }

    /// Removes the recording files backing this session.
    func deleteFiles() {
        guard let directory = try? FileLocations.recordingsDirectory() else { return }
        let videoURL = directory.appendingPathComponent(videoFileName)
        try? FileManager.default.removeItem(at: videoURL)
        CoachReportStore.delete(for: videoURL)
        if let depthFileName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(depthFileName))
        }
    }
}
