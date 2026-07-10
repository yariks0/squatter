import Foundation

struct Finding: Codable, Sendable, Identifiable {
    enum Severity: String, Codable, Sendable, Comparable {
        case info, warning, risk

        private var rank: Int {
            switch self {
            case .info: 0
            case .warning: 1
            case .risk: 2
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }

    var id = UUID()
    var severity: Severity
    var title: String
    var detail: String
    /// Rep numbers (1-based) the finding applies to; empty = whole set.
    var repNumbers: [Int]
    /// Wrong-vs-right diagram shown with the finding; nil = no diagram.
    /// Optional so analyses saved before form hints still decode.
    var topic: FormHintTopic? = nil
}

/// Deterministic mapping from per-rep metrics to coaching findings.
/// Thresholds live in `AnalysisTuning`.
enum FormRules {
    static func findings(for reps: [RepMetrics], activity: ActivityType = .squat) -> [Finding] {
        switch activity {
        case .squat: squatFindings(for: reps)
        case .benchPress: benchFindings(for: reps)
        case .deadlift: deadliftFindings(for: reps)
        }
    }

    /// The single finding shown when the skeleton was too unstable to trust
    /// joint angles (see `TrackingQuality`): no form claims, just the reason
    /// and how to film so the next set is measurable.
    static func trackingQualityFinding(activity: ActivityType) -> Finding {
        let framing = switch activity {
        case .squat:
            "Film from about 3 m at a 45° front-side angle with your whole body in frame."
        case .benchPress:
            "Film from about 3 m with your whole body — head to feet — in frame; a raised phone angled down at the bench keeps the head and hips visible."
        case .deadlift:
            "Film from about 3 m at a 45° front-side angle with your whole body and the bar in frame, including the plates on the floor."
        }
        return Finding(
            severity: .warning,
            title: "Tracking too unstable to judge form",
            detail: "The body couldn't be tracked reliably in this recording, so form feedback was skipped — any angle-based call would be noise, and the rep count may be off. " + framing,
            repNumbers: [],
            topic: .framing
        )
    }

    private static func squatFindings(for reps: [RepMetrics]) -> [Finding] {
        guard !reps.isEmpty else {
            return [Finding(
                severity: .info,
                title: "No reps detected",
                detail: "Make sure your whole body stays in frame for the full set, with the phone about 3 m away at a 45° front-side angle.",
                repNumbers: [],
                topic: .framing
            )]
        }
        var findings: [Finding] = []
        findings.append(contentsOf: depthFindings(reps))
        findings.append(contentsOf: valgusFindings(reps))
        findings.append(contentsOf: torsoFindings(reps))
        findings.append(contentsOf: elbowLiftFindings(reps))
        findings.append(contentsOf: balanceFindings(reps))
        findings.append(contentsOf: tempoFindings(reps))
        findings.append(contentsOf: asymmetryFindings(reps))
        findings.append(contentsOf: stanceFindings(reps))
        findings.append(contentsOf: bottomStabilityFindings(reps))
        findings.append(contentsOf: lockoutFindings(reps))
        findings.append(contentsOf: fatigueFindings(reps))
        findings.append(contentsOf: velocityFindings(reps))
        return findings.sorted { $0.severity > $1.severity }
    }

    /// Bench standards: bar touches the lower chest with the elbows tucked
    /// ~45–75° from the torso and the forearms vertical, controlled descent
    /// with no bounce, a J-curve press back over the shoulders, and full
    /// elbow lockout on every rep.
    private static func benchFindings(for reps: [RepMetrics]) -> [Finding] {
        guard !reps.isEmpty else {
            return [Finding(
                severity: .info,
                title: "No reps detected",
                detail: "Make sure your whole body and the bar stay in frame for the full set — phone about 3 m away at bench height, at a 45° angle from the foot of the bench.",
                repNumbers: [],
                topic: .framing
            )]
        }
        var findings: [Finding] = []
        findings.append(contentsOf: benchTouchFindings(reps))
        findings.append(contentsOf: benchFlareFindings(reps))
        findings.append(contentsOf: benchForearmFindings(reps))
        findings.append(contentsOf: benchBounceFindings(reps))
        findings.append(contentsOf: benchLockoutFindings(reps))
        findings.append(contentsOf: benchBarPathFindings(reps))
        findings.append(contentsOf: benchTouchConsistencyFindings(reps))
        findings.append(contentsOf: tempoFindings(reps))
        findings.append(contentsOf: benchAsymmetryFindings(reps))
        findings.append(contentsOf: fatigueFindings(reps))
        findings.append(contentsOf: velocityFindings(reps))
        return findings.sorted { $0.severity > $1.severity }
    }

    /// Deadlift standards: neutral spine throughout (the injury line), bar
    /// dragged up the legs, hips and shoulders leaving the floor together,
    /// full tall lockout, plates settled between reps.
    private static func deadliftFindings(for reps: [RepMetrics]) -> [Finding] {
        guard !reps.isEmpty else {
            return [Finding(
                severity: .info,
                title: "No reps detected",
                detail: "Make sure your whole body and the bar stay in frame for the full set — phone about 3 m away at a 45° front-side angle, plates visible on the floor.",
                repNumbers: [],
                topic: .framing
            )]
        }
        var findings: [Finding] = []
        findings.append(contentsOf: spineFindings(reps))
        findings.append(contentsOf: barGapFindings(reps))
        findings.append(contentsOf: hipShootFindings(reps))
        findings.append(contentsOf: deadliftLockoutFindings(reps))
        findings.append(contentsOf: deadliftBounceFindings(reps))
        // The first pull starts on the floor (no eccentric); keep it out of
        // the shared tempo rules so a zero-length "descent" doesn't flag.
        findings.append(contentsOf: tempoFindings(reps.filter { $0.eccentricSeconds > 0.05 }))
        findings.append(contentsOf: asymmetryFindings(reps))
        findings.append(contentsOf: velocityFindings(reps))
        return findings.sorted { $0.severity > $1.severity }
    }

    /// Rounding under load is THE deadlift injury mechanism — flexed lumbar
    /// tissue takes the shear the erectors should carry.
    private static func spineFindings(_ reps: [RepMetrics]) -> [Finding] {
        let risky = reps.filter {
            ($0.spineFlexionDegrees ?? 180) < AnalysisTuning.deadliftSpineFlexionRiskDegrees
        }
        let rounding = reps.filter {
            let spine = $0.spineFlexionDegrees ?? 180
            return spine < AnalysisTuning.deadliftSpineFlexionWarningDegrees
                && spine >= AnalysisTuning.deadliftSpineFlexionRiskDegrees
        }
        var findings: [Finding] = []
        if !risky.isEmpty {
            findings.append(Finding(
                severity: .risk,
                title: "Back rounding under load",
                detail: "The spine visibly flexed mid-pull on \(repList(risky)) — the classic deadlift injury pattern, loading the discs in their weakest position. Stop the set when this appears: reset with a big breath into the belt line, chest proud, hips wedged down, and take weight off the bar until the line holds.",
                repNumbers: risky.map(\.repNumber),
                topic: .neutralSpine
            ))
        }
        if !rounding.isEmpty {
            findings.append(Finding(
                severity: .warning,
                title: "Back losing its line",
                detail: "The upper back started rounding on \(repList(rounding)). Set the lats before the bar leaves the floor — “bend the bar around your shins”, chest proud — and treat any rep the line won't hold as the last one.",
                repNumbers: rounding.map(\.repNumber),
                topic: .neutralSpine
            ))
        }
        if risky.isEmpty, rounding.isEmpty, reps.contains(where: { $0.spineFlexionDegrees != nil }) {
            findings.append(Finding(
                severity: .info,
                title: "Neutral spine held",
                detail: "Your back kept its line on every rep — the single most important thing in a deadlift. Keep bracing exactly like this as the weight goes up.",
                repNumbers: []
            ))
        }
        return findings
    }

    private static func barGapFindings(_ reps: [RepMetrics]) -> [Finding] {
        let drifting = reps.filter {
            ($0.barGapRatio ?? 0) > AnalysisTuning.deadliftBarGapWarningRatio
        }
        guard !drifting.isEmpty else { return [] }
        return [Finding(
            severity: .warning,
            title: "Bar drifting off your legs",
            detail: "The bar swung away from your legs on \(repList(drifting)) — every centimeter of gap is a moment arm your lower back has to hold. Drag the bar up the thighs: lats tight (“protect your armpits”), shoulders over the bar at the start, and let it graze the skin.",
            repNumbers: drifting.map(\.repNumber),
            topic: .barClose
        )]
    }

    private static func hipShootFindings(_ reps: [RepMetrics]) -> [Finding] {
        let shooting = reps.filter {
            ($0.hipShootRatio ?? 1) >= AnalysisTuning.deadliftHipShootRatio
        }
        guard !shooting.isEmpty else { return [] }
        return [Finding(
            severity: .warning,
            title: "Hips shooting up first",
            detail: "Off the floor your hips rose much faster than your shoulders on \(repList(shooting)) — the pull turns into a stiff-leg lift and the back takes the whole load. Cue “push the floor away”: chest and hips rise together until the bar passes the knees.",
            repNumbers: shooting.map(\.repNumber),
            topic: .hipsRiseEarly
        )]
    }

    private static func deadliftLockoutFindings(_ reps: [RepMetrics]) -> [Finding] {
        let soft = reps.filter {
            ($0.lockoutKneeDegrees ?? 180) < AnalysisTuning.deadliftLockoutKneeDegrees
        }
        guard !soft.isEmpty else { return [] }
        return [Finding(
            severity: .warning,
            title: "Soft lockout",
            detail: "The pull stopped short of standing tall on \(repList(soft)). Finish every rep with the hips through and knees straight — squeeze the glutes, no lean-back — before lowering.",
            repNumbers: soft.map(\.repNumber),
            topic: .squatLockout
        )]
    }

    private static func deadliftBounceFindings(_ reps: [RepMetrics]) -> [Finding] {
        // The first pull starts from a dead stop by definition.
        let bounced = reps.dropFirst().filter {
            ($0.touchPauseSeconds ?? 1) < AnalysisTuning.deadliftBouncePauseSeconds
        }
        guard bounced.count > reps.count / 3 else { return [] }
        return [Finding(
            severity: .warning,
            title: "Bouncing off the floor",
            detail: "The plates rebounded straight off the floor on \(repList(Array(bounced))). A bounce feeds momentum and catches the back before it's re-braced — let the bar settle, reset the breath and lats, then pull.",
            repNumbers: bounced.map(\.repNumber),
            topic: .controlDescent
        )]
    }

    /// Velocity-loss autoregulation (LiDAR captures only): once the bar
    /// moves 20% slower than the set's best rep, extra reps add fatigue
    /// faster than strength — the standard VBT "rack it" signal.
    private static func velocityFindings(_ reps: [RepMetrics]) -> [Finding] {
        let velocities = reps.compactMap { rep in
            rep.meanConcentricVelocity.map { (number: rep.repNumber, mcv: $0) }
        }
        guard velocities.count >= 3, let last = velocities.last,
              let best = velocities.map(\.mcv).max(), best > 0 else { return [] }
        let loss = (best - last.mcv) / best
        guard loss >= AnalysisTuning.velocityLossWarningFraction else { return [] }
        return [Finding(
            severity: .info,
            title: "Bar speed dropping",
            detail: String(
                format: "Rep %d moved %.0f%% slower than your fastest rep (%.2f vs %.2f m/s). Past %.0f%% velocity loss, extra reps mostly add fatigue — a good place to rack it.",
                last.number, loss * 100, last.mcv, best,
                AnalysisTuning.velocityLossWarningFraction * 100
            ),
            repNumbers: [last.number]
        )]
    }

    private static func benchTouchFindings(_ reps: [RepMetrics]) -> [Finding] {
        let high = reps.filter {
            ($0.elbowFlexionDegrees ?? 0) > AnalysisTuning.benchShallowElbowDegrees
        }
        let close = reps.filter {
            let elbow = $0.elbowFlexionDegrees ?? 0
            return elbow > AnalysisTuning.benchFullTouchElbowDegrees
                && elbow <= AnalysisTuning.benchShallowElbowDegrees
        }
        var findings: [Finding] = []
        if high.isEmpty, close.isEmpty {
            findings.append(Finding(
                severity: .info,
                title: "Full range of motion",
                detail: "The bar came all the way down to the chest on every rep. Keep touching the same lower-chest spot.",
                repNumbers: []
            ))
        }
        if !close.isEmpty {
            findings.append(Finding(
                severity: .info,
                title: "Almost to the chest",
                detail: "The bar stopped just short of the chest on \(repList(close)). Touch the lower chest lightly on every rep — a consistent touch point makes the press repeatable.",
                repNumbers: close.map(\.repNumber),
                topic: .benchTouch
            ))
        }
        if !high.isEmpty {
            findings.append(Finding(
                severity: high.count > reps.count / 2 ? .warning : .info,
                title: "Cutting the rep high",
                detail: "The bar turned around well above the chest on \(repList(high)). Lower until the bar touches the lower chest with the forearms vertical; if that position hurts, reduce the load, not the range.",
                repNumbers: high.map(\.repNumber),
                topic: .benchTouch
            ))
        }
        return findings
    }

    private static func benchFlareFindings(_ reps: [RepMetrics]) -> [Finding] {
        let risky = reps.filter {
            ($0.elbowFlareDegrees ?? 0) >= AnalysisTuning.benchFlareRiskDegrees
        }
        let flaring = reps.filter {
            let flare = $0.elbowFlareDegrees ?? 0
            return flare >= AnalysisTuning.benchFlareWarningDegrees
                && flare < AnalysisTuning.benchFlareRiskDegrees
        }
        var findings: [Finding] = []
        if !risky.isEmpty {
            findings.append(Finding(
                severity: .risk,
                title: "Elbows flared to a T",
                detail: "Upper arms near 90° from the torso at the touch on \(repList(risky)) — the classic shoulder-impingement position. Tuck the elbows to roughly 45–70° and touch lower on the chest.",
                repNumbers: risky.map(\.repNumber),
                topic: .elbowFlare
            ))
        }
        if !flaring.isEmpty {
            findings.append(Finding(
                severity: .warning,
                title: "Elbows drifting wide",
                detail: "Elbow flare creeping up on \(repList(flaring)). Keep the upper arms about 45–70° from the torso at the touch — think “bend the bar” or “tuck to the lats” on the way down.",
                repNumbers: flaring.map(\.repNumber),
                topic: .elbowFlare
            ))
        }
        let pinned = reps.filter {
            ($0.elbowFlareDegrees ?? 60) < AnalysisTuning.benchOverTuckFlareDegrees
        }
        if !pinned.isEmpty {
            findings.append(Finding(
                severity: pinned.count > reps.count / 2 ? .warning : .info,
                title: "Elbows over-tucked",
                detail: "Upper arms pinned inside ~40° of the torso on \(repList(pinned)). Over-tucking takes the chest out of the press and loads the front delts and wrists through a longer path. Let the elbows sit around 45–70° — an arrow, not a pencil.",
                repNumbers: pinned.map(\.repNumber),
                topic: .elbowFlare
            ))
        }
        return findings
    }

    private static func benchForearmFindings(_ reps: [RepMetrics]) -> [Finding] {
        let tipping = reps.filter {
            ($0.forearmTiltDegrees ?? 0) >= AnalysisTuning.benchForearmTiltWarningDegrees
        }
        guard !tipping.isEmpty else { return [] }
        return [Finding(
            severity: .warning,
            title: "Forearms not vertical",
            detail: "The forearms tipped well off vertical at the touch on \(repList(tipping)) — force leaks sideways instead of driving the bar. That's usually a grip-width or touch-point mismatch: adjust hand spacing until the wrist stacks straight over the elbow when the bar meets the chest.",
            repNumbers: tipping.map(\.repNumber),
            topic: .forearmVertical
        )]
    }

    private static func benchBounceFindings(_ reps: [RepMetrics]) -> [Finding] {
        // A bounce needs a chest touch: cut-high reps can't bounce.
        let bounced = reps.filter {
            ($0.touchPauseSeconds ?? 1) < AnalysisTuning.benchBouncePauseSeconds
                && ($0.elbowFlexionDegrees ?? 180) <= AnalysisTuning.benchFullTouchElbowDegrees
        }
        guard bounced.count > reps.count / 3 else { return [] }
        return [Finding(
            severity: .warning,
            title: "Bouncing off the chest",
            detail: "The bar rebounded straight off the chest on \(repList(bounced)). Touch-and-go is fine, but the touch should be a light tap off a controlled descent — sinking the bar and bouncing hides strength and beats up the ribcage.",
            repNumbers: bounced.map(\.repNumber),
            topic: .controlDescent
        )]
    }

    private static func benchLockoutFindings(_ reps: [RepMetrics]) -> [Finding] {
        let cut = reps.filter {
            ($0.lockoutElbowDegrees ?? 180) < AnalysisTuning.benchLockoutElbowDegrees
        }
        guard !cut.isEmpty else { return [] }
        return [Finding(
            severity: .warning,
            title: "Not locking out",
            detail: "The elbows never reached full extension on \(repList(cut)). Finish every rep with the arms straight and the bar stacked over the shoulders before descending again.",
            repNumbers: cut.map(\.repNumber),
            topic: .benchLockout
        )]
    }

    private static func benchBarPathFindings(_ reps: [RepMetrics]) -> [Finding] {
        let backward = reps.filter {
            ($0.barPathDriftRatio ?? 0.3) < AnalysisTuning.benchBarPathMinimumRatio
        }
        let sweeping = reps.filter {
            ($0.barPathDriftRatio ?? 0.3) > AnalysisTuning.benchBarPathWarningRatio
        }
        var findings: [Finding] = []
        if !backward.isEmpty {
            findings.append(Finding(
                severity: .warning,
                title: "Pressing toward the feet",
                detail: "The bar moved toward the belly instead of back over the shoulders on \(repList(backward)). Press up and slightly back — lockout belongs stacked over the shoulder joint.",
                repNumbers: backward.map(\.repNumber),
                topic: .barPath
            ))
        }
        if !sweeping.isEmpty {
            findings.append(Finding(
                severity: .warning,
                title: "Bar path sweeping long",
                detail: "A very long horizontal sweep on \(repList(sweeping)). Some travel back over the shoulders is correct, but a big sweep wastes force — touch the lower chest and drive the bar up with only a slight backward drift.",
                repNumbers: sweeping.map(\.repNumber),
                topic: .barPath
            ))
        }
        return findings
    }

    private static func benchTouchConsistencyFindings(_ reps: [RepMetrics]) -> [Finding] {
        let offsets = reps.compactMap(\.touchOffsetRatio)
        guard reps.count >= 3, offsets.count >= 3,
              let low = offsets.min(), let high = offsets.max(),
              high - low > AnalysisTuning.benchTouchSpreadWarningRatio else { return [] }
        return [Finding(
            severity: .warning,
            title: "Touch point wandering",
            detail: "The bar touched noticeably different spots across the set. Pick one lower-chest landmark and hit it on every rep — a consistent touch point is what makes the groove repeatable.",
            repNumbers: [],
            topic: .benchTouch
        )]
    }

    private static func benchAsymmetryFindings(_ reps: [RepMetrics]) -> [Finding] {
        let uneven = reps.filter { $0.asymmetryDegrees >= AnalysisTuning.asymmetryWarningDegrees }
        guard uneven.count > reps.count / 3 else { return [] }
        return [Finding(
            severity: .warning,
            title: "Uneven press",
            detail: "One arm bent noticeably more than the other on \(repList(uneven)) — usually one side lagging or a crooked grip. Check your grip width against the bar rings and film head-on occasionally.",
            repNumbers: uneven.map(\.repNumber)
        )]
    }

    /// 0–100 set score: start from 100, subtract per finding severity.
    static func score(for findings: [Finding]) -> Int {
        let penalty = findings.reduce(0) { total, finding in
            switch finding.severity {
            case .info: total
            case .warning: total + 12
            case .risk: total + 25
            }
        }
        return max(0, 100 - penalty)
    }

    private static func depthFindings(_ reps: [RepMetrics]) -> [Finding] {
        let shallow = reps.filter { $0.hipBelowKneeDegrees < AnalysisTuning.parallelToleranceDegrees }
        let atParallel = reps.filter {
            $0.hipBelowKneeDegrees >= AnalysisTuning.parallelToleranceDegrees
                && $0.hipBelowKneeDegrees < AnalysisTuning.fullDepthDegrees
        }
        var findings: [Finding] = []
        if shallow.isEmpty, atParallel.isEmpty {
            findings.append(Finding(
                severity: .info,
                title: "Good depth",
                detail: "Full depth on every rep — hip crease clearly below the knee, the position Chinese weightlifters train for. Keep it up.",
                repNumbers: []
            ))
        }
        if !atParallel.isEmpty {
            findings.append(Finding(
                severity: .info,
                title: "Close to full depth",
                detail: "You reached about parallel on \(repList(atParallel)). The standard is sitting fully down with the hip crease below the knee — if ankle mobility limits you, heel-elevated work gets you there over time.",
                repNumbers: atParallel.map(\.repNumber),
                topic: .squatDepth
            ))
        }
        if !shallow.isEmpty {
            findings.append(Finding(
                severity: shallow.count > reps.count / 2 ? .warning : .info,
                title: "Shallow depth",
                detail: "Hips stayed above parallel on \(repList(shallow)). Aim to sit fully down between your legs with the torso upright; if mobility is the limit, elevate your heels and go only as deep as you can with a neutral back.",
                repNumbers: shallow.map(\.repNumber),
                topic: .squatDepth
            ))
        }
        return findings
    }

    private static func valgusFindings(_ reps: [RepMetrics]) -> [Finding] {
        let risky = reps.filter { $0.kneeValgusRatio >= AnalysisTuning.valgusRiskRatio }
        let caving = reps.filter {
            $0.kneeValgusRatio >= AnalysisTuning.valgusWarningRatio
                && $0.kneeValgusRatio < AnalysisTuning.valgusRiskRatio
        }
        var findings: [Finding] = []
        if !risky.isEmpty {
            findings.append(Finding(
                severity: .risk,
                title: "Knees caving in hard",
                detail: "Strong knee valgus on \(repList(risky)). This loads the knee ligaments — stop the set when it appears. Cue: push the knees out over the toes (“spread the floor”), and consider lighter weight.",
                repNumbers: risky.map(\.repNumber),
                topic: .kneeValgus
            ))
        }
        if !caving.isEmpty {
            findings.append(Finding(
                severity: .warning,
                title: "Knees drifting inward",
                detail: "Some knee valgus on \(repList(caving)), usually on the way up. Cue: screw your feet into the floor and drive the knees out as you stand.",
                repNumbers: caving.map(\.repNumber),
                topic: .kneeValgus
            ))
        }
        return findings
    }

    private static func torsoFindings(_ reps: [RepMetrics]) -> [Finding] {
        let risky = reps.filter { $0.torsoLeanDegrees >= AnalysisTuning.torsoLeanRiskDegrees }
        let leaning = reps.filter {
            $0.torsoLeanDegrees >= AnalysisTuning.torsoLeanWarningDegrees
                && $0.torsoLeanDegrees < AnalysisTuning.torsoLeanRiskDegrees
        }
        var findings: [Finding] = []
        if !risky.isEmpty {
            findings.append(Finding(
                severity: .risk,
                title: "Torso folding forward",
                detail: "Very strong forward lean on \(repList(risky)) — this shifts load to the lower back. Brace your core before descending and keep your chest up; if it persists, drop the weight.",
                repNumbers: risky.map(\.repNumber),
                topic: .torsoLean
            ))
        }
        if !leaning.isEmpty {
            findings.append(Finding(
                severity: .warning,
                title: "Excessive forward lean",
                detail: "Noticeable forward lean at the bottom on \(repList(leaning)). The standard is a near-vertical torso: big breath into the belly, brace, elbows down, and let the knees travel forward over the toes instead of hinging at the hips. Limited ankle mobility also causes this — heel wedges or lifting shoes help.",
                repNumbers: leaning.map(\.repNumber),
                topic: .torsoLean
            ))
        }
        return findings
    }

    /// Chinese practice: the elbows stay down under the bar, pointing at the
    /// floor — they pin the bar to the back and keep the upper back tight.
    /// Elbows swinging up/back let the bar roll and tip the chest forward.
    private static func elbowLiftFindings(_ reps: [RepMetrics]) -> [Finding] {
        let risky = reps.filter {
            ($0.elbowLiftDegrees ?? 0) >= AnalysisTuning.elbowLiftRiskDegrees
        }
        let lifting = reps.filter {
            let lift = $0.elbowLiftDegrees ?? 0
            return lift >= AnalysisTuning.elbowLiftWarningDegrees
                && lift < AnalysisTuning.elbowLiftRiskDegrees
        }
        var findings: [Finding] = []
        if !risky.isEmpty {
            findings.append(Finding(
                severity: .risk,
                title: "Elbows swinging up",
                detail: "The upper arms swung near horizontal at the bottom on \(repList(risky)) — the bar rolls, the chest drops, and the wrists take the load. Point the elbows at the floor and pull them under the bar before you descend; if the grip won't allow it, widen the hands slightly.",
                repNumbers: risky.map(\.repNumber),
                topic: .elbowsDown
            ))
        }
        if !lifting.isEmpty {
            findings.append(Finding(
                severity: .warning,
                title: "Elbows creeping up",
                detail: "Elbow lift rising at the bottom on \(repList(lifting)). The standard is elbows down under the bar — it locks the lats and upper back so the chest stays up. Cue: squeeze the bar into the traps and point the elbows at the floor.",
                repNumbers: lifting.map(\.repNumber),
                topic: .elbowsDown
            ))
        }
        return findings
    }

    /// The bar (shoulder center in high-bar) stays stacked over the midfoot;
    /// horizontal offset at the bottom is load on the lower back as shear.
    private static func balanceFindings(_ reps: [RepMetrics]) -> [Finding] {
        let drifting = reps.filter {
            ($0.balanceDriftRatio ?? 0) >= AnalysisTuning.balanceDriftWarningRatio
        }
        guard !drifting.isEmpty else { return [] }
        return [Finding(
            severity: .warning,
            title: "Bar off the midfoot",
            detail: "The bar sat well off the midfoot line at the bottom on \(repList(drifting)) — every centimeter of horizontal offset is a moment arm the lower back has to hold. Keep the bar stacked over the middle of the foot: push the floor straight down and let the knees travel forward instead of tipping the chest.",
            repNumbers: drifting.map(\.repNumber),
            topic: .barOverMidfoot
        )]
    }

    private static func tempoFindings(_ reps: [RepMetrics]) -> [Finding] {
        var findings: [Finding] = []
        let rushed = reps.filter { $0.eccentricSeconds < AnalysisTuning.minimumEccentricSeconds }
        if !rushed.isEmpty {
            findings.append(Finding(
                severity: .warning,
                title: "Dropping too fast",
                detail: "Free-fall descent on \(repList(rushed)). A rebound out of the bottom is good technique, but it has to come off a controlled 1–2 s descent — stay tight on the way down so the bounce comes from position, not from falling.",
                repNumbers: rushed.map(\.repNumber),
                topic: .controlDescent
            ))
        }
        let grinding = reps.filter { $0.concentricSeconds > AnalysisTuning.slowConcentricSeconds }
        if !grinding.isEmpty {
            findings.append(Finding(
                severity: .info,
                title: "Grinding ascent",
                detail: "Slow ascent on \(repList(grinding)). Heavy strength work can grind, but if you're training technique, keep reps crisp out of the bottom — when every rep slows to a grind, the load is too heavy for that.",
                repNumbers: grinding.map(\.repNumber)
            ))
        }
        return findings
    }

    private static func asymmetryFindings(_ reps: [RepMetrics]) -> [Finding] {
        let uneven = reps.filter { $0.asymmetryDegrees >= AnalysisTuning.asymmetryWarningDegrees }
        guard uneven.count > reps.count / 3 else { return [] }
        return [Finding(
            severity: .warning,
            title: "Uneven left/right",
            detail: "One knee bends noticeably more than the other on \(repList(uneven)) — often a weight shift to the stronger leg. Film from the front occasionally and check foot pressure stays even.",
            repNumbers: uneven.map(\.repNumber)
        )]
    }

    private static func stanceFindings(_ reps: [RepMetrics]) -> [Finding] {
        let narrow = reps.filter { ($0.stanceWidthRatio ?? 1) < AnalysisTuning.stanceNarrowRatio }
        let wide = reps.filter { ($0.stanceWidthRatio ?? 1) > AnalysisTuning.stanceWideRatio }
        var findings: [Finding] = []
        if !narrow.isEmpty {
            findings.append(Finding(
                severity: narrow.count > reps.count / 2 ? .warning : .info,
                title: "Stance too narrow",
                detail: "Your feet were inside hip width on \(repList(narrow)). Set the heels about shoulder-width apart with the toes turned out ~30° so the hips have room to sit down between the legs.",
                repNumbers: narrow.map(\.repNumber),
                topic: .stanceWidth
            ))
        }
        if !wide.isEmpty {
            findings.append(Finding(
                severity: wide.count > reps.count / 2 ? .warning : .info,
                title: "Stance very wide",
                detail: "Your feet were well outside shoulder width on \(repList(wide)). The high-bar standard is heels around shoulder width — a wide stance turns the squat into a hip hinge and limits upright depth.",
                repNumbers: wide.map(\.repNumber),
                topic: .stanceWidth
            ))
        }
        return findings
    }

    private static func bottomStabilityFindings(_ reps: [RepMetrics]) -> [Finding] {
        let wobbly = reps.filter {
            ($0.bottomHipShiftRatio ?? 0) >= AnalysisTuning.bottomShiftWarningRatio
        }
        guard !wobbly.isEmpty else { return [] }
        return [Finding(
            severity: .warning,
            title: "Hips shifting at the bottom",
            detail: "The pelvis wandered instead of holding still at the bottom on \(repList(wobbly)). The bottom position should be a held, braced posture: hips centered between the feet, no wiggling or rocking to find a rebound — that instability under load falls on the lower back.",
            repNumbers: wobbly.map(\.repNumber)
        )]
    }

    private static func lockoutFindings(_ reps: [RepMetrics]) -> [Finding] {
        let cut = reps.filter { ($0.lockoutKneeDegrees ?? 180) < AnalysisTuning.lockoutKneeDegrees }
        guard !cut.isEmpty else { return [] }
        return [Finding(
            severity: .warning,
            title: "Not standing up fully",
            detail: "You started the next descent before reaching lockout on \(repList(cut)). Finish every rep standing tall — knees and hips fully extended, one breath — before going down again; cutting the top shortens the rep and hides fatigue.",
            repNumbers: cut.map(\.repNumber),
            topic: .squatLockout
        )]
    }

    private static func fatigueFindings(_ reps: [RepMetrics]) -> [Finding] {
        guard reps.count >= 3, let first = reps.first, let last = reps.last,
              first.depthFraction > 0 else { return [] }
        let loss = (first.depthFraction - last.depthFraction) / first.depthFraction
        guard loss >= AnalysisTuning.fatigueDepthLossFraction else { return [] }
        return [Finding(
            severity: .info,
            title: "Depth fading late in the set",
            detail: "Your last reps were noticeably shallower than your first — a normal fatigue sign. When depth starts fading, that's a good point to rack it, especially when training alone.",
            repNumbers: [last.repNumber]
        )]
    }

    private static func repList(_ reps: [RepMetrics]) -> String {
        let numbers = reps.map { "\($0.repNumber)" }.joined(separator: ", ")
        return reps.count == 1 ? "rep \(numbers)" : "reps \(numbers)"
    }
}
