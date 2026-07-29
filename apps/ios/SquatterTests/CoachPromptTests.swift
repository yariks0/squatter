import Foundation
import Testing
@testable import Squatter

struct CoachPromptTests {
    @Test func systemPromptEmbedsLiveThresholds() {
        let prompt = CoachPrompt.systemPrompt()
        #expect(prompt.contains("\(Int(AnalysisTuning.fullDepthDegrees))°"))
        #expect(prompt.contains("\(Int(AnalysisTuning.torsoLeanWarningDegrees))°"))
        #expect(prompt.contains("\(Int(AnalysisTuning.valgusRiskRatio * 100))%"))
        #expect(prompt.contains("\(AnalysisTuning.slowConcentricSeconds)"))
    }

    @Test func userContentPacksMetricsFindingsAndImages() {
        let analysis = SquatAnalyzer.analyze(SyntheticSquat(repCount: 2).series())
        let keyframe = CoachPrompt.Keyframe(label: "Rep 1 — bottom position", jpegData: Data([0xFF]))
        let blocks = CoachPrompt.userContent(analysis: analysis, keyframes: [keyframe])

        let texts = blocks.compactMap { $0["text"] as? String }
        #expect(texts.contains { $0.contains("Rep 1:") && $0.contains("torso lean") })
        #expect(texts.contains { $0.contains("Rules-engine findings") })
        #expect(texts.contains("Rep 1 — bottom position"))
        #expect(blocks.contains { $0["type"] as? String == "image" })
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
        let repLines = texts.joined(separator: "\n")
            .split(separator: "\n").filter { $0.hasPrefix("Rep ") }
        #expect(repLines.contains { $0.hasPrefix("Rep 1:") && $0.contains("TRACKING UNRELIABLE") })
        #expect(repLines.contains { $0.hasPrefix("Rep 2:") && !$0.contains("TRACKING UNRELIABLE") })
    }

    @Test func coachReportDecodesSchemaShapedJSON() throws {
        let sample = """
        {"summary":"Solid set.","priority_fix":{"title":"Brace harder","cue":"Big air, push out","why":"Lean grows late in the set."},"findings":[{"severity":"warning","title":"t","detail":"d","rep_numbers":[1,3],"confidence":"high"}],"positives":["Depth"]}
        """
        let report = try JSONDecoder().decode(CoachReport.self, from: Data(sample.utf8))
        #expect(report.findings.first?.severity == .warning)
        #expect(report.findings.first?.repNumbers == [1, 3])
        #expect(report.priorityFix.title == "Brace harder")
    }
}
