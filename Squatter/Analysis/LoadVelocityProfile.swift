import Foundation

/// Linear load–velocity profile for one lift. Mean concentric velocity
/// falls near-linearly as load rises, so sessions at three or more
/// distinct loads fit a line whose crossing of the lift's minimal velocity
/// estimates the 1RM — no max attempt needed. Fresh best-rep MCVs per load
/// go in; stale grinding reps would flatten the line.
struct LoadVelocityProfile: Equatable {
    /// m/s lost per added kg (negative by construction).
    var slope: Double
    /// m/s the line predicts at 0 kg.
    var intercept: Double
    var pointCount: Int

    /// Fits from (load, best-rep MCV) points; nil until three sufficiently
    /// distinct loads spanning at least 10 kg exist, or when the fit isn't
    /// downhill (noise, not a profile).
    static func fit(points: [(loadKg: Double, velocity: Double)]) -> LoadVelocityProfile? {
        // One point per load (2.5 kg buckets), keeping the fastest MCV —
        // the freshest expression of that load.
        var bestPerLoad: [Double: Double] = [:]
        for point in points where point.loadKg > 0 && point.velocity > 0 {
            let bucket = (point.loadKg / 2.5).rounded() * 2.5
            bestPerLoad[bucket] = max(bestPerLoad[bucket] ?? 0, point.velocity)
        }
        let loads = bestPerLoad.keys.sorted()
        guard loads.count >= 3, let lightest = loads.first, let heaviest = loads.last,
              heaviest - lightest >= 10 else { return nil }

        let n = Double(loads.count)
        let sumX = loads.reduce(0, +)
        let sumY = loads.reduce(0) { $0 + bestPerLoad[$1]! }
        let sumXY = loads.reduce(0) { $0 + $1 * bestPerLoad[$1]! }
        let sumXX = loads.reduce(0) { $0 + $1 * $1 }
        let denominator = n * sumXX - sumX * sumX
        guard abs(denominator) > 1e-9 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denominator
        guard slope < 0 else { return nil }
        return LoadVelocityProfile(
            slope: slope,
            intercept: (sumY - slope * sumX) / n,
            pointCount: loads.count
        )
    }

    /// Load at which the line reaches the lift's minimal velocity.
    func estimatedOneRepMax(atMinimalVelocity velocity: Double) -> Double {
        (velocity - intercept) / slope
    }

    func predictedVelocity(atLoad loadKg: Double) -> Double {
        intercept + slope * loadKg
    }
}
