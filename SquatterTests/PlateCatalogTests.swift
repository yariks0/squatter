import Foundation
import Testing
@testable import Squatter

@Suite struct PlateCatalogTests {
    /// A black-plate gym: no colors, distinct diameters.
    private let catalog = PlateCatalog(barWeightKg: 20, plates: [
        PlateSpec(weightKg: 25, diameterMeters: 0.45),
        PlateSpec(weightKg: 15, diameterMeters: 0.40),
        PlateSpec(weightKg: 10, diameterMeters: 0.325),
        PlateSpec(weightKg: 5, diameterMeters: 0.23),
    ])

    @Test func matchesByDiameterWithinTolerance() {
        #expect(catalog.match(diameterMeters: 0.45)?.weightKg == 25)
        #expect(catalog.match(diameterMeters: 0.437)?.weightKg == 25)
        #expect(catalog.match(diameterMeters: 0.33)?.weightKg == 10)
        // Between classes and outside tolerance of both.
        #expect(catalog.match(diameterMeters: 0.37) == nil)
        #expect(catalog.match(diameterMeters: 0.60) == nil)
    }

    @Test func ambiguousDiametersRefuseToMatch() {
        var crowded = catalog
        // A 20 kg plate 1 cm off the 25 — closer than the tolerance can
        // separate, so neither may be silently picked.
        crowded.plates.append(PlateSpec(weightKg: 20, diameterMeters: 0.44))
        #expect(crowded.match(diameterMeters: 0.445) == nil)
        // Far from the crowded pair still matches cleanly.
        #expect(crowded.match(diameterMeters: 0.325)?.weightKg == 10)
    }

    @Test func totalsAreBarPlusTwiceOneSide() {
        let side = [
            catalog.plates[0]: 2,  // 2 × 25
            catalog.plates[2]: 1,  // 1 × 10
        ]
        #expect(catalog.totalKg(perSide: side) == 20 + 2 * (2 * 25 + 10))
    }

    @Test func clusteringNeedsTwoSightingsPerClass() {
        let samples = [0.451, 0.448, 0.325, 0.33, 0.28]  // 0.28 seen once
            .map { PlateDetector.Sighting(diameterMeters: $0, color: nil) }
        let clusters = PlateDetector.cluster(samples)
        #expect(clusters.count == 2)
        #expect(abs(clusters[0].diameterMeters - 0.45) < 0.005)
        #expect(abs(clusters[1].diameterMeters - 0.3275) < 0.005)
        #expect(PlateDetector.cluster([]).isEmpty)
    }

    /// Standard color-coded set: every full-size bumper is 450 mm — only
    /// color separates them, and without color the match must refuse.
    @Test func colorSeparatesSameDiameterBumpers() {
        let standard = PlateCatalog(barWeightKg: 20, plates: PlateCatalog.standardIWFPlates)
        #expect(standard.match(diameterMeters: 0.448, color: .red)?.weightKg == 25)
        #expect(standard.match(diameterMeters: 0.452, color: .blue)?.weightKg == 20)
        #expect(standard.match(diameterMeters: 0.45, color: .green)?.weightKg == 10)
        // No color signal on identical diameters: ambiguous, no guess.
        #expect(standard.match(diameterMeters: 0.45) == nil)
        // Distinct diameter still matches without color (5 kg is 230 mm).
        #expect(standard.match(diameterMeters: 0.235)?.weightKg == 5)
        // Small red change plate vs big red bumper: diameter decides.
        #expect(standard.match(diameterMeters: 0.19, color: .red)?.weightKg == 2.5)
    }

    @Test func clusterColorNeedsAgreement() {
        let agreeing = PlateDetector.cluster([
            PlateDetector.Sighting(diameterMeters: 0.45, color: .red),
            PlateDetector.Sighting(diameterMeters: 0.452, color: .red),
            PlateDetector.Sighting(diameterMeters: 0.449, color: nil),
        ])
        #expect(agreeing.first?.color == .red)
        let conflicted = PlateDetector.cluster([
            PlateDetector.Sighting(diameterMeters: 0.45, color: .red),
            PlateDetector.Sighting(diameterMeters: 0.452, color: .blue),
        ])
        #expect(conflicted.first?.color == nil)
    }

    @Test func pixelColorClassification() {
        #expect(PlateColor.classify(red: 0.8, green: 0.1, blue: 0.12) == .red)
        #expect(PlateColor.classify(red: 0.1, green: 0.2, blue: 0.75) == .blue)
        #expect(PlateColor.classify(red: 0.85, green: 0.75, blue: 0.1) == .yellow)
        #expect(PlateColor.classify(red: 0.15, green: 0.6, blue: 0.2) == .green)
        #expect(PlateColor.classify(red: 0.9, green: 0.9, blue: 0.88) == .white)
        #expect(PlateColor.classify(red: 0.08, green: 0.08, blue: 0.09) == .black)
        // Mid-grey gym wall: no plate code.
        #expect(PlateColor.classify(red: 0.5, green: 0.5, blue: 0.5) == nil)
    }
}
