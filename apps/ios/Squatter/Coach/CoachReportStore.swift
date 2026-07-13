import Foundation

/// Persists the LLM coaching report next to its recording, so a fetched
/// response survives leaving the report and app restarts until the user
/// regenerates it. Keyed by the video file, which is stable across both the
/// fresh-analysis and history paths.
enum CoachReportStore {
    static let fileExtension = "coach"

    static func url(for videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension(fileExtension)
    }

    static func load(for videoURL: URL) -> CoachReport? {
        guard let data = try? Data(contentsOf: url(for: videoURL)) else { return nil }
        return try? JSONDecoder().decode(CoachReport.self, from: data)
    }

    static func save(_ report: CoachReport, for videoURL: URL) {
        guard let data = try? JSONEncoder().encode(report) else { return }
        try? data.write(to: url(for: videoURL), options: .atomic)
    }

    static func delete(for videoURL: URL) {
        try? FileManager.default.removeItem(at: url(for: videoURL))
    }
}
