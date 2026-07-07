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

    // MARK: Fatigue (relative depth loss between first and last reps)
    static let fatigueDepthLossFraction = 0.25

    // MARK: Smoothing
    static let smoothingWindow = 5
}
