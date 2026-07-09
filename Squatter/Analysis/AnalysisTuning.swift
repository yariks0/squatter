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

    // MARK: Torso lean at the bottom (degrees from vertical).
    // High-bar standard: torso close to vertical (a deep upright squat sits
    // around 25–35°), so lean is caught early.
    static let torsoLeanWarningDegrees = 40.0
    static let torsoLeanRiskDegrees = 50.0

    // MARK: Knee valgus (medial knee deviation / hip width)
    static let valgusWarningRatio = 0.18
    static let valgusRiskRatio = 0.32

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

    // MARK: Stance (ankle separation / shoulder width, measured standing at
    // the start of a rep). High-bar standard: heels around shoulder width so
    // the hips can sit between the legs — hip-width down to ~0.7 is fine,
    // inside that is too narrow to reach depth upright.
    static let stanceNarrowRatio = 0.7
    static let stanceWideRatio = 1.7

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

    // MARK: Tracking quality gate
    /// Median relative bone-length jitter (see `TrackingQuality`) above which
    /// joint angles cannot be trusted: form rules are replaced by a single
    /// tracking-quality finding. Well-framed squat sessions measure
    /// 0.0003–0.0026; the badly framed 2026-07-08 bench recording, 0.035.
    static let trackingJitterGateRatio = 0.01

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
