import Foundation

/// IWF plate color code, plus black for uncoded gym iron. Detection votes
/// pixels on the plate face into these buckets.
enum PlateColor: String, Codable, Sendable, CaseIterable, Identifiable {
    case red, blue, yellow, green, white, black

    var id: String { rawValue }

    /// Classifies one RGB pixel (components 0–1); nil for colors that
    /// don't map to a plate code (grey walls, skin, wood).
    static func classify(red: Double, green: Double, blue: Double) -> PlateColor? {
        let value = max(red, green, blue)
        if value < 0.18 { return .black }
        let delta = value - min(red, green, blue)
        let saturation = delta / value
        if saturation < 0.22 {
            if value > 0.7 { return .white }
            return value <= 0.35 ? .black : nil
        }
        var hue: Double
        if value == red {
            hue = (green - blue) / delta * 60
            if hue < 0 { hue += 360 }
        } else if value == green {
            hue = ((blue - red) / delta + 2) * 60
        } else {
            hue = ((red - green) / delta + 4) * 60
        }
        switch hue {
        case ..<20, 340...: return .red
        case 40 ..< 75: return .yellow
        case 75 ..< 170: return .green
        case 190 ..< 265: return .blue
        default: return nil
        }
    }
}

/// One plate type the user's gym stocks. Recognition is diameter-first —
/// all-black gyms classify by size alone — with color as the tie-breaker
/// for standard sets, where every full-size bumper is 450 mm and only the
/// IWF color tells 25 from 20 from 15 from 10.
struct PlateSpec: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var weightKg: Double
    var diameterMeters: Double
    /// nil = unknown/any; set for color-coded sets.
    var color: PlateColor? = nil
    /// Optional user note ("thin iron 15").
    var label: String? = nil
}

/// The user's plate inventory plus their bar. Persisted as JSON next to the
/// body-geometry profile.
struct PlateCatalog: Codable, Sendable, Equatable {
    var barWeightKg: Double = 20
    var plates: [PlateSpec] = []

    /// Nearest catalog plate within diameter tolerance; when the sighting
    /// carries a color and colored candidates exist, color decides —
    /// standard bumpers share one diameter and differ only by their code.
    /// nil when unknown or still ambiguous (ambiguity must reach the user,
    /// not silently pick one).
    func match(diameterMeters: Double, color: PlateColor? = nil) -> PlateSpec? {
        let tolerance = AnalysisTuning.plateDiameterToleranceMeters
        var candidates = plates
            .map { (spec: $0, error: abs($0.diameterMeters - diameterMeters)) }
            .filter { $0.error <= tolerance }
        if let color {
            let colored = candidates.filter { $0.spec.color == color }
            if colored.count == 1 { return colored[0].spec }
            if !colored.isEmpty { candidates = colored }
        }
        candidates.sort { $0.error < $1.error }
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

    /// The color-coded competition set — a one-tap starting inventory. All
    /// full-size bumpers are 450 mm; only color separates them, which is
    /// exactly what the color strategy exists for.
    static let standardIWFPlates: [PlateSpec] = [
        PlateSpec(weightKg: 25, diameterMeters: 0.45, color: .red),
        PlateSpec(weightKg: 20, diameterMeters: 0.45, color: .blue),
        PlateSpec(weightKg: 15, diameterMeters: 0.45, color: .yellow),
        PlateSpec(weightKg: 10, diameterMeters: 0.45, color: .green),
        PlateSpec(weightKg: 5, diameterMeters: 0.23, color: .white),
        PlateSpec(weightKg: 2.5, diameterMeters: 0.19, color: .red),
    ]
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
