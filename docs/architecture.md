# Squatter architecture — agent reference

Read this before designing a feature; it replaces most code-reading and
dependency-graph reconstruction. One line of truth per fact — if code and
this doc disagree, fix the doc in the same commit.

## Dependency graph (who calls whom)

```
UI (HomeView routes)
 ├─ SetupGuideView → RecordView ──(RecordingResult)──▶ AttemptReviewView
 │        (live, while recording: FramingChecker → spoken framing gate;
 │         LiveRepCounter, a 2D-image-signal rep state machine with its
 │         thresholds in AnalysisTuning → SetVoice rep/fault callouts)
 │                                                     ├─ PlateDetector.detect (async, review-time)
 │                                                     └─ PlatePickerView ↔ PlateCatalog(Store)
 ├─ AttemptReviewView ──(RecordingResult, ActivityType)──▶ AnalysisView (AnalysisFlow.swift)
 │        AnalysisViewModel.run:
 │          PoseExtractor.extract(video, depthSidecar) ──▶ JointSeries
 │          SquatAnalyzer.analyze(series, activity, profile: BodyGeometryProfileStore.load())
 │          └─▶ SquatAnalysis ──▶ ReportView / saved as WorkoutSession (SwiftData)
 │                ReportView: PlayerOverlayView draws the skeleton, coloring
 │                  faulted parts red via FormFaultDetector (per-frame checks
 │                  with the FormRules thresholds); CoachSectionView →
 │                  CoachClient (KeyframeExtractor rep-bottom JPEGs →
 │                  Anthropic API), report cached by CoachReportStore
 ├─ BodyScanGuideView → RecordView → BodyScanResultView
 │        PoseExtractor.extract → SquatAnalyzer.profileScan → BodyGeometryProfile(Store)
 └─ SessionReportView (reopens saved sessions; can re-analyze)

SquatAnalyzer.analyze (pure, no I/O — the whole Analysis layer is UI-free):
  TrackingQuality.boneLengthJitter        (on smoothed *un-repaired* series! gate ≤ 0.01)
  TrackingQuality.frameJitterTimeline     (same series; per-rep medians → per-rep gate)
  JointTrackRepair.repaired               (fork: despike + gap-bridge the RAW series)
  JointSeriesSmoother.smoothed            (SG filter, window 5, over the repaired series)
  SquatAnalyzer.scanGeometry              (model-space bone lengths, standing frames)
  SquatAnalyzer.metricScan / profile      (metric femur/shin/…, image drops × LiDAR scale)
  SkeletonCorrector.corrected             (squat-only image anchor, see below)
  RepSegmenter.segment                    (lift signal per activity)
  MetricsCalculator.metrics               (per-rep RepMetrics + trackingJitter fill)
  VelocityCalculator (inside Metrics)     (MCV/peak from despiked barTrack × scale)
  FormRules.findings                      (over per-rep-trusted reps only, see below)
```

Type→file exceptions (everything else lives in `<TypeName>.swift`):
`JointSeriesSmoother` → `Smoothing.swift`; `PlatePickerView` →
`PlateWeightView.swift`; `SessionReportView` → private in `HomeView.swift`;
`AnalysisView`/`AnalysisViewModel` → `AnalysisFlow.swift`; `FrameFaults` →
`FormFaultDetector.swift`.

## Pipeline stages: inputs, outputs, invariants

| Stage | Key facts |
|---|---|
| `PoseExtractor` | Video+sidecar → `JointSeries`. 15 fps 3D pose + 2D image points; 30 fps `barTrack` (wrist-mid y). Sets per-frame `metersPerImageHeight` (LiDAR body plane × H / focal, pitch-corrected) and series-level `imageAspectRatio` (W/H), `bodyHeight` (measured, not the Vision prior). Resumes if the decoder dies mid-file (backgrounding). |
| `JointTrackRepair` | Pre-smoothing fork: detrended Hampel despike (median-slope detrend, else mid-rep motion inflates the MAD and spikes slip under) + linear bridging of ≤ 2-frame joint dropouts, `positions` and `imagePoints` independently. Every touched joint flagged in `JointFrame.repairedJoints`. **Runs after TrackingQuality is measured** — cleaning first would mask the flicker the gate catches. Repaired joints may never assert a fault: `MetricsCalculator`'s valgus/spine sweeps skip repaired frames (a real session's degenerate stretch passed the valgus sanity guards after despiking and minted a fake 0.5 risk reading), and the overlay dims them instead of drawing red. |
| `JointSeriesSmoother` | Quadratic Savitzky–Golay, window 5 (image points window 3). Preserves curvature — bottoms keep true depth. |
| `TrackingQuality` | Median frame-to-frame relative bone-length change. Clean squats 0.0002–0.003; gate at 0.01 replaces all findings with one "tracking unstable". **Computed before SkeletonCorrector and JointTrackRepair** — both would mask flicker. `frameJitterTimeline` + `repJitter` localize it: per-rep medians gate single reps (`repTrackingJitterGateRatio`, also 0.01) when the global gate passes — suppressed reps keep metrics/velocity but are excluded from FormRules, named in one info finding, and caveated in the coach prompt. Replay: clean-session rep windows measure 0.0003–0.0054, the broken 2026-07-08 bench windows 0.017–0.086 — 0.01 sits in the gap. Dropout-only breakage reads as *clean* jitter (missing bones don't register), so the per-rep gate catches flicker, not occlusion. |
| `BodyGeometry` / `MetricBodyGeometry` | Scanned from standing frames (lift signal ≥ 97% of baseline). Model-space bone lengths anchor the corrector's femur length; metric lengths come from the vertical-drop trick (below). `profileScan` additionally reads deep-hold frames (signal ≤ 75% baseline) → `deepestHipBelowKneeDegrees`. |
| `SkeletonCorrector` | Squat+LiDAR only. sin(femur elevation) = image-y drop × scale ÷ metric femur; pelvis (root+hips, rigid) re-posed to it. **Deepen-only** and **only when the model is already deep** (`geometryAnchorModelSineFloor`) — both rules earned on real footage (tilted-camera session lost 30°; standing 2D glitches minted phantom reps). There is no bone-length constraint pass: real Vision output is length-consistent; a length pass was built, proven a no-op on clean footage and harmful on broken stretches, and removed. |
| `RepSegmenter` | Signal per lift: squat = hip-above-ankle distance, bench = wrist–shoulder distance, deadlift = wrist–ankle distance. Standing baseline = 90th percentile. |
| `MetricsCalculator` | Per-rep `RepMetrics`. Squat depth = `hipBelowKneeDegrees` (femur vs horizontal, + = below parallel). `stanceWidthRatio` is **image-x spans** (see facts), nil from side views. `VelocityCalculator` cleans a **local copy** of the stored-raw `barTrack` at consumption (detrended Hampel on y and scale, quadratic SG on interior y, edge samples never smoothed — they anchor mean velocity): a single mislocked wrist sample otherwise fakes a multi-m/s peak (real sessions: 5.03 → 2.21, 3.51 → 3.10; clean-set MCV shifts ≤ 1.3%). |
| `FormRules` | Thresholds all in `AnalysisTuning`. Squat judged vs Chinese high-bar practice; `depthReference` (profile deep hold) personalizes the full-depth line (capped by the absolute standard) and adds "Depth in reserve". |
| `PlateDetector` | Review-time, not pipeline. 2D wrists → bar line → sleeve crops; depth sampled **at each sleeve** (near/far differ ~1 m at 45°); plate faces = ellipses, vertical axis = true diameter; ring-pixel color vote. Emits diameter+color *classes*, never counts (identical plates stack invisibly). Untuned on real footage: gates conservative, failure mode is silence. |

## Persistence (backward compatibility is law)

- `WorkoutSession` (SwiftData, `default.store`): stores full `SquatAnalysis`
  JSON in `analysisData` + `weightKg`, `activityRaw`. **Every new field on
  `SquatAnalysis`/`RepMetrics`/`Finding`/`JointSeries`/`JointFrame` must be
  optional or defaulted** — old sessions must decode. Optional-by-law fields
  so far: `JointFrame.jointConfidences` (2D detector, the 3D observation
  exposes none) + `.repairedJoints`, `RepMetrics.trackingJitter`; nil maps =
  pre-upgrade session, treated as fully confident.
- `Application Support/body-geometry.json` → `BodyGeometryProfile`
  (`MetricBodyGeometry` + `scannedAt` + `heightMeters`). Loaded per analysis;
  **overrides** in-session scans. Saving a scan replaces it wholesale.
- `Application Support/plate-catalog.json` → `PlateCatalog` (barWeightKg +
  `PlateSpec[]`: weight, diameter, optional `PlateColor`).
- `Application Support/Recordings/<uuid>.mov` + `<uuid>.depth` (LiDAR
  sidecar) — the recordings themselves, base-named by `FileLocations`.
  `<uuid>.coach` beside them caches the fetched LLM report
  (`CoachReportStore`) until the user regenerates it.
- Anthropic API key: Keychain via `CoachKeyStore` — never UserDefaults,
  source, or the binary.
- `UserDefaults`: `lastWeightKg.<activity>` prefill; `SetVoice` enabled flag.
- Dates in hand-written JSON: Swift default = seconds since 2001-01-01.

## Measured facts (do not re-derive; sourced from real device sessions)

- **Vision 3D model proportions are priors, not measurements**: shoulder
  width ≈ 0.34 m and hip width ≈ 0.31 m on *every* session regardless of the
  lifter (Yarik's real: shoulders 0.428, hips 0.372). Never judge body
  proportions in model space — use 2D image spans (ratios are yaw-invariant
  for frontal-plane widths) or metric image measurements.
- **Vertical-drop trick**: a standing bone hangs vertical, so image-y drop ×
  `metersPerImageHeight` is its true length — no aspect ratio, no camera
  yaw dependence. Horizontal metric spans additionally need
  `imageAspectRatio` (Δmeters = Δx × aspect × scale).
- **Deep-squat pose bias**: Vision keeps bone lengths to ~0.02% but poses
  the pelvis high at depth → hipBelowKnee read ~−15° on true full-depth
  reps. Only the 2D points see the truth. Trust the deeper of model vs
  image (model never exaggerates depth; image goes shallow under pitch/2D
  glitches).
- Yarik's ground truth (professional anthropometry, seeded into the device
  profile): height 1.799 m, femur 0.429, shin 0.415, shoulders 0.428, hips
  0.372, upper arm 0.339, forearm 0.259. In-session metric femur scans
  measured 0.41–0.47 (straddling truth) — the controlled scan/profile exists
  because of that spread.
- Loaded vs unloaded depth calibration is **circular** if taken from a
  session's own bottoms — only the dedicated scan flow measures the
  deep-hold reference.
- **A Hampel filter without detrending misses real spikes**: mid-rep joints
  move several window-widths per second, the in-window trend inflates the
  MAD, and a measured +0.2 image spike slipped under 3 MADs. Median-slope
  detrend first (`JointTrackRepair`, `VelocityCalculator`); after it, steady
  motion of any speed deviates ≈ 0.
- **Repaired data may not assert faults**: despiking s17's broken rep-9
  stretch made degenerate frames pass `maxValgus`'s sanity guards → fake
  0.51 (risk-level) valgus. Fault-sweeping metrics skip repaired frames;
  the overlay draws uncertain bones dim, never red.

## Feature recipes

- **New per-rep metric**: optional field on `RepMetrics` → compute in
  `MetricsCalculator` → threshold in `AnalysisTuning` → rule in `FormRules`
  → mention in `CoachPrompt` (embeds live thresholds) → test in
  `SquatterTests` with the `Synthetic*` generators (they support image
  points, metric scale, camera yaw, pose bias, T-pose arms).
- **New lift**: `ActivityType` case → lift signal in `RepSegmenter` →
  metrics branch → rules branch → synthetic generator + tests. Thresholds
  start synthetic-only; real footage tunes them.
- **Anything reading body measurements**: prefer `BodyGeometryProfile`
  (controlled) over session scans; check `quality` against
  `geometryScanQualityGate`.
- **Tuning thresholds**: never tune on synthetic alone if real footage
  exists — pull sessions and replay (below).

## Real-footage replay workflow

1. Pull: `xcrun devicectl device copy from --device <udid> --domain-type
   appDataContainer --domain-identifier com.yarik.squatter --source
   "Library/Application Support/<path>" --destination <dir>` — paths:
   `Recordings/` (videos + `.depth` sidecars), `default.store*` (SwiftData).
   `copy to` works the same direction for **seeding** profile/catalog JSON.
2. Extract analyses: `sqlite3 default.store "SELECT writefile('s.json',
   ZANALYSISDATA) FROM ZWORKOUTSESSION WHERE Z_PK=<n>"`.
3. Replay standalone on macOS (no phone, no Xcode) — compile a `main.swift`
   that decodes `SquatAnalysis` and re-runs any pipeline stage:

   ```sh
   swiftc -O -o replay main.swift Squatter/Analysis/*.swift \
     Squatter/Models/ActivityType.swift Squatter/Models/FormHintTopic.swift \
     Squatter/Models/BodyGeometryProfile.swift Squatter/Models/PlateCatalog.swift \
     Squatter/Capture/DepthSidecar.swift
   ```

   The stored `series` is the device-extracted (smoothed) ground truth;
   macOS Vision ≠ iOS Vision, so re-extracting on Mac is only for rough
   checks. Swift encodes `[BodyJoint: SIMD]` dictionaries as flat
   `[key, value, …]` arrays in JSON (Python: pairwise-unpack).
4. Simulator tests failing with "Busy / Application failed preflight
   checks": `xcrun simctl shutdown all`, retry.

## Session/device notes

- Devices: iPhone 16 Pro Max "tts0" (LiDAR, primary test device), iPhone 11
  Pro (no LiDAR). LiDAR-only features must degrade silently without depth.
- 1RM estimate: Progress dashboard, single-lift filter, needs ≥3 distinct
  logged loads spanning ≥10 kg with velocity data (`LoadVelocityProfile`).
