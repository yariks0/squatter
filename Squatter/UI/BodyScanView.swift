import SwiftUI

/// Instructions for the one-time body scan: a short standing recording in a
/// controlled setup. The measured metric bone lengths become the
/// `BodyGeometryProfile` every later session is anchored to.
struct BodyScanGuideView: View {
    let onStart: () -> Void
    @State private var profile = BodyGeometryProfileStore.load()

    var body: some View {
        List {
            if let profile {
                Section("Current profile") {
                    LabeledContent("Femur", value: Self.centimeters(profile.metric.femurMeters))
                    LabeledContent("Shin", value: Self.centimeters(profile.metric.shinMeters))
                    LabeledContent("Scanned", value: profile.scannedAt.formatted(date: .abbreviated, time: .omitted))
                    Button("Remove profile", role: .destructive) {
                        BodyGeometryProfileStore.clear()
                        self.profile = nil
                    }
                }
            }
            Section("Set up") {
                Label("Use the LiDAR (rear) camera, phone held level — prop it at hip height if you can.", systemImage: "camera.metering.center.weighted")
                Label("Stand side-on about 3 m away, whole body in frame.", systemImage: "figure.stand")
                Label("Stand still for the whole recording — around ten seconds.", systemImage: "timer")
            }
            Section {
                Text("The scan measures your true thigh and shin lengths. Every set you record afterwards is corrected against them, which sharpens depth angles at the bottom of a squat.")
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
        .navigationTitle("Body scan")
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
        case measured(MetricBodyGeometry)
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
            case .measured(let metric):
                List {
                    Section("Measured") {
                        LabeledContent("Femur", value: BodyScanGuideView.centimeters(metric.femurMeters))
                        LabeledContent("Shin", value: BodyScanGuideView.centimeters(metric.shinMeters))
                        LabeledContent("Scan noise", value: String(format: "±%.1f cm", metric.quality * metric.femurMeters * 100))
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
                        try? BodyGeometryProfileStore.save(
                            BodyGeometryProfile(metric: metric, scannedAt: .now)
                        )
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
            if let metric = SquatAnalyzer.metricScan(of: series, activity: .squat),
               metric.quality <= AnalysisTuning.geometryScanQualityGate {
                phase = .measured(metric)
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
