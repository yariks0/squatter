import Foundation

enum FileLocations {
    static func recordingsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Base URL (no extension) for a new recording; the video and its depth
    /// sidecar share this base name.
    static func newRecordingBaseURL() throws -> URL {
        try recordingsDirectory().appendingPathComponent(UUID().uuidString)
    }

    /// All recorded videos, newest first.
    static func recordedVideoURLs() throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(
            at: try recordingsDirectory(),
            includingPropertiesForKeys: [.creationDateKey]
        )
        func created(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
        }
        return files.filter { $0.pathExtension == "mov" }
            .sorted { created($0) > created($1) }
    }
}
