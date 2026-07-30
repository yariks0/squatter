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

    /// Two-to-three sentence overall read of the set.
    var summary: String
    var priorityFix: PriorityFix
    var findings: [CoachFinding]
    /// Things done well, worth keeping.
    var positives: [String]
    /// Optional so cached reports from before the verification mission decode.
    var trackingVerification: [TrackingVerdict]?

    enum CodingKeys: String, CodingKey {
        case summary, findings, positives
        case priorityFix = "priority_fix"
        case trackingVerification = "tracking_verification"
    }
}
