import Foundation

/// The pre-scanned body: metric bone lengths captured once in a controlled
/// setup (standing, full body in frame, LiDAR, camera level at ~3 m) and
/// applied to every later session — a deliberate scan from a good angle
/// beats re-measuring in whatever corner of the gym the set was filmed in.
struct BodyGeometryProfile: Codable, Sendable, Equatable {
    var metric: MetricBodyGeometry
    var scannedAt: Date
    /// LiDAR-measured standing height from the scan clip; lets the profile
    /// page sanity-check each bone against typical human proportions.
    /// Optional so profiles saved before it existed decode.
    var heightMeters: Double? = nil
}

/// One profile per device, as JSON in Application Support.
enum BodyGeometryProfileStore {
    private static var url: URL {
        get throws {
            try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("body-geometry.json")
        }
    }

    static func load() -> BodyGeometryProfile? {
        guard let url = try? url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BodyGeometryProfile.self, from: data)
    }

    static func save(_ profile: BodyGeometryProfile) throws {
        try JSONEncoder().encode(profile).write(to: url, options: .atomic)
    }

    static func clear() {
        guard let url = try? url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
