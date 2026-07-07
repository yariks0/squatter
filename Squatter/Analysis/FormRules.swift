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
}

/// Deterministic mapping from per-rep metrics to coaching findings.
/// Thresholds live in `AnalysisTuning`.
enum FormRules {
    static func findings(for reps: [RepMetrics]) -> [Finding] {
        guard !reps.isEmpty else {
            return [Finding(
                severity: .info,
                title: "No reps detected",
                detail: "Make sure your whole body stays in frame for the full set, with the phone about 3 m away at a 45° front-side angle.",
                repNumbers: []
            )]
        }
        var findings: [Finding] = []
        findings.append(contentsOf: depthFindings(reps))
        findings.append(contentsOf: valgusFindings(reps))
        findings.append(contentsOf: torsoFindings(reps))
        findings.append(contentsOf: tempoFindings(reps))
        findings.append(contentsOf: asymmetryFindings(reps))
        findings.append(contentsOf: stanceFindings(reps))
        findings.append(contentsOf: bottomStabilityFindings(reps))
        findings.append(contentsOf: lockoutFindings(reps))
        findings.append(contentsOf: fatigueFindings(reps))
        return findings.sorted { $0.severity > $1.severity }
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
                repNumbers: atParallel.map(\.repNumber)
            ))
        }
        if !shallow.isEmpty {
            findings.append(Finding(
                severity: shallow.count > reps.count / 2 ? .warning : .info,
                title: "Shallow depth",
                detail: "Hips stayed above parallel on \(repList(shallow)). Aim to sit fully down between your legs with the torso upright; if mobility is the limit, elevate your heels and go only as deep as you can with a neutral back.",
                repNumbers: shallow.map(\.repNumber)
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
                repNumbers: risky.map(\.repNumber)
            ))
        }
        if !caving.isEmpty {
            findings.append(Finding(
                severity: .warning,
                title: "Knees drifting inward",
                detail: "Some knee valgus on \(repList(caving)), usually on the way up. Cue: screw your feet into the floor and drive the knees out as you stand.",
                repNumbers: caving.map(\.repNumber)
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
                repNumbers: risky.map(\.repNumber)
            ))
        }
        if !leaning.isEmpty {
            findings.append(Finding(
                severity: .warning,
                title: "Excessive forward lean",
                detail: "Noticeable forward lean at the bottom on \(repList(leaning)). The standard is a near-vertical torso: big breath into the belly, brace, elbows down, and let the knees travel forward over the toes instead of hinging at the hips. Limited ankle mobility also causes this — heel wedges or lifting shoes help.",
                repNumbers: leaning.map(\.repNumber)
            ))
        }
        return findings
    }

    private static func tempoFindings(_ reps: [RepMetrics]) -> [Finding] {
        var findings: [Finding] = []
        let rushed = reps.filter { $0.eccentricSeconds < AnalysisTuning.minimumEccentricSeconds }
        if !rushed.isEmpty {
            findings.append(Finding(
                severity: .warning,
                title: "Dropping too fast",
                detail: "Free-fall descent on \(repList(rushed)). A rebound out of the bottom is good technique, but it has to come off a controlled 1–2 s descent — stay tight on the way down so the bounce comes from position, not from falling.",
                repNumbers: rushed.map(\.repNumber)
            ))
        }
        let grinding = reps.filter { $0.concentricSeconds > AnalysisTuning.slowConcentricSeconds }
        if !grinding.isEmpty {
            findings.append(Finding(
                severity: .info,
                title: "Grinding ascent",
                detail: "Slow stand-up on \(repList(grinding)). Heavy strength work can grind, but if you're training technique, keep reps crisp out of the bottom — when every rep slows to a grind, the load is too heavy for that.",
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
                repNumbers: narrow.map(\.repNumber)
            ))
        }
        if !wide.isEmpty {
            findings.append(Finding(
                severity: wide.count > reps.count / 2 ? .warning : .info,
                title: "Stance very wide",
                detail: "Your feet were well outside shoulder width on \(repList(wide)). The high-bar standard is heels around shoulder width — a wide stance turns the squat into a hip hinge and limits upright depth.",
                repNumbers: wide.map(\.repNumber)
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
            repNumbers: cut.map(\.repNumber)
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
