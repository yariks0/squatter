import Foundation

/// Structured coaching produced by the LLM, decoded from the
/// JSON-schema-constrained response. `CoachPrompt.outputSchema` must stay in
/// sync with these types.
struct CoachReport: Codable, Sendable {
    struct PriorityFix: Codable, Sendable {
        /// Short name of the single most important fix for the next set.
        var title: String
        /// The cue to think about while lifting.
        var cue: String
        /// Why this fix comes first.
        var why: String
        /// Raw diagram-topic tag from the model ("none" when nothing fits);
        /// optional so reports saved before form hints still decode.
        var topic: String?

        var hintTopic: FormHintTopic? { topic.flatMap(FormHintTopic.init(rawValue:)) }
    }

    struct CoachFinding: Codable, Sendable, Identifiable {
        var id: UUID { UUID() }
        var severity: Finding.Severity
        var title: String
        var detail: String
        var repNumbers: [Int]
        /// "low" | "medium" | "high" — how sure the model is from the evidence.
        var confidence: String
        /// Raw diagram-topic tag from the model ("none" when nothing fits);
        /// optional so reports saved before form hints still decode.
        var topic: String?

        enum CodingKeys: String, CodingKey {
            case severity, title, detail, confidence, topic
            case repNumbers = "rep_numbers"
        }

        /// Bridge to the rules-engine type so the report UI renders both alike.
        var asFinding: Finding {
            Finding(
                severity: severity, title: title, detail: detail, repNumbers: repNumbers,
                topic: topic.flatMap(FormHintTopic.init(rawValue:))
            )
        }
    }

    /// The model's skeleton-vs-footage check for one overlay-carrying rep.
    struct TrackingVerdict: Codable, Sendable {
        /// "matches" | "minor_drift" | "mismatch".
        var verdict: String
        var repNumber: Int
        /// BodyJoint raw values the verdict is about (empty for "matches").
        var joints: [String]
        /// One sentence on what the skeleton got wrong.
        var note: String

        enum CodingKeys: String, CodingKey {
            case verdict, joints, note
            case repNumber = "rep_number"
        }
    }

    /// An off-the-bar drill prescribed because a fault traces back to a
    /// physical limitation a cue alone can't fix.
    struct CorrectiveExercise: Codable, Sendable, Identifiable {
        var id: String { name }
        /// "mobility" | "strength" — which limitation this addresses.
        var kind: String
        /// The drill itself, e.g. "Goblet squat hold".
        var name: String
        /// The capacity being trained, e.g. "ankle dorsiflexion".
        var target: String
        /// The fault it unlocks, in the lifter's own set.
        var addresses: String
        /// Prescription: sets × reps or hold time, and frequency.
        var dosage: String
        /// One sentence: limitation → fault.
        var why: String
        /// Raw drill tag selecting the animated demo ("none" when the
        /// prescribed drill isn't one the app can draw); optional so
        /// reports saved before the animations decode.
        var drill: String?

        var isMobility: Bool { kind == "mobility" }

        var hintTopic: ExerciseHintTopic? {
            drill.flatMap(ExerciseHintTopic.init(rawValue:))
        }
    }

    /// Two-to-three sentence overall read of the set.
    var summary: String
    var priorityFix: PriorityFix
    var findings: [CoachFinding]
    /// Things done well, worth keeping.
    var positives: [String]
    /// Optional so cached reports from before the verification mission decode.
    var trackingVerification: [TrackingVerdict]?
    /// Empty when every fault is a cue away from fixed. Optional so cached
    /// reports from before corrective work existed decode.
    var correctiveWork: [CorrectiveExercise]?

    enum CodingKeys: String, CodingKey {
        case summary, findings, positives
        case priorityFix = "priority_fix"
        case trackingVerification = "tracking_verification"
        case correctiveWork = "corrective_work"
    }
}

extension CoachReport {
    /// True when a prose field carries serialized-JSON residue. The model
    /// occasionally glitches and nests the real report inside a string
    /// field (observed: `priority_fix.why` held `<prose>","title":"…"},`
    /// followed by the rest of the report JSON, wrapped in a placeholder
    /// envelope). The envelope decodes fine against the schema, so it can
    /// only be caught semantically.
    var hasJSONResidue: Bool {
        let prose = [summary, priorityFix.title, priorityFix.cue, priorityFix.why]
            + findings.flatMap { [$0.title, $0.detail] }
            + (correctiveWork ?? []).flatMap { [$0.name, $0.addresses, $0.dosage, $0.why] }
            + positives
        return prose.contains {
            $0.contains("\":\"") || $0.contains("\":[") || $0.contains("\"},\"")
        }
    }

    /// True when the reply satisfies the output schema but carries no usable
    /// coaching. The schema can't catch this — the *shape* is valid — so like
    /// `hasJSONResidue` it can only be caught semantically.
    ///
    /// Judged on the two fields the review screen always renders and the
    /// lifter actually acts on: the priority cue (the one line to take to the
    /// next set) and the summary (the read of the set). Everything else is
    /// legitimately optional — a clean lift has no findings and no correctives
    /// — so keying on those would reject good reports.
    ///
    /// Both failure grades seen on prod have been caught here: the all-blank
    /// 152-byte shell (2026-08-04), and the partial reply that carried one
    /// finding but a blank cue and summary and rendered as "◎ :" over an empty
    /// "Cue:" (2026-08-05, 390 bytes against 5.5k output tokens).
    var isUnusable: Bool {
        Self.isBlank(priorityFix.cue) || Self.isBlank(summary)
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The report with a nested-JSON glitch repaired and half-written drills
    /// dropped, or nil when what is left carries no usable coaching. The
    /// caller then treats the response as unreadable and offers a retry.
    func sanitized() -> CoachReport? {
        // Residue recovery first: it is what fills the fields the usability
        // check then judges, so checking before it would reject recoverable
        // reports.
        let repaired: CoachReport
        if hasJSONResidue {
            guard let recovered = recoveringNestedReport() else { return nil }
            repaired = recovered
        } else {
            repaired = self
        }
        guard !repaired.isUnusable else { return nil }
        return repaired.droppingHalfWrittenDrills()
    }

    /// Drops correctives the model left half-written. One blank-named drill
    /// otherwise renders as a card reading "—" over an empty "Fixes:", which
    /// is worse than not showing the drill at all.
    private func droppingHalfWrittenDrills() -> CoachReport {
        guard let drills = correctiveWork, !drills.isEmpty else { return self }
        let usable = drills.filter { !Self.isBlank($0.name) && !Self.isBlank($0.addresses) }
        guard usable.count != drills.count else { return self }
        var trimmed = self
        trimmed.correctiveWork = usable
        return trimmed
    }

    private func recoveringNestedReport() -> CoachReport? {
        // Whole report serialized into `why`, head included.
        if let data = priorityFix.why.data(using: .utf8),
           let direct = try? JSONDecoder().decode(CoachReport.self, from: data),
           !direct.hasJSONResidue {
            return direct
        }
        // Observed shape: `why` starts mid-report — `<why prose>","title":"…"},`
        // then the remaining top-level fields. Re-head it into a full object.
        guard priorityFix.why.contains("\"summary\":\""),
              let data = "{\"priority_fix\":{\"cue\":\"\",\"topic\":\"none\",\"why\":\""
                  .appending(priorityFix.why).data(using: .utf8),
              var inner = try? JSONDecoder().decode(CoachReport.self, from: data),
              !inner.hasJSONResidue
        else { return nil }
        // The envelope carried the real cue and topic; the inner object
        // lost them to the glitch.
        if inner.priorityFix.cue.isEmpty {
            inner.priorityFix.cue = priorityFix.title
        }
        if inner.priorityFix.topic == nil || inner.priorityFix.topic == "none" {
            inner.priorityFix.topic = priorityFix.topic
        }
        return inner
    }
}
