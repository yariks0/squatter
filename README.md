# Squatter

iOS squat-form coach: record a set with the camera (plus LiDAR depth on Pro
devices), get a post-set report with per-rep metrics and coaching feedback —
a safety net for training alone.

Form standards follow Chinese weightlifting team practice: full depth (hip
crease below the knee), near-vertical torso, knees tracking over the toes,
controlled descent.

## How it works

1. **Capture** (`Squatter/Capture/`) — `AVCaptureSession` records HEVC video.
   On LiDAR devices (iPhone 12 Pro and later Pros) synchronized depth frames
   are written to a `.depth` sidecar. A live 2D pose check shows a
   full-body-in-frame indicator while you set up.
2. **Analysis** (`Squatter/Analysis/`) — after the set, Vision's
   `VNDetectHumanBodyPose3DRequest` runs over the video (fed `AVDepthData`
   from the sidecar when available), producing a 17-joint 3D series →
   smoothing → rep segmentation → per-rep metrics (depth, torso lean, knee
   valgus, tempo, symmetry) → rule-based findings. Thresholds live in
   `AnalysisTuning.swift`.
3. **Report** (`Squatter/UI/`) — score, per-rep cards, coaching notes, and
   video playback with the tracked skeleton overlaid. Sessions persist via
   SwiftData (`WorkoutSession`), including the full analysis JSON so reports
   re-render and can be re-scored after threshold tuning.

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

- iPhone 16 Pro Max: LiDAR depth feeds the pose request for better accuracy.
- iPhone 11 Pro: no LiDAR (TrueDepth is front-facing, too short-ranged at
  squat distance); runs the identical pipeline RGB-only.
