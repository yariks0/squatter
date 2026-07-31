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
        guard let data = try? Data(contentsOf: url(for: videoURL)),
              let report = try? JSONDecoder().decode(CoachReport.self, from: data)
        else { return nil }
        guard let sane = report.sanitized() else {
            // Unrecoverable glitch report — drop it so the section offers
            // to generate again instead of rendering raw JSON.
            delete(for: videoURL)
            return nil
        }
        if report.hasJSONResidue {
            save(sane, for: videoURL)
        }
        return sane
    }

    static func save(_ report: CoachReport, for videoURL: URL) {
        guard let data = try? JSONEncoder().encode(report) else { return }
        try? data.write(to: url(for: videoURL), options: .atomic)
    }

    static func delete(for videoURL: URL) {
        try? FileManager.default.removeItem(at: url(for: videoURL))
    }
}
