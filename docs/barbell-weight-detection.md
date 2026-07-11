# Automatic barbell weight detection — design

> Design rationale and phasing only. Implementation truth (current gates and
> behavior) lives in the `PlateDetector` row of `docs/architecture.md` —
> update that, not this, when the code changes.

Goal: prefill `WorkoutSession.weightKg` from the recording itself so the
load–velocity profile and 1RM estimate work without manual entry. The bar is
assumed to be a standard 20 kg bar (user-overridable setting; 15 kg women's
bar as the alternative); everything else is read off the plates.

Detected weight is always a **suggestion**: it prefills the weight field in
the review UI with the breakdown shown ("20 + 2 × (25 + 10) = 90 kg") and one
tap edits it. Low confidence leaves the field empty rather than guessing.

## Signal

Total = bar (20 kg assumed) + 2 × one sleeve's plates (+ 5 kg when
competition collars are detected). Symmetric loading is assumed; only the
better-visible sleeve is read.

Plate identity comes from two independent features:

1. **Metric diameter.** Full-size competition bumpers (25/20/15/10 kg) are
   all 450 mm; change plates step down in diameter. The depth sidecar gives
   pixels→mm directly at the plate's plane — sample `DepthSidecar` at the
   plate region itself, not the body-plane `metersPerImageHeight` (the
   plates sit ~half a bar off the body plane on a side view). Depth is
   sampled directly, never handed to Vision (see CLAUDE.md).
2. **Color (IWF code).** 25 red, 20 blue, 15 yellow, 10 green, 5 white;
   change plates repeat the colors at small diameters, which is why diameter
   must disambiguate. All-black gym plates defeat color classification —
   then only diameter + band counting applies and confidence drops.

## Pipeline

1. **Keyframe selection.** A frame from the setup phase where the bar is
   stationary (variance of the existing 30 fps `barTrack` near zero) before
   the first rep's descent. Several candidate frames are scored; the one
   with the largest un-occluded plate area wins.
2. **Bar localization.** The 2D wrist points give the grip; the bar axis is
   the line through the wrists (squat: behind the neck, roughly through the
   shoulder line). Sleeves and plates sit outside the grip along that axis.
3. **Plate segmentation.** Crop each sleeve region and run
   `VNDetectContoursRequest`; plates are the large near-circular contours
   (face-on view) or vertical color bands (edge-on view) centered on the
   sleeve.
   - *Face-on* (camera perpendicular to the lifter): the outermost plate
     hides the inner ones. Read the outermost plate's color + metric
     diameter, then count the stack by the visible sleeve length consumed
     (plate thicknesses per class from a small per-manufacturer table,
     calibrated against real footage — bumper thickness varies too much to
     hardcode from spec sheets).
   - *Edge-on* (camera in front / 45°): each plate is a colored band; count
     bands and classify each by hue, with band width as a thickness sanity
     check.
4. **Scoring.** Each plate hypothesis carries a confidence (hue match ×
   diameter match × geometric consistency). Sleeve total confidence is the
   product; below a threshold the suggestion is dropped.
5. **Velocity cross-check.** When a fitted `LoadVelocityProfile` exists for
   the lift, invert it: the set's best mean concentric velocity predicts a
   load. Disagreement beyond ~15 % flags the detection (shown as a "check
   weight?" hint), agreement boosts confidence. Cheap, uses code that
   already ships.

## Phasing

- **Phase 1 (shipped):** manual `weightKg` entry feeding the LVP.
- **Phase 2 (shipped, diameter-first + color tie-break):** implemented as
  `PlateDetector` + `PlateCatalog` + `PlatePickerView`. Two strategies
  compose: recognition is **by diameter** against a *user-taught catalog*
  (weight + diameter per plate — all-black gym iron classifies by size
  alone; unknown detected diameters open a teach sheet — the system
  measures, the user names the weight), with **color as the tie-breaker**
  (`PlateColor` pixel voting on the plate face) for standard sets where
  every full-size bumper is 450 mm and only the IWF code separates
  25/20/15/10. A one-tap standard IWF set seeds the catalog; ambiguity
  without a color signal still refuses to guess. The detector reports plate
  *classes* seen on the bar, never counts (identical plates stack
  invisibly); matched classes preselect chips in a per-side plate
  calculator and the user sets counts. Plate depth is sampled from the
  sidecar at each sleeve (the near/far sleeve differ by ~1 m at 45°), and
  diameters are measured on the ellipse's vertical axis (yaw-invariant),
  pitch-corrected. Untuned against real footage yet — gates are
  conservative, silence is the failure mode.
- **Phase 3:** contour-gate tuning on real recordings, stack counting via
  sleeve occupancy, collar detection, velocity cross-check
  (`LoadVelocityProfile` inversion) to flag implausible entries.

## Non-goals / assumptions

- Kilogram plates only (no lb sets) for now — matches the app's units.
- No attempt to read plates mid-rep; only the stationary setup frame.
- Asymmetric loading is out of scope; the UI breakdown makes a wrong
  symmetric assumption obvious to the user.
