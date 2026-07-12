import Foundation

/// All analysis thresholds in one place for tuning against real recordings.
///
/// Quality standards follow Chinese weightlifting team practice (high-bar
/// style): full depth well below parallel is the target, the torso stays
/// close to vertical, knees track over the toes without caving, and the
/// descent stays controlled.
enum AnalysisTuning {
    // MARK: Rep segmentation (fractions of standing hip-above-ankle height)
    static let descentEntryFraction = 0.85
    static let ascentExitFraction = 0.93
    /// Fraction of standing height that counts as "standing" when locating
    /// where a rep actually starts and ends (tempo boundaries).
    static let standingFraction = 0.97
    static let minimumRepDepthFraction = 0.12
    static let minimumRepDuration: TimeInterval = 0.8

    // MARK: Depth (femur angle vs horizontal at the bottom, degrees;
    // positive = hip crease below the knee)
    /// Full depth: sitting fully down with the hip crease well below the
    /// knee, not just breaking parallel.
    static let fullDepthDegrees = 12.0
    /// Below this the rep counts as shallow (above parallel).
    static let parallelToleranceDegrees = -8.0

    // MARK: Plate detection (see PlateDetector / PlateCatalog)
    /// Detected diameters within this of a catalog plate match it; two
    /// catalog plates closer than half of this are ambiguous and unmatched.
    static let plateDiameterToleranceMeters = 0.02
    /// Plausible plate-face diameters; contours outside are gym clutter.
    static let plateDiameterRangeMeters = 0.15 ... 0.52

    // MARK: Personalized depth (vs the body scan's unloaded deep hold)
    /// Loaded bottoms within this many degrees of the scan's deep-hold
    /// reading count as the lifter's full depth.
    static let depthReferenceMarginDegrees = 6.0
    /// Scan depth minus the set's median bottom beyond this = "depth in
    /// reserve": the range demonstrably exists, the lifter isn't using it.
    static let depthReserveDegrees = 10.0

    // MARK: Torso lean at the bottom (degrees from vertical).
    // High-bar standard: torso close to vertical (a deep upright squat sits
    // around 25–35°), so lean is caught early.
    static let torsoLeanWarningDegrees = 40.0
    static let torsoLeanRiskDegrees = 50.0

    // MARK: Knee valgus (medial knee deviation / hip width)
    static let valgusWarningRatio = 0.18
    static let valgusRiskRatio = 0.32

    // MARK: Body-geometry scan (see BodyGeometry / SkeletonCorrector)
    /// Fraction of the standing baseline above which a frame counts as
    /// standing — the auto-scan frames bone lengths are measured from.
    static let geometryScanFraction = 0.97
    /// Standing frames (and per-bone samples) required before the scan is
    /// trusted; below this the session runs uncorrected.
    static let geometryMinimumScanFrames = 12
    /// Signal fraction of the standing baseline below which a scan frame
    /// belongs to the deep hold — the lifter's full-depth reference pose.
    static let geometryScanDeepFraction = 0.75
    /// Metric femur scans noisier than this (MAD/median of the standing
    /// samples) can't be trusted to anchor the pose. Real in-session scans
    /// measured 0.02–0.06; a controlled pre-scan should sit near 0.02.
    static let geometryScanQualityGate = 0.08
    /// Sanity range for a scanned metric femur; outside it the 2D detector
    /// grabbed something that isn't a standing leg.
    static let geometryFemurRangeMeters = 0.25 ... 0.70
    /// Hard cap on the per-frame pelvis shift from the image anchor —
    /// real mis-projections measured ~0.1–0.15 m of equivalent shift.
    static let geometryAnchorMaxShiftMeters: Float = 0.25
    /// The anchor engages only when the model femur's depth sine (+1 = hip a
    /// femur-length below the knee) is above this — i.e. the model already
    /// sits in the bottom half of a squat, the only place the pelvis
    /// mis-projection exists. Keeps 2D glitches elsewhere in the set from
    /// deepening standing frames into phantom reps.
    static let geometryAnchorModelSineFloor: Float = -0.5

    // MARK: Tempo
    /// Below this the descent is a free fall rather than a controlled ~1–2 s
    /// eccentric. The elastic rebound out of the bottom is fine — the descent
    /// feeding it must be controlled.
    static let minimumEccentricSeconds = 0.6
    /// Above this the ascent is a grind — bar speed out of the bottom is the
    /// load-management signal in Chinese weightlifting practice.
    static let slowConcentricSeconds = 2.5

    // MARK: Symmetry (left/right knee-angle difference at the bottom, degrees)
    static let asymmetryWarningDegrees = 12.0

    // MARK: Stance (ankle separation / shoulder width in image x, measured
    // standing at the start of a rep — the lifter's own proportions, not the
    // 3D model's fixed-width shoulders). High-bar standard: heels around
    // shoulder width so the hips can sit between the legs; real correct
    // stances measured 0.9–1.3 on pulled sessions.
    static let stanceNarrowRatio = 0.6
    static let stanceWideRatio = 1.5
    /// Shoulder image span below this fraction of the femur's image length
    /// means the camera is side-on: stance is unmeasurable and unjudged.
    static let stanceViewGateRatio: Float = 0.5

    // MARK: Bottom stability (horizontal pelvis drift while at the bottom,
    // as a fraction of hip width). A held bottom position keeps the pelvis
    // still; wiggle/rocking under load is a control fault.
    static let bottomShiftWarningRatio = 0.25
    /// Frames count as "at the bottom" while the squat signal is within this
    /// fraction of standing height above the rep's lowest point.
    static let bottomWindowFraction = 0.05

    // MARK: Lockout (average knee angle at the top of the rep, degrees;
    // 180 = fully straight). Below this the lifter started the next descent
    // without standing up fully.
    static let lockoutKneeDegrees = 160.0

    // MARK: Elbow position (upper-arm angle from the torso line at the
    // bottom; 0° = arm hanging along the torso). Chinese cue: elbows down,
    // pointing at the floor, pinning the bar to the back — elbows swinging
    // up/back let the bar roll and tip the chest. First-pass thresholds from
    // high-bar grip geometry (elbows-down grip sits ~30–50°); set above the
    // 46–81° band measured on the 2026-07-07/08 *bodyweight* squat sessions
    // (arms held free) so those don't false-flag. Tune on barbell footage.
    static let elbowLiftWarningDegrees = 70.0
    static let elbowLiftRiskDegrees = 85.0

    // MARK: Balance (horizontal bar-over-midfoot offset at the bottom:
    // shoulder center vs ankle midpoint, as a fraction of hip width,
    // magnitude only). Bodyweight sessions measure a 0.34–0.7 noise floor
    // from the 45° camera; first-pass threshold sits above it. Tune on
    // barbell footage.
    static let balanceDriftWarningRatio = 0.9

    // MARK: Fatigue (relative depth loss between first and last reps)
    static let fatigueDepthLossFraction = 0.25

    // MARK: Smoothing
    static let smoothingWindow = 5

    // MARK: Track repair (see JointTrackRepair — runs on the raw series,
    // and only after TrackingQuality has been measured: cleaning first
    // would mask the very flicker the gate catches)
    /// Longest joint dropout bridged by interpolation (≈130 ms at 15 fps).
    /// Longer gaps are real occlusion — left missing, never invented.
    static let repairMaxGapFrames = 2
    /// Hampel half-window (samples each side of the judged one); matches
    /// the smoother's reach.
    static let repairSpikeWindow = 2
    /// Deviation from the window median, in MADs, that marks a tracking
    /// spike (the classic Hampel k = 3). Real articulation at 15 fps is
    /// monotone inside a 5-frame window, so its median deviation ≈ 0 —
    /// only detector flicker trips this.
    static let repairSpikeSigmas: Float = 3.0
    /// MAD floors so a still track (MAD ≈ 0) can't flag micro-noise: clean
    /// footage shows ~2–5 mm of per-frame position noise, so the smallest
    /// flaggable spike is 3 × 0.01 = 30 mm in model space and 3 × 0.005 =
    /// 1.5% of image height (~33 mm at a 2.2 m scale). First-pass values —
    /// finalize on real-footage replay.
    static let repairSpikeFloorMeters: Float = 0.01
    static let repairSpikeFloorImage: Float = 0.005

    // MARK: Live set tracking (2D image-space signals at ~10 Hz while
    // recording, driving spoken feedback only — the offline 3D analysis
    // remains the truth for the report). First-pass values.
    /// Seconds framing must hold green before the countdown auto-starts.
    static let liveFramingHoldSeconds: TimeInterval = 2.0
    /// Positioning give-up window; recording force-starts after it so a
    /// hard-to-detect position (lying on a bench) never strands the lifter.
    static let livePositioningTimeoutSeconds: TimeInterval = 90
    /// Squat rep hysteresis: the hip-midpoint drop below standing that
    /// enters/exits a rep, as fractions of the lifter's image-space body
    /// span (nose to ankles).
    static let liveSquatEntryDropFraction = 0.12
    static let liveSquatExitDropFraction = 0.06
    /// Normalized-image margin by which the hip midpoint must stay above
    /// the knee midpoint at the turnaround before the rep is called "high".
    static let liveSquatHighMargin = 0.02
    /// Bench rep hysteresis, as fractions of the rolling lockout
    /// (wrist–shoulder) distance.
    static let liveBenchEntryFraction = 0.75
    static let liveBenchExitFraction = 0.88
    /// Live entry-crossing→bottom time below which the descent was a free
    /// fall. The live clock starts at the entry crossing (~40–50% into the
    /// descent), so this is roughly half the offline 0.6 s eccentric
    /// minimum: a controlled 1.5 s descent measures ~0.8 s live, a drop
    /// measures ~0.2 s.
    static let liveFastDescentSeconds: TimeInterval = 0.45
    /// Live bottom→exit time beyond which the ascent was a grind (the
    /// bottom-to-near-standing crossing captures the full concentric).
    static let liveSlowAscentSeconds: TimeInterval = 2.5
    /// Median image-space torso lean over the in-rep window beyond which
    /// the torso folded. The 45° camera compresses projected lean, so this
    /// only fires on a real fold (~60°+): normal bottoms project ~15–25°.
    static let liveSquatFoldDegrees = 40.0
    /// Median image-space upper-arm angle from the torso line over the
    /// in-rep window beyond which the elbows swung up off the bar. A
    /// settled high-bar grip projects well under this; conservative so it
    /// only fires on elbows clearly climbing.
    static let liveElbowLiftDegrees = 75.0
    /// Bench bottom-dwell band (fraction of the lockout distance) and the
    /// dwell below which the touch was a bounce off the chest.
    static let liveBounceBandFraction = 0.05
    static let liveBounceMaxSeconds: TimeInterval = 0.15
    /// A bench rep whose depth falls below this fraction of the set's
    /// median rep depth was cut high (needs two reps of history).
    static let liveBenchCutHighFraction = 0.7
    /// Rolling window for the standing/lockout baseline (a decaying max):
    /// long enough to survive a slow rep, short enough to track drift.
    static let liveBaselineWindowSeconds: TimeInterval = 10
    /// Samples in the live transition median: rep entry/exit crossings are
    /// judged on the median of this many raw signals so a single flickered
    /// sample can't start or end a rep. Odd; 3 costs at most one sample
    /// (~100 ms at 10 Hz) of crossing latency.
    static let liveSignalMedianWindow = 3

    // MARK: Bar velocity (from the wrist image trajectory × LiDAR metric
    // scale; MCV = mean concentric velocity, the headline VBT number).
    /// Last-rep MCV this far below the set's best rep is the standard
    /// velocity-loss autoregulation cut — the "rack it" signal.
    static let velocityLossWarningFraction = 0.2
    /// Minimal velocity thresholds (m/s): the MCV of a true limit attempt,
    /// where the load–velocity line crosses into a miss. Literature-standard
    /// first-pass values per lift.
    static let squatMinimalVelocity = 0.30
    static let benchMinimalVelocity = 0.15
    static let deadliftMinimalVelocity = 0.25
    /// Bar-track spike gate: a sample deviating from its detrended 5-sample
    /// window median beyond sigmas × max(MAD, floor) is a detector mislock
    /// (the wrist lock jumped to a knee or plate) and is replaced by the
    /// window's estimate before velocity is derived. The floor (normalized
    /// image y) is ≈9 mm at a 2.2 m scale — above wrist noise, far below a
    /// mislock's jump; real bar motion is trend, which detrending removes
    /// from the judgment entirely. First-pass — validate on replayed
    /// sessions.
    static let barTrackSpikeSigmas = 3.0
    static let barTrackSpikeFloor = 0.004
    /// Scale-spike floor as a fraction of the track's median scale: a LiDAR
    /// hole jumps to the background (roughly a doubling, multiplying
    /// velocity directly) while steady reads wobble well under 1%.
    static let barTrackScaleSpikeFloorFraction = 0.01

    // MARK: - Deadlift
    // Standards: neutral spine throughout (the injury line), bar dragged up
    // the legs over the midfoot, hips and shoulders rising together off the
    // floor, full tall lockout, no bouncing the plates. First-pass values
    // to be tuned against real recordings.

    // Rep segmentation rides the range-normalized bench thresholds on the
    // wrist–ankle distance signal, with deadlift-specific timing: the set
    // starts with the bar on the floor, so windows are judged on their
    // ascent and the folded-in floor time is capped.
    /// Shortest plausible pull, floor to lockout.
    static let deadliftMinimumAscentSeconds: TimeInterval = 0.4
    /// Longest eccentric-plus-floor-dwell folded into one rep; anything
    /// earlier is setup, not the rep.
    static let deadliftMaxEccentricSeconds: TimeInterval = 6.0

    // Spine flexion: the angle at the spine joint between the root→spine
    // and spine→shoulder segments (180° = a straight line). Rounding under
    // load is THE deadlift injury mechanism — flexed lumbar tissue carries
    // shear the erectors should carry.
    /// Below this at any point of the pull the back is visibly rounding.
    static let deadliftSpineFlexionWarningDegrees = 155.0
    /// Below this the spine is clearly flexed under load — stop the set.
    static let deadliftSpineFlexionRiskDegrees = 140.0

    /// Peak horizontal wrist-to-ankle-midpoint offset during the pull, as a
    /// fraction of hip width. Bar drifting off the legs multiplies the
    /// lumbar moment arm — efficiency and injury in one number.
    static let deadliftBarGapWarningRatio = 0.8

    /// Hip rise ÷ shoulder rise over the first third of the ascent. Hips
    /// shooting up first turns the pull into a stiff-leg lift and dumps the
    /// load onto the lower back.
    static let deadliftHipShootRatio = 1.8

    /// Average knee extension at lockout (180 = straight); below this the
    /// pull stopped short of standing tall.
    static let deadliftLockoutKneeDegrees = 160.0

    /// Bottom dwell below which consecutive reps bounce off the plates
    /// instead of resetting — momentum, not strength, and a flexed catch.
    static let deadliftBouncePauseSeconds = 0.2

    // MARK: Overlay
    /// 2D joint confidence below which the skeleton overlay dims that
    /// joint's bones — drawn as a hint, not an assertion (repaired joints
    /// dim regardless; see `JointFrame.isUncertain`). Extraction accepts
    /// image points above 0.3, but the 0.3–0.5 band tracks while wandering.
    /// First-pass — check the on-footage confidence histogram before
    /// trusting it.
    static let overlayConfidenceFloor: Float = 0.5

    // MARK: Tracking quality gate
    /// Median relative bone-length jitter (see `TrackingQuality`) above which
    /// joint angles cannot be trusted: form rules are replaced by a single
    /// tracking-quality finding. Well-framed squat sessions measure
    /// 0.0003–0.0026; the badly framed 2026-07-08 bench recording, 0.035.
    static let trackingJitterGateRatio = 0.01
    /// Per-rep version of the gate (median of the jitter timeline over one
    /// rep's window): a rep above it has its form findings suppressed while
    /// the rest of the set stays judged. Starts equal to the global gate —
    /// per-rep windows are shorter and their medians noisier, so validate
    /// the per-rep distribution on pulled sessions before diverging.
    static let repTrackingJitterGateRatio = 0.01

    // MARK: - Bench press
    // Standards: bar touches the chest, elbows ~45–70° from the torso (not
    // flared to a T), controlled descent, no bounce, full elbow lockout.
    // Thresholds are first-pass values to be tuned against real recordings.

    // Rep segmentation. The wrist–shoulder distance never nears zero on a
    // real skeleton — the forearm keeps the wrist ~0.35–0.4 m from the
    // shoulder at a legit chest touch (~60–70% of the lockout distance) —
    // so bench hysteresis is normalized to the observed press range
    // (floor = 10th percentile of the signal ≈ touch, baseline = 90th ≈
    // lockout) instead of fractions of the lockout. That adapts to both
    // clean skeletons and compressed noisy ones. Tuned on the 2026-07-08
    // recording (8 real reps, segments 8/8) with the synthetic suite exact.
    /// Press range below this fraction of the lockout distance means nobody
    /// pressed — the lifter held the bar still, or the series is noise.
    static let benchMinimumRangeFraction = 0.10
    static let benchEntryRangeFraction = 0.30
    static let benchExitRangeFraction = 0.50
    static let benchStandingRangeFraction = 0.60

    /// Longest plausible bench rep, start back to lockout. Beyond this the
    /// window is a settling hold under the bar or several reps merged by
    /// tracking noise, not one rep (seen on device: a 9.5 s "rep" spanning
    /// the pre-set hold).
    static let benchMaximumRepDuration: TimeInterval = 6.0

    // Touch depth (average elbow flexion at the bottom, degrees;
    // 180 = arms straight). Deeper touch = smaller elbow angle.
    /// At or below this the bar is at/near the chest.
    static let benchFullTouchElbowDegrees = 95.0
    /// Above this the rep is clearly cut high (half rep).
    static let benchShallowElbowDegrees = 115.0

    // Elbow flare (upper-arm angle from the torso line at the bottom;
    // 0° = pinned to the side, 90° = T position). The safe window is an
    // "arrow" shape around 45–70°.
    static let benchFlareWarningDegrees = 78.0
    static let benchFlareRiskDegrees = 88.0
    /// Below this the elbows are pinned to the torso (over-tucked): the
    /// chest stops contributing, the wrists carry a longer moment arm, and
    /// the press path lengthens.
    static let benchOverTuckFlareDegrees = 40.0

    /// Forearm angle from vertical at the touch. Vertical forearms stack
    /// the bar over wrist over elbow; beyond this the force leaks
    /// horizontally — usually a grip-width or touch-point mismatch.
    static let benchForearmTiltWarningDegrees = 20.0

    /// Below this dwell at the bottom, a chest touch is a bounce.
    static let benchBouncePauseSeconds = 0.1

    /// Average elbow extension at the top of a rep (180 = straight);
    /// below this the press stopped short of lockout.
    static let benchLockoutElbowDegrees = 160.0

    // Bar path (head-ward wrist drift between touch and lockout, as a
    // fraction of shoulder width). The correct path is a J-curve: touch at
    // the lower chest, lock out over the shoulders — so moderate head-ward
    // drift is expected. Faults are pressing straight up (or toward the
    // feet) and an exaggerated sweep.
    static let benchBarPathMinimumRatio = 0.0
    static let benchBarPathWarningRatio = 0.9

    /// Spread of per-rep touch points (range of touch offsets across the
    /// set, as a fraction of shoulder width) beyond which the touch point is
    /// inconsistent.
    static let benchTouchSpreadWarningRatio = 0.3
}
