import Foundation

/// Stable topics a coaching point can address; each maps to a wrong-vs-right
/// form diagram (`FormHintView`). Raw values are the `topic` strings the
/// coach model picks from in `CoachPrompt.outputSchema`.
enum FormHintTopic: String, Codable, CaseIterable, Sendable {
    // Squat
    case squatDepth = "squat_depth"
    case torsoLean = "torso_lean"
    case kneeValgus = "knee_valgus"
    case stanceWidth = "stance_width"
    case squatLockout = "squat_lockout"
    case controlDescent = "control_descent"
    case elbowsDown = "elbows_down"
    case barOverMidfoot = "bar_over_midfoot"
    // Bench press
    case benchTouch = "bench_touch"
    case elbowFlare = "elbow_flare"
    case forearmVertical = "forearm_vertical"
    case barPath = "bar_path"
    case benchLockout = "bench_lockout"
    // Recording setup
    case framing = "framing"
}
