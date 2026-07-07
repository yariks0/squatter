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
}
