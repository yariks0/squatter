import AVFoundation
import Foundation

/// What the coach says after each rep — terse imperatives in the register
/// of a Chinese weightlifting coach standing behind the lifter: the count,
/// then at most one cue, and a short affirmation on every third clean rep
/// so the praise keeps meaning.
enum CoachScript {
    private static let praise = ["Good.", "Strong.", "Stay tight."]

    static func repLine(count: Int, faults: [LiveRepCounter.LiveFault]) -> String {
        guard let fault = faults.first else {
            guard count > 0, count % 3 == 0 else { return "\(count)" }
            return "\(count). \(praise[(count / 3 - 1) % praise.count])"
        }
        let cue = switch fault {
        case .shallowDepth: "Go deeper!"
        case .torsoFold: "Chest up!"
        case .elbowsUp: "Elbows down!"
        case .cutHigh: "Touch the chest!"
        case .bounce: "No bounce!"
        case .fastDescent: "Control the descent!"
        case .slowAscent: "Big grind — stay sharp."
        }
        return "\(count). \(cue)"
    }
}

/// Speaks the live coaching cues — placement guidance, the countdown, rep
/// counts — through the speaker. The lifter is ~3 m from the phone mid-set,
/// so audio is the only feedback channel that works there. The recording
/// has no audio track, so speech never contaminates the captured video.
@MainActor
final class SetVoice {
    static let enabledDefaultsKey = "voiceCoachEnabled"

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
            if !enabled { synthesizer.stopSpeaking(at: .immediate) }
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var sessionActive = false
    private var lastGuidance: (text: String, at: Date)?

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
    }

    func speak(_ text: String, interrupting: Bool = false) {
        guard enabled else { return }
        if !sessionActive {
            // Duck (not stop) whatever the lifter has playing.
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, options: [.duckOthers])
            try? session.setActive(true)
            sessionActive = true
        }
        if interrupting, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        // A touch quicker than the default — cues land like commands, not
        // narration.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.08
        synthesizer.speak(utterance)
    }

    /// Placement guidance repeats as the status re-fires ~10×/s; the same
    /// line is spoken at most once every few seconds.
    func speakGuidance(_ text: String) {
        if let last = lastGuidance, last.text == text,
           Date().timeIntervalSince(last.at) < 4 { return }
        lastGuidance = (text, Date())
        speak(text)
    }

    func finish() {
        synthesizer.stopSpeaking(at: .immediate)
        guard sessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        sessionActive = false
    }
}
