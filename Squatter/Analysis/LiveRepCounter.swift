import Foundation
import simd

/// One 2D pose observation from the live camera feed, in Vision-normalized
/// image coordinates (origin bottom-left, y up). Midpoints average whichever
/// of the left/right joints cleared the confidence bar; nil = neither did.
struct LivePoseSample: Sendable, Equatable {
    var time: TimeInterval
    var hipMid: SIMD2<Double>?
    var kneeMid: SIMD2<Double>?
    var shoulderMid: SIMD2<Double>?
    var elbowMid: SIMD2<Double>?
    var wristMid: SIMD2<Double>?
    var noseY: Double?
    var ankleMidY: Double?

    init(
        time: TimeInterval,
        hipMid: SIMD2<Double>? = nil,
        kneeMid: SIMD2<Double>? = nil,
        shoulderMid: SIMD2<Double>? = nil,
        elbowMid: SIMD2<Double>? = nil,
        wristMid: SIMD2<Double>? = nil,
        noseY: Double? = nil,
        ankleMidY: Double? = nil
    ) {
        self.time = time
        self.hipMid = hipMid
        self.kneeMid = kneeMid
        self.shoulderMid = shoulderMid
        self.elbowMid = elbowMid
        self.wristMid = wristMid
        self.noseY = noseY
        self.ankleMidY = ankleMidY
    }
}

/// Online rep counter behind the spoken live feedback: a hysteresis state
/// machine over 2D image-space signals. The camera is propped and static,
/// so image y is a legitimate vertical axis — squat reps are the hip
/// midpoint dropping below its standing height, bench reps the
/// wrist–shoulder distance contracting from lockout. Best-effort by design;
/// the offline 3D analysis remains the truth for the report.
struct LiveRepCounter {
    /// Faults the 2D signals can call reliably enough to speak out loud.
    /// Only calls that are timing-based or computed from robust statistics
    /// (a median over the rep, a comparison against the lifter's own
    /// earlier reps) qualify — a wrong shout mid-set costs more trust than
    /// ten right ones earn. Valgus, lockout, and drift stay offline.
    enum LiveFault: Equatable {
        /// Squat: the hips clearly stayed above the knees at the turnaround.
        case shallowDepth
        /// Squat: the torso folded well past vertical through the rep
        /// (median image-space lean over the in-rep window).
        case torsoFold
        /// Squat: the elbows swung up/back off the torso line through the
        /// rep — the bar rolls and the chest follows.
        case elbowsUp
        /// Bench: this rep turned around well above the lifter's own
        /// earlier touch depth.
        case cutHigh
        /// Bench: no measurable dwell at the bottom — the bar rebounded
        /// straight off the chest.
        case bounce
        /// Entry-crossing→bottom time below `liveFastDescentSeconds` —
        /// the descent was a free fall, not a controlled lowering.
        case fastDescent
        /// Bottom→exit time beyond `liveSlowAscentSeconds` — a grind, the
        /// bar-speed signal to consider ending the set.
        case slowAscent
    }

    enum Event: Equatable {
        /// A rep just finished; `faults` is priority-ordered (may be empty).
        case repCompleted(count: Int, faults: [LiveFault])
    }

    let activity: ActivityType
    private(set) var count = 0

    /// Standing hip height locked in while the lifter holds position before
    /// the set; a floor under the rolling baseline, immune to its decay
    /// during long pauses at the bottom.
    private var calibratedStanding: Double?
    private var calibrationHipYs: [Double] = []

    // Decaying maxima over `liveBaselineWindowSeconds`: the signal baseline
    // (standing hip height / lockout distance) and, for squat, the
    // image-space body span the drop thresholds scale by.
    private var baselineWindow: [(time: TimeInterval, value: Double)] = []
    private var spanWindow: [(time: TimeInterval, value: Double)] = []

    private var lastSignal: Double?
    private var inRep = false
    private var repStart: TimeInterval = 0
    private var bottomTime: TimeInterval = 0
    private var bottomSignal = Double.infinity
    private var bottomKneeY: Double?
    /// (time, signal) trail of the current rep, for the bottom-dwell call.
    private var repSamples: [(time: TimeInterval, signal: Double)] = []
    /// Image-space torso leans over the current rep (squat).
    private var repLeans: [Double] = []
    /// Image-space upper-arm angles from the torso line over the current
    /// rep (squat) — the live "elbows down" measure.
    private var repElbowDegrees: [Double] = []
    /// Depths (lockout − bottom) of this set's earlier reps (bench).
    private var priorDepths: [Double] = []

    init(activity: ActivityType) {
        self.activity = activity
    }

    /// Feed standing samples during the positioning green-hold to pin the
    /// baseline before the first descent.
    mutating func calibrate(with sample: LivePoseSample) {
        guard activity == .squat, let hip = sample.hipMid else { return }
        calibrationHipYs.append(hip.y)
        if calibrationHipYs.count > 40 { calibrationHipYs.removeFirst() }
        calibratedStanding = median(of: calibrationHipYs)
    }

    mutating func ingest(_ sample: LivePoseSample) -> Event? {
        switch activity {
        case .squat: ingestSquat(sample)
        case .benchPress: ingestBench(sample)
        }
    }

    private mutating func ingestSquat(_ sample: LivePoseSample) -> Event? {
        guard let signal = sample.hipMid?.y ?? lastSignal else { return nil }
        lastSignal = signal

        var baseline = rollingMax(&baselineWindow, insert: signal, at: sample.time)
        if let calibratedStanding {
            baseline = max(baseline, calibratedStanding)
        }
        // Body span from the standing leg: hip-to-ankle is about half of it.
        // The decaying max keeps standing-frame estimates in charge while
        // the squat itself compresses the instantaneous value.
        var span: Double?
        if let hip = sample.hipMid?.y, let ankle = sample.ankleMidY, hip - ankle > 0.02 {
            span = rollingMax(&spanWindow, insert: 2 * (hip - ankle), at: sample.time)
        } else if let last = spanWindow.last {
            span = last.value
        }
        guard let span, span > 0.05 else { return nil }

        let entry = baseline - AnalysisTuning.liveSquatEntryDropFraction * span
        let exit = baseline - AnalysisTuning.liveSquatExitDropFraction * span
        if inRep {
            if signal < bottomSignal {
                bottomSignal = signal
                bottomTime = sample.time
                bottomKneeY = sample.kneeMid?.y ?? bottomKneeY
            }
            if let shoulder = sample.shoulderMid, let hip = sample.hipMid {
                let trunk = shoulder - hip
                if trunk.y > 1e-6 {
                    repLeans.append(atan2(abs(trunk.x), trunk.y) * 180 / .pi)
                }
                if let elbow = sample.elbowMid {
                    let upperArm = elbow - shoulder
                    let torsoDown = hip - shoulder
                    let lengths = simd_length(upperArm) * simd_length(torsoDown)
                    if lengths > 1e-9 {
                        let cosine = simd_dot(upperArm, torsoDown) / lengths
                        repElbowDegrees.append(acos(max(-1, min(1, cosine))) * 180 / .pi)
                    }
                }
            }
            guard signal > exit else { return nil }
            inRep = false
            guard sample.time - repStart >= AnalysisTuning.minimumRepDuration else { return nil }
            count += 1
            var faults: [LiveFault] = []
            if let kneeY = bottomKneeY,
               bottomSignal > kneeY + AnalysisTuning.liveSquatHighMargin {
                faults.append(.shallowDepth)
            }
            if let lean = median(of: repLeans), lean > AnalysisTuning.liveSquatFoldDegrees {
                faults.append(.torsoFold)
            }
            if let elbows = median(of: repElbowDegrees),
               elbows > AnalysisTuning.liveElbowLiftDegrees {
                faults.append(.elbowsUp)
            }
            if bottomTime - repStart < AnalysisTuning.liveFastDescentSeconds {
                faults.append(.fastDescent)
            }
            if sample.time - bottomTime > AnalysisTuning.liveSlowAscentSeconds {
                faults.append(.slowAscent)
            }
            return .repCompleted(count: count, faults: faults)
        } else if signal < entry {
            beginRep(at: sample.time, signal: signal)
            bottomKneeY = sample.kneeMid?.y
        }
        return nil
    }

    private mutating func ingestBench(_ sample: LivePoseSample) -> Event? {
        var distance: Double?
        if let wrist = sample.wristMid, let shoulder = sample.shoulderMid {
            distance = simd_length(wrist - shoulder)
        }
        guard let signal = distance ?? lastSignal else { return nil }
        lastSignal = signal

        let lockout = rollingMax(&baselineWindow, insert: signal, at: sample.time)
        guard lockout > 0.02 else { return nil }

        let entry = lockout * AnalysisTuning.liveBenchEntryFraction
        let exit = lockout * AnalysisTuning.liveBenchExitFraction
        if inRep {
            if signal < bottomSignal {
                bottomSignal = signal
                bottomTime = sample.time
            }
            repSamples.append((sample.time, signal))
            guard signal > exit else { return nil }
            inRep = false
            guard sample.time - repStart >= AnalysisTuning.minimumRepDuration else { return nil }
            count += 1
            var faults: [LiveFault] = []
            let depth = lockout - bottomSignal
            if priorDepths.count >= 2, let typical = median(of: priorDepths),
               depth < AnalysisTuning.liveBenchCutHighFraction * typical {
                faults.append(.cutHigh)
            } else if bottomDwell(band: AnalysisTuning.liveBounceBandFraction * lockout)
                < AnalysisTuning.liveBounceMaxSeconds {
                // A cut-high turnaround has no chest to bounce off; the two
                // calls are mutually exclusive.
                faults.append(.bounce)
            }
            if bottomTime - repStart < AnalysisTuning.liveFastDescentSeconds {
                faults.append(.fastDescent)
            }
            if sample.time - bottomTime > AnalysisTuning.liveSlowAscentSeconds {
                faults.append(.slowAscent)
            }
            priorDepths.append(depth)
            return .repCompleted(count: count, faults: faults)
        } else if signal < entry {
            beginRep(at: sample.time, signal: signal)
        }
        return nil
    }

    private mutating func beginRep(at time: TimeInterval, signal: Double) {
        inRep = true
        repStart = time
        bottomTime = time
        bottomSignal = signal
        repSamples = [(time, signal)]
        repLeans = []
        repElbowDegrees = []
    }

    /// Time spent within `band` of the rep's bottom — near zero on a bounce.
    private func bottomDwell(band: Double) -> TimeInterval {
        let nearBottom = repSamples.filter { $0.signal <= bottomSignal + band }
        guard let first = nearBottom.first, let last = nearBottom.last else { return 0 }
        return last.time - first.time
    }

    private func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }

    /// Inserts a value into a time-pruned window and returns its maximum.
    private func rollingMax(
        _ window: inout [(time: TimeInterval, value: Double)],
        insert value: Double,
        at time: TimeInterval
    ) -> Double {
        window.append((time, value))
        window.removeAll { time - $0.time > AnalysisTuning.liveBaselineWindowSeconds }
        return window.map(\.value).max() ?? value
    }
}
