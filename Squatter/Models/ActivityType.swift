import Foundation

/// Lifts the app can record and analyze. Each activity has its own rep
/// signal, metrics, and form rules; the capture pipeline is shared.
enum ActivityType: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case squat
    case benchPress

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .squat: "Squat"
        case .benchPress: "Bench press"
        }
    }

    var systemImage: String {
        switch self {
        case .squat: "figure.strengthtraining.functional"
        case .benchPress: "figure.strengthtraining.traditional"
        }
    }
}
