import Foundation

/// One plate type the user's gym stocks. Recognition is by metric diameter
/// alone — gyms with all-black plates (no IWF color code) still classify
/// cleanly as long as diameters differ, which is exactly what the teach
/// flow records.
struct PlateSpec: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var weightKg: Double
    var diameterMeters: Double
    /// Optional user note ("red bumper", "thin iron 15").
    var label: String? = nil
}

/// The user's plate inventory plus their bar. Persisted as JSON next to the
/// body-geometry profile.
struct PlateCatalog: Codable, Sendable, Equatable {
    var barWeightKg: Double = 20
    var plates: [PlateSpec] = []

    /// Nearest catalog plate within tolerance; nil when unknown or when two
    /// plates are close enough to confuse (ambiguity must reach the user,
    /// not silently pick one).
    func match(diameterMeters: Double) -> PlateSpec? {
        let tolerance = AnalysisTuning.plateDiameterToleranceMeters
        let candidates = plates
            .map { (spec: $0, error: abs($0.diameterMeters - diameterMeters)) }
            .filter { $0.error <= tolerance }
            .sorted { $0.error < $1.error }
        guard let best = candidates.first else { return nil }
        if candidates.count > 1, candidates[1].error - best.error < tolerance / 2 {
            return nil
        }
        return best.spec
    }

    /// Total load for a symmetric bar: bar + 2 × one side's plates.
    func totalKg(perSide: [PlateSpec: Int]) -> Double {
        barWeightKg + 2 * perSide.reduce(0) { $0 + $1.key.weightKg * Double($1.value) }
    }
}

extension PlateSpec: Hashable {}

enum PlateCatalogStore {
    private static var url: URL {
        get throws {
            try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("plate-catalog.json")
        }
    }

    static func load() -> PlateCatalog? {
        guard let url = try? url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PlateCatalog.self, from: data)
    }

    static func save(_ catalog: PlateCatalog) throws {
        try JSONEncoder().encode(catalog).write(to: url, options: .atomic)
    }
}
