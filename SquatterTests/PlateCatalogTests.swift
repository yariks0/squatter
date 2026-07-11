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
        let clusters = PlateDetector.cluster(samples)
        #expect(clusters.count == 2)
        #expect(abs(clusters[0] - 0.45) < 0.005)
        #expect(abs(clusters[1] - 0.3275) < 0.005)
        #expect(PlateDetector.cluster([]).isEmpty)
    }
}
