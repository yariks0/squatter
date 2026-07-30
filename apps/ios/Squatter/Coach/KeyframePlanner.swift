import Foundation

/// Decides which video moments the coach sees — pure selection + budget
/// policy, no AVFoundation, so it is unit-testable. Tier-1 phases (the moment
/// that defines the rep) ship as a raw + skeleton-overlay pair: the pair is
/// what lets the model verify the tracked skeleton against the real footage.
enum KeyframePlanner {
    enum Phase: String, Sendable {
        case setup
        case bottom
        case touch
        case liftoff
        case midAscent = "mid-ascent"
        case lockout
    }

    /// Which renditions of the frame to send.
    enum ImageSet: Sendable, Equatable {
        case raw
        case overlay
        case pair

        var imageCount: Int { self == .pair ? 2 : 1 }
    }

    struct PlannedFrame: Sendable, Equatable {
        var repNumber: Int
        var phase: Phase
        var time: TimeInterval
        var images: ImageSet
        /// 1 = defining phase, kept longest under budget pressure.
        var tier: Int
    }

    /// The full wishlist degraded to fit `budget` total images. Degradation
    /// order (verification frames survive longest): setup frames → first rep
    /// only, lockouts → first + last rep, pairs → overlay-only outside the
    /// keystone reps (first, last, worst tracking jitter), remaining tier-2
    /// frames dropped outside keystones, then an even stride over the
    /// non-keystone tier-1 frames.
    static func plan(analysis: SquatAnalysis, budget: Int = 30) -> [PlannedFrame] {
        var frames = wishlist(analysis)
        func imageCount(_ frames: [PlannedFrame]) -> Int {
            frames.reduce(0) { $0 + $1.images.imageCount }
        }
        guard imageCount(frames) > budget else { return frames }

        let repNumbers = analysis.reps.map(\.repNumber)
        let worstJitterRep = analysis.reps
            .max { ($0.trackingJitter ?? 0) < ($1.trackingJitter ?? 0) }?.repNumber
        let keystones = Set([repNumbers.first, repNumbers.last, worstJitterRep].compactMap { $0 })

        frames.removeAll { $0.phase == .setup && $0.repNumber != repNumbers.first }
        if imageCount(frames) <= budget { return frames }

        frames.removeAll {
            $0.phase == .lockout
                && $0.repNumber != repNumbers.first && $0.repNumber != repNumbers.last
        }
        if imageCount(frames) <= budget { return frames }

        for index in frames.indices
        where frames[index].images == .pair && !keystones.contains(frames[index].repNumber) {
            frames[index].images = .overlay
        }
        if imageCount(frames) <= budget { return frames }

        frames.removeAll { $0.tier > 1 && !keystones.contains($0.repNumber) }
        if imageCount(frames) <= budget { return frames }

        // Even stride over what's left outside the keystone reps.
        let fixed = frames.filter { keystones.contains($0.repNumber) }
        let pool = frames.filter { !keystones.contains($0.repNumber) }
        let room = max(0, budget - imageCount(fixed))
        var kept: [PlannedFrame] = []
        if room > 0, !pool.isEmpty {
            let step = Double(pool.count) / Double(min(room, pool.count))
            var next = 0.0
            for (index, frame) in pool.enumerated() where Double(index) >= next && kept.count < room {
                kept.append(frame)
                next += step
            }
        }
        return (fixed + kept).sorted { ($0.repNumber, $0.time) < ($1.repNumber, $1.time) }
    }

    /// Everything worth seeing, before budgeting. Phases are derived from
    /// the rep timeline: bottom = start + eccentric.
    private static func wishlist(_ analysis: SquatAnalysis) -> [PlannedFrame] {
        var frames: [PlannedFrame] = []
        for rep in analysis.reps {
            let bottom = rep.startTime + rep.eccentricSeconds
            switch analysis.kind {
            case .squat:
                frames.append(.init(
                    repNumber: rep.repNumber, phase: .bottom, time: bottom, images: .pair, tier: 1
                ))
                // Valgus is a squat metric; the old extractor ran this gate
                // for every activity.
                if rep.kneeValgusRatio >= AnalysisTuning.valgusWarningRatio {
                    frames.append(.init(
                        repNumber: rep.repNumber, phase: .midAscent,
                        time: bottom + rep.concentricSeconds / 2, images: .raw, tier: 2
                    ))
                }
                frames.append(.init(
                    repNumber: rep.repNumber, phase: .lockout, time: rep.endTime,
                    images: .raw, tier: 3
                ))
            case .benchPress:
                // Arch, grip, and feet are set before the bar moves.
                frames.append(.init(
                    repNumber: rep.repNumber, phase: .setup, time: rep.startTime,
                    images: .raw, tier: 2
                ))
                frames.append(.init(
                    repNumber: rep.repNumber, phase: .touch, time: bottom, images: .pair, tier: 1
                ))
                frames.append(.init(
                    repNumber: rep.repNumber, phase: .lockout, time: rep.endTime,
                    images: .raw, tier: 3
                ))
            case .deadlift:
                // Settled over the bar just before the pull.
                frames.append(.init(
                    repNumber: rep.repNumber, phase: .setup,
                    time: max(rep.startTime, bottom - 0.3), images: .raw, tier: 2
                ))
                // Bar just off the floor — where spine line and bar gap matter.
                frames.append(.init(
                    repNumber: rep.repNumber, phase: .liftoff,
                    time: bottom + 0.2 * rep.concentricSeconds, images: .pair, tier: 1
                ))
                frames.append(.init(
                    repNumber: rep.repNumber, phase: .lockout, time: rep.endTime,
                    images: .raw, tier: 3
                ))
            }
        }
        return frames
    }
}
