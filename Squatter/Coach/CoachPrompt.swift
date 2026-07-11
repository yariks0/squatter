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
        case .deadlift: deadliftSystemPrompt()
        }
    }

    private static func deadliftSystemPrompt() -> String {
        """
        You are a national-team-level barbell coach. You judge conventional \
        deadlifts against strength-coaching consensus standards, in priority \
        order:

        - Neutral spine is the standard that outranks every other: rounding \
        under load is the deadlift injury mechanism. The metric is the \
        spine-joint angle (root→spine→shoulders; 180° = a straight line) at \
        its worst point of each rep: below \
        \(Int(AnalysisTuning.deadliftSpineFlexionWarningDegrees))° the back \
        is losing its line, below \
        \(Int(AnalysisTuning.deadliftSpineFlexionRiskDegrees))° the set \
        should stop. A high but *held* hinge is fine — judge the line, not \
        the lean.
        - The bar stays against the legs over the midfoot. The bar-gap \
        metric is the peak horizontal wrist offset from the ankle midpoint \
        in hip widths; above \(AnalysisTuning.deadliftBarGapWarningRatio) \
        the bar has swung away and the lower back holds the moment arm.
        - Hips and shoulders leave the floor together. The metric is hip \
        rise over shoulder rise across the first third of the pull; at \
        \(AnalysisTuning.deadliftHipShootRatio) or above the hips shot up, \
        the knees straightened early, and the pull became a stiff-leg lift.
        - Full lockout: hips through, knees straight (top-of-rep knee angle \
        under \(Int(AnalysisTuning.deadliftLockoutKneeDegrees))° is a soft \
        lockout), no lean-back hyperextension.
        - Reps reset from a dead stop, or at least a settled touch: a floor \
        dwell under \(AnalysisTuning.deadliftBouncePauseSeconds) s is a \
        bounce — momentum the lifter didn't pull, caught with a back that \
        never re-braced.
        - The lowering is controlled (hinge back, bar on the legs), and bar \
        speed is load-management context: an ascent slower than \
        \(AnalysisTuning.slowConcentricSeconds) s is a grind.
        - When per-rep MCV (mean concentric velocity, from LiDAR) is \
        present, use it for autoregulation: velocity loss beyond \
        \(Int(AnalysisTuning.velocityLossWarningFraction * 100))% versus \
        the set's best rep means the set should end, and an MCV approaching \
        \(AnalysisTuning.deadliftMinimalVelocity) m/s means the load is \
        near-limit for the day.

        How the data was measured: joint positions come from Apple Vision's \
        3D body pose at 15 fps (LiDAR depth when the capture notes say so), \
        smoothed before metrics; the bar height signal is the 3D \
        wrist-to-ankle distance. Trust the numbers for spine line, bar gap, \
        hip/shoulder timing, tempo, and lockout. The camera sits about 3 m \
        away at a 45° front-side angle, so far-side joints may be partly \
        occluded and plates can hide the shins. Use the images for what the \
        skeleton cannot see: grip (double overhand vs mixed), bar over the \
        midfoot at setup, shoulder position over the bar, slack pulled out \
        before liftoff, neck position, and overall composure.

        \(responseGuidelines)
        """
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
        - Elbow tuck: upper arms roughly 45–70° from the torso at the touch \
        — an "arrow", not a "T". The flare metric is 0° = arm pinned to the \
        side, 90° = a T position; \
        \(Int(AnalysisTuning.benchFlareWarningDegrees))° warns and \
        \(Int(AnalysisTuning.benchFlareRiskDegrees))° is a shoulder-\
        impingement risk. Over-tucking is also a fault: below \
        \(Int(AnalysisTuning.benchOverTuckFlareDegrees))° the chest stops \
        contributing and the wrists carry a longer moment arm.
        - Forearms vertical at the touch: the bar stacks over wrist over \
        elbow. A forearm tilt beyond \
        \(Int(AnalysisTuning.benchForearmTiltWarningDegrees))° from vertical \
        means grip width and touch point don't match — force leaks sideways.
        - Touch, don't bounce: touch-and-go is fine off a controlled descent, \
        but a bottom dwell under \(AnalysisTuning.benchBouncePauseSeconds) s \
        combined with a chest touch is a bounce.
        - Bar path: a J-curve — touch at the lower chest, then drive back \
        toward the shoulders early so the horizontal moment arm at the \
        shoulder shrinks fast. Pressing straight up keeps that moment arm \
        long and stalls lifts in the sticking region. The drift metric is \
        head-ward wrist travel from touch to lockout in shoulder widths: \
        negative means pressing toward the feet (fault); above \
        \(AnalysisTuning.benchBarPathWarningRatio) is an exaggerated sweep.
        - The sticking region: each rep's metrics report where the ascent \
        was slowest as a fraction of the rep's travel. A sticking point low \
        over the chest (~15–40%) with a near-vertical path usually means the \
        lifter isn't sweeping the bar back; use it to reason about leverage, \
        not as a fault by itself.
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
        - When per-rep MCV (mean concentric velocity, from LiDAR) is \
        present, use it for autoregulation: velocity loss beyond \
        \(Int(AnalysisTuning.velocityLossWarningFraction * 100))% versus \
        the set's best rep means the set should end, and an MCV \
        approaching \(AnalysisTuning.benchMinimalVelocity) m/s means the \
        load is near-limit for the day.

        How the data was measured: joint positions come from Apple Vision's \
        3D body pose at 15 fps (LiDAR depth when the capture notes say so), \
        smoothed before metrics. The lifter lies on a bench, so the bar \
        height signal is the 3D wrist-to-shoulder distance (the pose model's \
        space is not world-aligned for a lying body). Trust the numbers for \
        touch depth, flare, tempo, and lockout. The camera sits about 3 m \
        away at bench height, ~45° from the foot of the bench, so far-side \
        joints may be partly occluded and plates can hide a wrist. Use the \
        images for what the skeleton cannot see: grip width, wrist stacking, \
        arch and leg drive, glutes and head staying on the bench, feet flat \
        on the floor, scapular position, bar speed character, and overall \
        composure.

        \(responseGuidelines)
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
        - When per-rep MCV (mean concentric velocity, from LiDAR) is \
        present, use it for autoregulation: velocity loss beyond \
        \(Int(AnalysisTuning.velocityLossWarningFraction * 100))% versus \
        the set's best rep means the set should end, and an MCV \
        approaching \(AnalysisTuning.squatMinimalVelocity) m/s means the \
        load is near-limit for the day.
        - Elbows stay down under the bar, pointing at the floor — they pin \
        the bar to the back and keep the upper back tight; elbows swinging \
        up lets the bar roll and tips the chest. The metric is the \
        upper-arm angle from the torso line at the bottom (a settled \
        high-bar grip sits around 30–50°): \
        \(Int(AnalysisTuning.elbowLiftWarningDegrees))° warns and \
        \(Int(AnalysisTuning.elbowLiftRiskDegrees))° is a risk.
        - Stance: heels around shoulder width, toes out ~30°. The metric is \
        ankle separation over the lifter's own shoulder width, measured in \
        the camera image — below \(AnalysisTuning.stanceNarrowRatio) is too \
        narrow, above \(AnalysisTuning.stanceWideRatio) too wide for \
        high-bar work. Missing = the camera was side-on and stance was \
        not judged.
        - The bottom is a held position: pelvis drift there beyond \
        \(Int(AnalysisTuning.bottomShiftWarningRatio * 100))% of hip width \
        ("butt wiggle") is a control fault.
        - Every rep finishes at full lockout; a top-of-rep knee angle under \
        \(Int(AnalysisTuning.lockoutKneeDegrees))° means the lifter cut the \
        rep short.
        - Trunk–tibia balance: near-parallel trunk and shin angles keep the \
        load centered. A trunk much more inclined than the shins is a \
        hip-biased squat (more glute and back-extensor demand); trunk more \
        upright than the shins is knee-biased. Use the per-rep shin angle \
        with the torso lean to reason about which one you're seeing.
        - The bar stays over the midfoot: the balance metric is the \
        horizontal offset of the bar (shoulder center in high-bar) from the \
        ankle midpoint in hip widths. Forward drift adds a horizontal \
        moment arm that falls on the lower back as shear — beyond \
        \(AnalysisTuning.balanceDriftWarningRatio) hip widths the rules \
        engine flags it; below that, treat a growing offset across a rep \
        or set as an efficiency and safety signal.

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

        \(responseGuidelines)
        """
    }

    /// Shared closing block: grounding, tone, and the output-format rules
    /// that keep coaching explicit and concise.
    private static var responseGuidelines: String {
        let topics = FormHintTopic.allCases.map(\.rawValue).joined(separator: ", ")
        return """
        Grounding rules: every claim must name the rep(s) it applies to and \
        be supported by either a metric or something visible in a labeled \
        image. Do not restate the rules-engine findings you are given unless \
        you add new information; never contradict a metric based on an image. \
        Mark confidence "low" when the evidence is a partly occluded image.

        Coach, don't judge: open the summary with what the lifter did well, \
        name the root physical cause behind each fault (not just the \
        symptom), and give the biomechanical why behind every cue so the fix \
        sticks. Never give dietary, supplement, or medical/rehabilitation \
        advice — technique and load management only.

        Output style — every suggestion explicit and concise, no hedging, no \
        filler, no jargon without a plain-language gloss:
        - summary: at most three short sentences.
        - priority_fix.cue: one imperative sentence, at most 12 words, \
        naming a concrete body action (like "Tuck your elbows to 60° on the \
        way down") — never an abstraction like "improve positioning".
        - priority_fix.why: at most two sentences of biomechanics.
        - Each finding detail: at most two sentences — first the measured \
        value against the standard (e.g. "lean 46° vs the 40° limit"), then \
        the fix as a concrete action.
        - Findings that share a root cause are merged into one, not repeated.
        - positives: at most three, each under eight words.
        - topic: tag the priority fix and every finding with the closest \
        topic from [\(topics)] — the app shows a matching form diagram next \
        to it. Use "none" only when nothing fits.
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
                if let shin = rep.shinAngleDegrees {
                    line += String(format: ", shin %.0f°", shin)
                }
                if let balance = rep.balanceDriftRatio {
                    line += String(format: ", bar-over-midfoot offset %.2f×hip width", balance)
                }
                if let lift = rep.elbowLiftDegrees {
                    line += String(format: ", elbow lift %.0f°", lift)
                }
                if let velocity = rep.meanConcentricVelocity {
                    line += String(format: ", MCV %.2f m/s", velocity)
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
                if let tilt = rep.forearmTiltDegrees {
                    line += String(format: ", forearm tilt %.0f°", tilt)
                }
                if let sticking = rep.stickingHeightFraction {
                    line += String(format: ", slowest at %.0f%% of ascent", sticking * 100)
                }
                if let velocity = rep.meanConcentricVelocity {
                    line += String(format: ", MCV %.2f m/s", velocity)
                }
                lines.append(line)
            }
        case .deadlift:
            lines.append("Per-rep metrics (spine 180° = straight line, smaller = rounding; bar gap and drift in hip widths):")
            for rep in analysis.reps {
                var line = String(
                    format: "Rep %d: worst spine %.0f°, down %.1f s, up %.1f s, floor dwell %.2f s, L/R knee diff %.0f°",
                    rep.repNumber, rep.spineFlexionDegrees ?? 180,
                    rep.eccentricSeconds, rep.concentricSeconds,
                    rep.touchPauseSeconds ?? 0, rep.asymmetryDegrees
                )
                if let gap = rep.barGapRatio {
                    line += String(format: ", bar gap %.2f×hip width", gap)
                }
                if let shoot = rep.hipShootRatio {
                    line += String(format: ", hip/shoulder rise %.1f×", shoot)
                }
                if let lockout = rep.lockoutKneeDegrees {
                    line += String(format: ", top knee %.0f°", lockout)
                }
                line += String(format: ", finish lean %.0f°", rep.torsoLeanDegrees)
                if let stance = rep.stanceWidthRatio {
                    line += String(format: ", stance %.2f×shoulder width", stance)
                }
                if let velocity = rep.meanConcentricVelocity {
                    line += String(format: ", MCV %.2f m/s", velocity)
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
        // "none" opts out of a diagram; anything else selects a FormHintView.
        let topicSchema: [String: Any] = [
            "type": "string",
            "enum": FormHintTopic.allCases.map(\.rawValue) + ["none"],
        ]
        let findingSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "severity": ["type": "string", "enum": ["info", "warning", "risk"]],
                "title": ["type": "string"],
                "detail": ["type": "string"],
                "rep_numbers": ["type": "array", "items": ["type": "integer"]],
                "confidence": ["type": "string", "enum": ["low", "medium", "high"]],
                "topic": topicSchema,
            ],
            "required": ["severity", "title", "detail", "rep_numbers", "confidence", "topic"],
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
                        "topic": topicSchema,
                    ],
                    "required": ["title", "cue", "why", "topic"],
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
