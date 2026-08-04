import CoreGraphics
import Foundation
import Testing
@testable import Squatter

struct CoachPromptTests {
    private func keyframe(
        rep: Int, phase: KeyframePlanner.Phase = .bottom, time: TimeInterval = 1.2,
        isOverlay: Bool = false
    ) -> CoachKeyframe {
        CoachKeyframe(
            repNumber: rep, phase: phase, time: time,
            pixelSize: CGSize(width: 576, height: 1024), isOverlay: isOverlay,
            jointPixels: [(joint: .leftKnee, point: CGPoint(x: 213, y: 641))],
            uncertainJoints: isOverlay
                ? [(joint: .leftAnkle, reason: "position repaired, not detected")] : [],
            jpegData: Data([0xFF])
        )
    }

    @Test func systemPromptEmbedsLiveThresholds() {
        let prompt = CoachPrompt.systemPrompt()
        #expect(prompt.contains("\(Int(AnalysisTuning.fullDepthDegrees))°"))
        #expect(prompt.contains("\(Int(AnalysisTuning.torsoLeanWarningDegrees))°"))
        #expect(prompt.contains("\(Int(AnalysisTuning.valgusRiskRatio * 100))%"))
        #expect(prompt.contains("\(AnalysisTuning.slowConcentricSeconds)"))
    }

    /// The prompt now carries two missions: coaching and skeleton-vs-footage
    /// verification. The old blanket "never contradict a metric" rule is gone
    /// — a verified mismatch is exactly the case where the image wins.
    @Test func systemPromptCarriesVerificationMission() {
        for activity in ActivityType.allCases {
            let prompt = CoachPrompt.systemPrompt(activity: activity)
            #expect(prompt.contains("Mission 2 — tracking verification"))
            #expect(prompt.contains("SKELETON OVERLAY"))
            #expect(prompt.contains("mismatch"))
            #expect(!prompt.contains("never contradict a metric"))
        }
    }

    @Test func userContentPacksMetricsFindingsAndImages() {
        let analysis = SquatAnalyzer.analyze(SyntheticSquat(repCount: 2).series())
        let blocks = CoachPrompt.userContent(analysis: analysis, keyframes: [keyframe(rep: 1)])

        let texts = blocks.compactMap { $0["text"] as? String }
        #expect(texts.contains { $0.contains("Rep 1:") && $0.contains("torso lean") })
        #expect(texts.contains { $0.contains("Rules-engine findings") })
        #expect(blocks.contains { $0["type"] as? String == "image" })
    }

    /// Every image sits after its own rep's metric line and before the next
    /// rep's — the anchoring that lets the model tie pixels to numbers.
    @Test func imagesInterleavePerRep() {
        let analysis = SquatAnalyzer.analyze(SyntheticSquat(repCount: 2).series())
        let blocks = CoachPrompt.userContent(
            analysis: analysis,
            keyframes: [keyframe(rep: 1), keyframe(rep: 2)]
        )
        func firstIndex(containing needle: String) -> Int? {
            blocks.firstIndex { ($0["text"] as? String)?.contains(needle) == true }
        }
        let rep1Line = firstIndex(containing: "Rep 1:")
        let rep1Label = firstIndex(containing: "Rep 1 — bottom")
        let rep2Line = firstIndex(containing: "Rep 2:")
        let rep2Label = firstIndex(containing: "Rep 2 — bottom")
        #expect(rep1Line != nil && rep1Label != nil && rep2Line != nil && rep2Label != nil)
        if let rep1Line, let rep1Label, let rep2Line, let rep2Label {
            #expect(rep1Line < rep1Label)
            #expect(rep1Label < rep2Line)
            #expect(rep2Line < rep2Label)
        }
    }

    /// Image labels carry the metadata the verification mission needs:
    /// timestamp, pixel dimensions, rendition, and joint coordinates.
    @Test func keyframeLabelsCarryMetadata() {
        let analysis = SquatAnalyzer.analyze(SyntheticSquat(repCount: 1).series())
        let blocks = CoachPrompt.userContent(
            analysis: analysis,
            keyframes: [keyframe(rep: 1), keyframe(rep: 1, isOverlay: true)]
        )
        let texts = blocks.compactMap { $0["text"] as? String }
        let rawLabel = texts.first { $0.contains("RAW FRAME") }
        let overlayLabel = texts.first { $0.contains("SKELETON OVERLAY") }
        #expect(rawLabel?.contains("t=1.2 s") == true)
        #expect(rawLabel?.contains("576×1024 px") == true)
        #expect(rawLabel?.contains("leftKnee (213, 641)") == true)
        #expect(overlayLabel?.contains("same instant as the raw frame above") == true)
        #expect(overlayLabel?.contains("leftAnkle (position repaired, not detected)") == true)
    }

    /// Measured per-rep jitter is stated with its gate so the model can
    /// weigh borderline reps instead of seeing only a binary caveat.
    @Test func repLinesCarryMeasuredJitter() {
        var analysis = SquatAnalyzer.analyze(SyntheticSquat(repCount: 1).series())
        analysis.reps[0].trackingJitter = 0.0007
        let texts = CoachPrompt.userContent(analysis: analysis, keyframes: [])
            .compactMap { $0["text"] as? String }
        #expect(texts.contains { $0.contains("tracking jitter 0.0007") && $0.contains("gate") })
    }

    /// nil per-rep jitter means "unmeasurable window" only in sessions that
    /// measured jitter at all. A legacy session (persisted before the
    /// per-rep field existed) decodes nil on every rep — none of them may be
    /// branded unreliable.
    @Test func legacySessionsGetNoTrackingCaveat() {
        var analysis = SquatAnalyzer.analyze(SyntheticSquat(repCount: 2).series())
        for index in analysis.reps.indices {
            analysis.reps[index].trackingJitter = nil
        }
        let texts = CoachPrompt.userContent(analysis: analysis, keyframes: [])
            .compactMap { $0["text"] as? String }
        #expect(!texts.contains { $0.contains("TRACKING UNRELIABLE") })
    }

    /// In a fresh session where other reps carry measured jitter, a nil rep
    /// really is an unmeasurable window and keeps the caveat.
    @Test func unmeasurableRepStillGetsTrackingCaveat() {
        var analysis = SquatAnalyzer.analyze(SyntheticSquat(repCount: 2).series())
        analysis.reps[0].trackingJitter = nil
        let texts = CoachPrompt.userContent(analysis: analysis, keyframes: [])
            .compactMap { $0["text"] as? String }
        let repLines = texts.filter { $0.hasPrefix("Rep ") }
        #expect(repLines.contains { $0.hasPrefix("Rep 1:") && $0.contains("TRACKING UNRELIABLE") })
        #expect(repLines.contains { $0.hasPrefix("Rep 2:") && !$0.contains("TRACKING UNRELIABLE") })
    }

    @Test func outputSchemaRequiresTrackingVerification() {
        let schema = CoachPrompt.outputSchema
        let required = schema["required"] as? [String]
        #expect(required?.contains("tracking_verification") == true)
        let properties = schema["properties"] as? [String: Any]
        #expect(properties?["tracking_verification"] != nil)
    }

    @Test func outputSchemaRequiresCorrectiveWork() {
        let schema = CoachPrompt.outputSchema
        #expect((schema["required"] as? [String])?.contains("corrective_work") == true)
        let properties = schema["properties"] as? [String: Any]
        let corrective = properties?["corrective_work"] as? [String: Any]
        let item = corrective?["items"] as? [String: Any]
        let itemRequired = item?["required"] as? [String]
        #expect(itemRequired?.sorted() == ["addresses", "dosage", "drill", "kind", "name", "target", "why"])
        // The drill tag must offer exactly the animations the app can draw,
        // plus the opt-out — a tag the app can't render draws nothing.
        let itemProperties = item?["properties"] as? [String: Any]
        let drill = itemProperties?["drill"] as? [String: Any]
        #expect((drill?["enum"] as? [String])?.sorted()
            == (ExerciseHintTopic.allCases.map(\.rawValue) + ["none"]).sorted())
    }

    /// The mobility-vs-strength discriminator: without the scan reference
    /// the model can't tell "can't reach depth" from "can't hold it".
    @Test func setHeaderCarriesUnloadedMobilityReference() {
        var geometry = MetricBodyGeometry(femurMeters: 0.42, shinMeters: 0.40, quality: 0.03)
        geometry.deepestHipBelowKneeDegrees = 28
        var analysis = SquatAnalysis(
            reps: [], findings: [], score: 80, usedDepth: true, bodyHeight: 1.8,
            series: JointSeries(frames: [], bodyHeight: 1.8, usedDepth: true)
        )
        analysis.metricGeometry = geometry
        let header = CoachPrompt.userContent(analysis: analysis, keyframes: [])
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
        #expect(header.contains("Unloaded mobility reference"))
        #expect(header.contains("28°"))
    }

    @Test func coachReportDecodesCorrectiveWork() throws {
        let sample = """
        {"summary":"s","priority_fix":{"title":"t","cue":"c","why":"w"},"findings":[],"positives":[],"corrective_work":[{"kind":"mobility","name":"Knee-to-wall ankle rock","target":"ankle dorsiflexion","addresses":"Shallow depth on reps 3-5","dosage":"3 x 45 s per side, daily","why":"Limited dorsiflexion stops the knee travelling forward.","drill":"ankleRock"}]}
        """
        let report = try JSONDecoder().decode(CoachReport.self, from: Data(sample.utf8))
        let drill = report.correctiveWork?.first
        #expect(drill?.isMobility == true)
        #expect(drill?.target == "ankle dorsiflexion")
        #expect(drill?.hintTopic == .ankleRock)
        #expect(!report.hasJSONResidue)
    }

    /// "none" and unknown tags must degrade to no animation, never crash.
    @Test func unknownDrillTagRendersNoAnimation() throws {
        let sample = """
        {"summary":"s","priority_fix":{"title":"t","cue":"c","why":"w"},"findings":[],"positives":[],"corrective_work":[{"kind":"strength","name":"Zercher carry","target":"trunk strength","addresses":"Lean on rep 4","dosage":"3 x 30 m","why":"Trunk gives out late.","drill":"none"}]}
        """
        let report = try JSONDecoder().decode(CoachReport.self, from: Data(sample.utf8))
        #expect(report.correctiveWork?.first?.hintTopic == nil)
        #expect(report.correctiveWork?.first?.isMobility == false)
    }

    /// Old cached `.coach` files predate the verification field and must
    /// still decode (optional-fields law).
    @Test func coachReportDecodesSchemaShapedJSON() throws {
        let sample = """
        {"summary":"Solid set.","priority_fix":{"title":"Brace harder","cue":"Big air, push out","why":"Lean grows late in the set."},"findings":[{"severity":"warning","title":"t","detail":"d","rep_numbers":[1,3],"confidence":"high"}],"positives":["Depth"]}
        """
        let report = try JSONDecoder().decode(CoachReport.self, from: Data(sample.utf8))
        #expect(report.findings.first?.severity == .warning)
        #expect(report.findings.first?.repNumbers == [1, 3])
        #expect(report.priorityFix.title == "Brace harder")
        #expect(report.trackingVerification == nil)
        #expect(report.correctiveWork == nil)
    }

    @Test func coachReportDecodesTrackingVerification() throws {
        let sample = """
        {"summary":"s","priority_fix":{"title":"t","cue":"c","why":"w"},"findings":[],"positives":[],"tracking_verification":[{"rep_number":3,"verdict":"mismatch","joints":["leftKnee","leftAnkle"],"note":"Knee drawn on the plate."}]}
        """
        let report = try JSONDecoder().decode(CoachReport.self, from: Data(sample.utf8))
        let verdict = report.trackingVerification?.first
        #expect(verdict?.repNumber == 3)
        #expect(verdict?.verdict == "mismatch")
        #expect(verdict?.joints == ["leftKnee", "leftAnkle"])
    }

    @Test func cleanReportHasNoResidue() throws {
        let sample = """
        {"summary":"Solid set.","priority_fix":{"title":"Brace harder","cue":"Big air, push out","why":"Lean grows late in the set."},"findings":[],"positives":["Depth"]}
        """
        let report = try JSONDecoder().decode(CoachReport.self, from: Data(sample.utf8))
        #expect(!report.hasJSONResidue)
        #expect(report.sanitized() != nil)
    }

    /// The glitch seen in the field: a placeholder envelope whose
    /// `priority_fix.why` starts with real prose, then continues as the
    /// serialized remainder of the actual report. The client must recover
    /// the nested report instead of rendering raw JSON.
    @Test func coachReportRecoversNestedReport() throws {
        let sample = """
        {"summary":"placeholder","priority_fix":{"title":"Sit your hips down until your hip crease drops below the knee","cue":"","topic":"squat_depth","why":"You already hold a near-vertical torso; ride it down.\\",\\"title\\":\\"Sit fully to depth\\"},\\"summary\\":\\"Upright torso and clean pattern; depth is the one habit costing the set.\\",\\"findings\\":[{\\"severity\\":\\"warning\\",\\"title\\":\\"Consistently stopping above parallel\\",\\"detail\\":\\"Femur sat at -11° on the tracked reps.\\",\\"rep_numbers\\":[1,2],\\"confidence\\":\\"high\\",\\"topic\\":\\"squat_depth\\"}],\\"positives\\":[\\"Torso stays tall\\"],\\"tracking_verification\\":[{\\"rep_number\\":1,\\"verdict\\":\\"matches\\",\\"joints\\":[],\\"note\\":\\"Clean.\\"}]}"},"findings":[],"positives":[],"tracking_verification":[]}
        """
        let report = try JSONDecoder().decode(CoachReport.self, from: Data(sample.utf8))
        #expect(report.hasJSONResidue)
        let recovered = try #require(report.sanitized())
        #expect(!recovered.hasJSONResidue)
        #expect(recovered.summary.hasPrefix("Upright torso"))
        #expect(recovered.priorityFix.title == "Sit fully to depth")
        #expect(recovered.priorityFix.cue == "Sit your hips down until your hip crease drops below the knee")
        #expect(recovered.priorityFix.why == "You already hold a near-vertical torso; ride it down.")
        #expect(recovered.priorityFix.topic == "squat_depth")
        #expect(recovered.findings.count == 1)
        #expect(recovered.findings.first?.repNumbers == [1, 2])
        #expect(recovered.positives == ["Torso stays tall"])
        #expect(recovered.trackingVerification?.count == 1)
    }

    /// Whole-report-inside-`why`, head included: recovered directly.
    @Test func coachReportRecoversFullySerializedReport() throws {
        let sample = """
        {"summary":"placeholder","priority_fix":{"title":"t","cue":"c","why":"{\\"summary\\":\\"Real summary.\\",\\"priority_fix\\":{\\"title\\":\\"Real title\\",\\"cue\\":\\"Real cue\\",\\"why\\":\\"Real why.\\",\\"topic\\":\\"none\\"},\\"findings\\":[],\\"positives\\":[],\\"tracking_verification\\":[]}"},"findings":[],"positives":[],"tracking_verification":[]}
        """
        let report = try JSONDecoder().decode(CoachReport.self, from: Data(sample.utf8))
        let recovered = try #require(report.sanitized())
        #expect(recovered.summary == "Real summary.")
        #expect(recovered.priorityFix.cue == "Real cue")
    }

    /// Residue that can't be rebuilt into a clean report is rejected, so
    /// the UI offers a retry instead of rendering garbage.
    @Test func unrecoverableResidueIsRejected() throws {
        let sample = """
        {"summary":"placeholder","priority_fix":{"title":"t","cue":"","why":"Prose.\\",\\"summary\\":\\"unbalanced"},"findings":[],"positives":[]}
        """
        let report = try JSONDecoder().decode(CoachReport.self, from: Data(sample.utf8))
        #expect(report.hasJSONResidue)
        #expect(report.sanitized() == nil)
    }

    /// Byte-for-byte the reply pulled off the device on 2026-08-04: the model
    /// spent ~6.9k output tokens thinking and then filled every field with
    /// nothing. It satisfies the output schema, so only a semantic check
    /// catches it — without one the review screen cached it and drew a blank
    /// card that looked like a finished assessment.
    @Test func emptyShellIsRejected() throws {
        let sample = """
        {"positives":[],"priority_fix":{"why":"","topic":"none","cue":"","title":""},"findings":[],"summary":"","tracking_verification":[],"corrective_work":[]}
        """
        let report = try JSONDecoder().decode(CoachReport.self, from: Data(sample.utf8))
        #expect(report.isEmptyShell)
        #expect(report.sanitized() == nil)
    }

    /// Whitespace-only prose is the same failure wearing a hat.
    @Test func blankProseCountsAsEmptyShell() throws {
        let sample = """
        {"summary":"  ","priority_fix":{"title":"\\n","cue":" ","why":""},"findings":[],"positives":[]}
        """
        let report = try JSONDecoder().decode(CoachReport.self, from: Data(sample.utf8))
        #expect(report.isEmptyShell)
    }

    /// The emptiness check must not swallow a genuinely clean lift: no
    /// findings is a legitimate verdict, and that report still carries a
    /// summary and a cue.
    @Test func cleanSetWithNoFindingsSurvives() throws {
        let sample = """
        {"summary":"Textbook set — depth and bar path both hold.","priority_fix":{"title":"Keep the tempo","cue":"Two seconds down","why":"Control is what is holding this together."},"findings":[],"positives":[]}
        """
        let report = try JSONDecoder().decode(CoachReport.self, from: Data(sample.utf8))
        #expect(!report.isEmptyShell)
        #expect(report.sanitized() != nil)
    }
}
