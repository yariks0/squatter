import SwiftUI

/// One measured bone with the typical human range for the lifter's height
/// (Drillis & Contini segment fractions ±10%) so a bad scan is visible at
/// a glance — a flagged value means "rescan", not "unusual body".
private struct MeasurementRow: View {
    let name: String
    let meters: Double
    let heightMeters: Double?
    /// Typical segment length as a fraction of standing height.
    let heightFraction: Double

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(BodyScanGuideView.centimeters(meters))
                if let expected {
                    Text("typical \(Int(expected.lowerBound * 100))–\(Int(expected.upperBound * 100)) cm")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(name)
                if let expected, !expected.contains(meters) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var expected: ClosedRange<Double>? {
        guard let heightMeters else { return nil }
        let center = heightMeters * heightFraction
        return (center * 0.9) ... (center * 1.1)
    }
}

/// Rows for every measurement a `MetricBodyGeometry` may carry, evaluated
/// against the scan height when known.
private struct MeasurementList: View {
    let metric: MetricBodyGeometry
    let heightMeters: Double?

    var body: some View {
        // Segment fractions of stature after Drillis & Contini.
        MeasurementRow(name: "Femur", meters: metric.femurMeters,
                       heightMeters: heightMeters, heightFraction: 0.245)
        MeasurementRow(name: "Shin", meters: metric.shinMeters,
                       heightMeters: heightMeters, heightFraction: 0.246)
        if let torso = metric.torsoMeters {
            MeasurementRow(name: "Upper body", meters: torso,
                           heightMeters: heightMeters, heightFraction: 0.288)
        }
        if let width = metric.shoulderWidthMeters {
            MeasurementRow(name: "Shoulders", meters: width,
                           heightMeters: heightMeters, heightFraction: 0.259)
        }
        if let width = metric.hipWidthMeters {
            MeasurementRow(name: "Hips", meters: width,
                           heightMeters: heightMeters, heightFraction: 0.191)
        }
        if let upper = metric.upperArmMeters {
            MeasurementRow(name: "Upper arm", meters: upper,
                           heightMeters: heightMeters, heightFraction: 0.186)
        }
        if let forearm = metric.forearmMeters {
            MeasurementRow(name: "Forearm", meters: forearm,
                           heightMeters: heightMeters, heightFraction: 0.146)
        }
        if let deepest = metric.deepestHipBelowKneeDegrees {
            LabeledContent("Deepest squat") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%+.0f°", deepest))
                    Text("hip below knee, unloaded")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The body profile page: current measurements evaluated against typical
/// proportions, plus the instructions and entry point for a (re)scan.
struct BodyScanGuideView: View {
    let onStart: () -> Void
    @State private var profile = BodyGeometryProfileStore.load()

    var body: some View {
        List {
            if let profile {
                Section {
                    if let height = profile.heightMeters {
                        LabeledContent("Height", value: BodyScanGuideView.centimeters(height))
                    }
                    MeasurementList(metric: profile.metric, heightMeters: profile.heightMeters)
                    LabeledContent("Scan noise", value: String(
                        format: "±%.1f cm", profile.metric.quality * profile.metric.femurMeters * 100
                    ))
                    LabeledContent("Scanned", value: profile.scannedAt.formatted(date: .abbreviated, time: .omitted))
                } header: {
                    Text("Your measurements")
                } footer: {
                    Text("Flagged values fall outside the typical range for your height — usually a scan problem, not your body. Rescan if anything looks off.")
                }
                Section {
                    Button("Remove profile", role: .destructive) {
                        BodyGeometryProfileStore.clear()
                        self.profile = nil
                    }
                }
            }
            Section("Set up") {
                Label("Use the LiDAR (rear) camera, phone held level — prop it at hip height if you can.", systemImage: "camera.metering.center.weighted")
                Label("Stand about 3 m away, whole body in frame.", systemImage: "figure.stand")
            }
            Section("One recording, three poses") {
                Label("Face the camera with your arms straight out to the sides, like a T. Hold for five seconds.", systemImage: "figure.arms.open")
                Label("Turn side-on, arms down, and hold still for five seconds.", systemImage: "figure.stand")
                Label("Still side-on, sit into your deepest squat, arms forward, and hold for five seconds.", systemImage: "figure.cross.training")
            }
            Section {
                Text("The frontal pose measures shoulder and hip width and your arm segments; the side pose measures thigh, shin, and upper-body lengths; the deep hold records your own full-depth reference. Every set you record afterwards is judged against your real proportions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                onStart()
            } label: {
                Label(profile == nil ? "Start scan" : "Rescan", systemImage: "person.and.background.dotted")
            }
            .buttonStyle(KodoProminentButtonStyle())
            .padding(.bottom, 8)
        }
        .navigationTitle("Body profile")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func centimeters(_ meters: Double) -> String {
        String(format: "%.1f cm", meters * 100)
    }
}

/// Runs pose extraction over the scan recording, measures the metric
/// geometry, and saves the profile. The scan clip is discarded either way —
/// it is a measurement, not a workout.
struct BodyScanResultView: View {
    enum Phase {
        case processing
        case measured(MetricBodyGeometry, heightMeters: Double?)
        case failed(String)
    }

    let recording: RecordingResult
    let onDone: () -> Void
    @State private var phase: Phase = .processing

    var body: some View {
        Group {
            switch phase {
            case .processing:
                VStack(spacing: 20) {
                    ProgressView()
                    Text("Measuring your body geometry…")
                        .font(.headline)
                }
            case .measured(let metric, let height):
                List {
                    Section("Measured") {
                        if let height {
                            LabeledContent("Height", value: BodyScanGuideView.centimeters(height))
                        }
                        MeasurementList(metric: metric, heightMeters: height)
                        LabeledContent("Scan noise", value: String(format: "±%.1f cm", metric.quality * metric.femurMeters * 100))
                    }
                    if metric.shoulderWidthMeters == nil {
                        Section {
                            Label("No frontal segment found — shoulder/hip widths and arms weren't measured. Rescan starting face-on to the camera, arms out like a T.", systemImage: "person.crop.rectangle.badge.plus")
                                .font(.footnote)
                        }
                    } else if metric.upperArmMeters == nil {
                        Section {
                            Label("Arms weren't measured — hold them straight out to the sides during the frontal pose.", systemImage: "figure.arms.open")
                                .font(.footnote)
                        }
                    }
                    if metric.quality > AnalysisTuning.geometryScanQualityGate / 2 {
                        Section {
                            Label("The scan is usable but noisy — a steadier stance or a propped phone gives a cleaner profile.", systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        try? BodyGeometryProfileStore.save(BodyGeometryProfile(
                            metric: metric, scannedAt: .now, heightMeters: height
                        ))
                        onDone()
                    } label: {
                        Label("Save profile", systemImage: "checkmark")
                    }
                    .buttonStyle(KodoProminentButtonStyle())
                    .padding(.bottom, 8)
                }
            case .failed(let message):
                ContentUnavailableView(
                    "Scan failed",
                    systemImage: "person.slash",
                    description: Text(message)
                )
            }
        }
        .navigationTitle("Scan result")
        .navigationBarTitleDisplayMode(.inline)
        .task { await measure() }
        .onDisappear { discardRecording() }
    }

    private func measure() async {
        guard case .processing = phase else { return }
        guard recording.usedLiDAR else {
            phase = .failed("The body scan needs the LiDAR camera for metric scale — record on a Pro device with depth enabled.")
            return
        }
        do {
            let series = try await PoseExtractor.extract(
                videoURL: recording.videoURL,
                depthSidecarURL: recording.depthSidecarURL,
                timeRange: recording.analysisRange,
                progress: { _ in }
            )
            if let metric = SquatAnalyzer.profileScan(of: series),
               metric.quality <= AnalysisTuning.geometryScanQualityGate {
                phase = .measured(metric, heightMeters: series.bodyHeight.map(Double.init))
            } else {
                phase = .failed("Couldn't get a stable measurement — make sure your whole body stays in frame and hold still, then rescan.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func discardRecording() {
        try? FileManager.default.removeItem(at: recording.videoURL)
        if let sidecar = recording.depthSidecarURL {
            try? FileManager.default.removeItem(at: sidecar)
        }
    }
}
