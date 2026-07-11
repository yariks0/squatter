# Squatter

iOS lifting-form coach: record a set of squat, bench, or deadlift with the
camera (plus LiDAR depth on Pro devices), get a post-set report with per-rep
metrics, rule-based findings, and optional LLM coaching — a safety net for
training alone.

Squat form standards follow Chinese weightlifting (high-bar) practice: full
depth (hip crease below the knee), near-vertical torso, knees tracking over
the toes, controlled descent — personalized by an optional body scan so the
app never demands more depth than the lifter's measured mobility.

## How it works

1. **Capture** (`Squatter/Capture/`) — `AVCaptureSession` records HEVC video.
   On LiDAR devices (iPhone 12 Pro and later Pros) synchronized depth frames
   are written to a `.depth` sidecar. Live 2D pose checks drive a
   full-body-in-frame indicator plus an optional voice coach that counts
   reps and calls out faults as you lift.
2. **Analysis** (`Squatter/Analysis/`) — after the set, Vision's
   `VNDetectHumanBodyPose3DRequest` runs over the video, producing a
   17-joint 3D series (sidecar depth is sampled directly off the depth maps
   for metric scale — never fed to Vision, which crashes on depth without
   calibration) → smoothing → skeleton correction → rep segmentation →
   per-rep metrics (depth, torso lean, knee valgus, tempo, symmetry, bar
   velocity) → rule-based findings. Thresholds live in
   `AnalysisTuning.swift`.
3. **Report** (`Squatter/UI/`, `Squatter/Coach/`) — score, per-rep cards,
   video playback with the tracked skeleton overlaid (faulted body parts
   drawn red), and optional coaching notes from the Anthropic API built on
   the metrics and rep-bottom keyframes. Sessions persist via SwiftData
   (`WorkoutSession`), including the full analysis JSON so reports re-render
   and can be re-scored after threshold tuning.

Beyond the core loop: a three-pose **body scan** measures the lifter's real
segment lengths and depth mobility to personalize judging; a **plate
detector** reads plate classes off the bar at review time to speed up weight
entry; logged loads with bar velocity build a load–velocity profile and a
**1RM estimate** on the progress dashboard.

## Building

Requires Xcode 26+. The `.xcodeproj` is generated and gitignored:

```sh
brew install xcodegen
xcodegen generate
open Squatter.xcodeproj
```

Run on a device (camera required; analysis of an existing recording works in
the simulator): select your team under Signing & Capabilities, enable
Developer Mode on the phone, build & run. With a free Apple ID the install
expires after 7 days — re-run from Xcode.

Tests (pure-Swift analysis pipeline against synthetic squat fixtures):

```sh
xcodebuild -project Squatter.xcodeproj -scheme Squatter \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

## Device notes

- iPhone 16 Pro Max: LiDAR depth provides metric scale for body measurements,
  bar velocity, and plate diameters.
- iPhone 11 Pro: no LiDAR (TrueDepth is front-facing, too short-ranged at
  squat distance); runs the identical pipeline RGB-only.
