import Foundation
import SwiftData

/// A workout pulled from the backend that has no recording on this device
/// (recorded on another phone, or after a reinstall). Kept separate from
/// `WorkoutSession` on purpose: a `WorkoutSession` promises its
/// `analysisData` is ground truth for re-render and re-analysis, which a
/// summary can't honor. This carries only the portable slice — enough for
/// the progress dashboard and the 1RM/load–velocity estimate — while the
/// report screen stays unavailable for it.
@Model
final class RemoteWorkoutSummary {
    /// The recording UUID (the backend session id).
    @Attribute(.unique) var id: String
    var date: Date
    var activityRaw: String
    var score: Int
    var repCount: Int
    var usedLiDAR: Bool
    var weightKg: Double?
    /// JSON-encoded `[RepMetrics]` — decoded lazily for the load–velocity
    /// profile; stored opaque so its schema can evolve like the local one.
    var repsData: Data

    var activity: ActivityType { ActivityType(rawValue: activityRaw) ?? .squat }

    init(
        id: String, date: Date, activityRaw: String, score: Int,
        repCount: Int, usedLiDAR: Bool, weightKg: Double?, repsData: Data
    ) {
        self.id = id
        self.date = date
        self.activityRaw = activityRaw
        self.score = score
        self.repCount = repCount
        self.usedLiDAR = usedLiDAR
        self.weightKg = weightKg
        self.repsData = repsData
    }

    func reps() -> [RepMetrics] {
        (try? JSONDecoder().decode([RepMetrics].self, from: repsData)) ?? []
    }
}
