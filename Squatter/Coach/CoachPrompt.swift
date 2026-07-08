import Foundation

/// Builds the Messages API prompt for LLM coaching. The harness packs
/// everything the pipeline knows — standards with the live `AnalysisTuning`
/// thresholds, measurement provenance, per-rep metrics, the deterministic
/// findings, and labeled keyframes — so the model adds judgment on top of the
/// geometry instead of re-guessing it.
enum CoachPrompt {
    struct Keyframe: Sendable {
        var label: String
        var jpegData: Data
    }

    static func systemPrompt(activity: ActivityType = .squat) -> String {
        switch activity {
        case .squat: squatSystemPrompt()
        case .benchPress: benchSystemPrompt()
        }
    }

    private static func benchSystemPrompt() -> String {
        """
        You are a national-team-level barbell coach. You judge the bench \
        press against strength-coaching consensus standards:

        - Full range: the bar touches the lower chest on every rep with the \
        forearms vertical. In this app's convention an average elbow angle at \
        the touch of \(Int(AnalysisTuning.benchFullTouchElbowDegrees))° or \
        less counts as a chest touch; above \
        \(Int(AnalysisTuning.benchShallowElbowDegrees))° the rep was cut high.
        - Elbow tuck: upper arms roughly 45–70° from the torso at the touch. \
        The flare metric is 0° = arm pinned to the side, 90° = a T position; \
        \(Int(AnalysisTuning.benchFlareWarningDegrees))° warns and \
        \(Int(AnalysisTuning.benchFlareRiskDegrees))° is a shoulder-\
        impingement risk.
        - Touch, don't bounce: touch-and-go is fine off a controlled descent, \
        but a bottom dwell under \(AnalysisTuning.benchBouncePauseSeconds) s \
        combined with a chest touch is a bounce.
        - Bar path: a J-curve — touch at the lower chest, lock out stacked \
        over the shoulders. The drift metric is head-ward wrist travel from \
        touch to lockout in shoulder widths: negative means pressing toward \
        the feet (fault); above \(AnalysisTuning.benchBarPathWarningRatio) is \
        an exaggerated sweep.
        - Consistent touch point: per-rep touch offsets spread over more than \
        \(AnalysisTuning.benchTouchSpreadWarningRatio) shoulder widths means \
        the groove is wandering.
        - Full lockout every rep: an average top-of-rep elbow angle under \
        \(Int(AnalysisTuning.benchLockoutElbowDegrees))° means the press \
        stopped short.
        - The descent is controlled (~1–2 s); under \
        \(AnalysisTuning.minimumEccentricSeconds) s is a drop. An ascent \
        slower than \(AnalysisTuning.slowConcentricSeconds) s is a grind — \
        normal for heavy strength work, a load-management flag for technique \
        sets.

        How the data was measured: joint positions come from Apple Vision's \
        3D body pose at 15 fps (LiDAR depth when the capture notes say so), \
        smoothed before metrics. The lifter lies on a bench, so the press \
        axis is world-up and the bar height signal is the wrist midpoint \
        above the shoulder midpoint. Trust the numbers for touch depth, \
        flare, tempo, and lockout. The camera sits about 3 m away at bench \
        height, ~45° from the foot of the bench, so far-side joints may be \
        partly occluded and plates can hide a wrist. Use the images for what \
        the skeleton cannot see: grip width, wrist stacking, arch and leg \
        drive, scapular position, bar speed character, and overall composure.

        Grounding rules: every claim must name the rep(s) it applies to and \
        be supported by either a metric or something visible in a labeled \
        image. Do not restate the rules-engine findings you are given unless \
        you add new information; never contradict a metric based on an image. \
        Mark confidence "low" when the evidence is a partly occluded image. \
        Write for the lifter: short, direct, one cue at a time, no jargon \
        without explanation.
        """
    }

    private static func squatSystemPrompt() -> String {
        """
        You are a national-team-level barbell coach. You judge back squats \
        strictly against Chinese weightlifting team (high-bar) practice:

        - Full depth: sit fully down between the legs, hip crease well below \
        the knee. In this app's convention that is a femur angle of at least \
        \(Int(AnalysisTuning.fullDepthDegrees))° below horizontal at the bottom; \
        between \(Int(AnalysisTuning.parallelToleranceDegrees))° and \
        \(Int(AnalysisTuning.fullDepthDegrees))° counts as roughly parallel.
        - Torso stays close to vertical — this is the primary standard; \
        Chinese coaches treat a held trunk position as the first priority. \
        Big breath into the belly, brace, elbows down. A deep upright bottom \
        position sits around 25–35° of trunk lean; \
        \(Int(AnalysisTuning.torsoLeanWarningDegrees))° is a warning and \
        \(Int(AnalysisTuning.torsoLeanRiskDegrees))° is a risk.
        - Knees travel forward over the toes — that is correct technique, not \
        a fault — and ideally track over the toes. Chinese coaches tolerate \
        minor knee drift as long as the torso holds, but this app flags \
        valgus for injury prevention: medial deviation of \
        \(Int(AnalysisTuning.valgusWarningRatio * 100))% of hip width warns; \
        \(Int(AnalysisTuning.valgusRiskRatio * 100))% is a risk.
        - The descent is controlled (~1–2 s). An elastic rebound out of the \
        bottom is good technique when positions hold; a descent under \
        \(AnalysisTuning.minimumEccentricSeconds) s is a free fall.
        - Bar speed is load-management context, not a fault: an ascent slower \
        than \(AnalysisTuning.slowConcentricSeconds) s is a grind. Grinding \
        is normal in dedicated heavy strength work; for technique-focused \
        sets it means the load is too heavy.
        - Stance: heels around shoulder width, toes out ~30°. The metric is \
        ankle separation over shoulder width — below \
        \(AnalysisTuning.stanceNarrowRatio) is too narrow, above \
        \(AnalysisTuning.stanceWideRatio) too wide for high-bar work.
        - The bottom is a held position: pelvis drift there beyond \
        \(Int(AnalysisTuning.bottomShiftWarningRatio * 100))% of hip width \
        ("butt wiggle") is a control fault.
        - Every rep finishes at full lockout; a top-of-rep knee angle under \
        \(Int(AnalysisTuning.lockoutKneeDegrees))° means the lifter cut the \
        rep short.

        How the data was measured: joint positions come from Apple Vision's \
        3D body pose at 15 fps (LiDAR depth when the capture notes say so), \
        smoothed before metrics. Angles in the metrics are computed from that \
        3D skeleton and are more precise than what you can estimate from \
        pixels — trust the numbers for depth, lean, valgus, and tempo. The \
        camera sits roughly 3 m away at a 45° front-side angle, so far-side \
        joints in the images may be partly occluded. Use the images for what \
        the skeleton cannot see: bar position on the back, grip and elbow \
        position, foot stance and pressure, weight shift, bar path drift, \
        head position, and overall composure.

        Grounding rules: every claim must name the rep(s) it applies to and \
        be supported by either a metric or something visible in a labeled \
        image. Do not restate the rules-engine findings you are given unless \
        you add new information; never contradict a metric based on an image. \
        Mark confidence "low" when the evidence is a partly occluded image. \
        Write for the lifter: short, direct, one cue at a time, no jargon \
        without explanation.
        """
    }

    /// User-turn content blocks: set context and metrics first, then each
    /// keyframe preceded by its label, then the ask.
    static func userContent(analysis: SquatAnalysis, keyframes: [Keyframe]) -> [[String: Any]] {
        var blocks: [[String: Any]] = [["type": "text", "text": setContext(analysis)]]
        for keyframe in keyframes {
            blocks.append(["type": "text", "text": keyframe.label])
            blocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": keyframe.jpegData.base64EncodedString(),
                ],
            ])
        }
        blocks.append(["type": "text", "text": """
            Assess this set against the standard above. Give the single \
            highest-value fix for the next set, any findings the rules engine \
            missed or under/over-called, and what the lifter should keep doing.
            """])
        return blocks
    }

    private static func setContext(_ analysis: SquatAnalysis) -> String {
        var lines: [String] = []
        lines.append("Set: \(analysis.kind.displayName), \(analysis.reps.count) reps, score \(analysis.score)/100.")
        lines.append(analysis.usedDepth
            ? "Capture: LiDAR depth fused with video (metric-scale skeleton)."
            : "Capture: video only (skeleton scale estimated).")
        if let height = analysis.bodyHeight {
            lines.append(String(format: "Estimated body height: %.2f m.", height))
        }
        lines.append("")
        switch analysis.kind {
        case .squat:
            lines.append("Per-rep metrics (femur angle positive = hip below knee):")
            for rep in analysis.reps {
                var line = String(
                    format: "Rep %d: femur %+.0f°, torso lean %.0f°, valgus %.2f×hip width, down %.1f s, up %.1f s, L/R knee diff %.0f°",
                    rep.repNumber, rep.hipBelowKneeDegrees, rep.torsoLeanDegrees,
                    rep.kneeValgusRatio, rep.eccentricSeconds, rep.concentricSeconds,
                    rep.asymmetryDegrees
                )
                if let stance = rep.stanceWidthRatio {
                    line += String(format: ", stance %.2f×shoulder width", stance)
                }
                if let shift = rep.bottomHipShiftRatio {
                    line += String(format: ", bottom pelvis drift %.2f×hip width", shift)
                }
                if let lockout = rep.lockoutKneeDegrees {
                    line += String(format: ", top knee %.0f°", lockout)
                }
                lines.append(line)
            }
        case .benchPress:
            lines.append("Per-rep metrics (elbow 180° = straight; flare 0° = arm at the side; drift positive = head-ward):")
            for rep in analysis.reps {
                var line = String(
                    format: "Rep %d: touch elbow %.0f°, flare %.0f°, down %.1f s, up %.1f s, touch pause %.2f s, L/R elbow diff %.0f°",
                    rep.repNumber, rep.elbowFlexionDegrees ?? 180,
                    rep.elbowFlareDegrees ?? 0, rep.eccentricSeconds,
                    rep.concentricSeconds, rep.touchPauseSeconds ?? 0,
                    rep.asymmetryDegrees
                )
                if let lockout = rep.lockoutElbowDegrees {
                    line += String(format: ", top elbow %.0f°", lockout)
                }
                if let drift = rep.barPathDriftRatio {
                    line += String(format: ", path drift %+.2f×shoulder width", drift)
                }
                if let touch = rep.touchOffsetRatio {
                    line += String(format: ", touch offset %+.2f×shoulder width", touch)
                }
                lines.append(line)
            }
        }
        lines.append("")
        lines.append("Rules-engine findings already shown to the lifter:")
        for finding in analysis.findings {
            let reps = finding.repNumbers.isEmpty
                ? "whole set" : "reps \(finding.repNumbers.map(String.init).joined(separator: ","))"
            lines.append("- [\(finding.severity.rawValue)] \(finding.title) (\(reps)): \(finding.detail)")
        }
        return lines.joined(separator: "\n")
    }

    /// JSON schema for `output_config.format` — must mirror `CoachReport`.
    static var outputSchema: [String: Any] {
        let findingSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "severity": ["type": "string", "enum": ["info", "warning", "risk"]],
                "title": ["type": "string"],
                "detail": ["type": "string"],
                "rep_numbers": ["type": "array", "items": ["type": "integer"]],
                "confidence": ["type": "string", "enum": ["low", "medium", "high"]],
            ],
            "required": ["severity", "title", "detail", "rep_numbers", "confidence"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "priority_fix": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "cue": ["type": "string"],
                        "why": ["type": "string"],
                    ],
                    "required": ["title", "cue", "why"],
                    "additionalProperties": false,
                ],
                "findings": ["type": "array", "items": findingSchema],
                "positives": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["summary", "priority_fix", "findings", "positives"],
            "additionalProperties": false,
        ]
    }
}
