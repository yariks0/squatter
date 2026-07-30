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
}
