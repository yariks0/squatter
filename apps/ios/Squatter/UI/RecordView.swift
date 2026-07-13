import AudioToolbox
import AVFoundation
import SwiftUI
import UIKit

@MainActor
@Observable
final class RecordingViewModel {
    enum Phase: Equatable {
        case preparing
        case ready
        /// Waiting for the lifter to walk into frame; spoken guidance runs
        /// and the countdown auto-starts once framing holds green.
        case positioning
        case countdown(Int)
        case recording
        case finishing
        case failed(String)
    }

    private(set) var phase: Phase = .preparing
    private(set) var framing: FramingChecker.Status = .noBody
    private(set) var elapsed: TimeInterval = 0
    private(set) var usesLiDAR = false
    private(set) var liveRepCount = 0

    let camera = CameraService()
    let voice = SetVoice()
    private var framingChecker: FramingChecker?
    private var repCounter: LiveRepCounter
    private var timerTask: Task<Void, Never>?
    private let activity: ActivityType
    private let onFinished: (RecordingResult) -> Void

    init(activity: ActivityType = .squat, onFinished: @escaping (RecordingResult) -> Void) {
        self.activity = activity
        self.onFinished = onFinished
        self.repCounter = LiveRepCounter(activity: activity)
    }

    func start() async {
        guard await CameraService.requestPermission() else {
            phase = .failed(CameraService.CameraError.permissionDenied.localizedDescription)
            return
        }
        let checker = FramingChecker(activity: activity, onStatus: { [weak self] status in
            Task { @MainActor in self?.updateFraming(status) }
        }, onPose: { [weak self] sample in
            Task { @MainActor in self?.handlePose(sample) }
        })
        framingChecker = checker
        camera.frameSink = { [weak checker] buffer in checker?.submit(buffer) }
        do {
            try await camera.start()
            usesLiDAR = camera.hasLiDAR
            phase = .ready
            // The lifter is meters away mid-set; don't let the screen lock.
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func updateFraming(_ status: FramingChecker.Status) {
        framing = status
        if phase == .positioning {
            voice.speakGuidance(status.message)
        }
    }

    private func handlePose(_ sample: LivePoseSample) {
        switch phase {
        case .positioning where framing == .fullBodyVisible:
            repCounter.calibrate(with: sample)
        case .recording:
            guard case let .repCompleted(count, faults) = repCounter.ingest(sample) else { return }
            liveRepCount = count
            voice.speak(CoachScript.repLine(count: count, faults: faults), interrupting: true)
        default:
            break
        }
    }

    /// Start-set flow: wait in `.positioning` until framing holds green for
    /// `liveFramingHoldSeconds`, then count down and record. A timeout
    /// force-starts so a hard-to-detect position never strands the lifter.
    func beginPositioning() {
        guard phase == .ready else { return }
        phase = .positioning
        voice.speak("Get into position")
        timerTask = Task { [self] in
            let started = Date()
            var greenSince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.25))
                guard phase == .positioning else { return }
                if framing == .fullBodyVisible {
                    greenSince = greenSince ?? Date()
                    if Date().timeIntervalSince(greenSince!) >= AnalysisTuning.liveFramingHoldSeconds {
                        await runCountdown()
                        return
                    }
                } else {
                    greenSince = nil
                }
                if Date().timeIntervalSince(started) > AnalysisTuning.livePositioningTimeoutSeconds {
                    voice.speak("Couldn't confirm framing — starting anyway")
                    await runCountdown()
                    return
                }
            }
        }
    }

    /// Positioning escape hatch: skip the framing gate.
    func forceStart() {
        guard phase == .positioning else { return }
        timerTask?.cancel()
        timerTask = Task { [self] in await runCountdown() }
    }

    func cancelPositioning() {
        guard phase == .positioning else { return }
        timerTask?.cancel()
        voice.finish()
        phase = .ready
    }

    private func runCountdown() async {
        for tick in stride(from: 3, through: 1, by: -1) {
            phase = .countdown(tick)
            voice.speak("\(tick)", interrupting: true)
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
        }
        await beginRecording()
    }

    private func beginRecording() async {
        do {
            try await camera.startRecording()
            // Audible confirmation that the set is being recorded (the
            // system begin-record chime), heard from squat distance.
            AudioServicesPlaySystemSound(1113)
            phase = .recording
            elapsed = 0
            liveRepCount = 0
            timerTask = Task { [self] in
                let start = Date()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(0.5))
                    elapsed = Date().timeIntervalSince(start)
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func stopAndFinish() async {
        guard phase == .recording else { return }
        timerTask?.cancel()
        voice.finish()
        phase = .finishing
        do {
            let result = try await camera.stopRecording()
            camera.stop()
            onFinished(result)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        timerTask?.cancel()
        voice.finish()
        camera.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

struct RecordView: View {
    @State private var model: RecordingViewModel
    @AppStorage(SetVoice.enabledDefaultsKey) private var voiceEnabled = true
    @Environment(\.dismiss) private var dismiss

    init(activity: ActivityType = .squat, onFinished: @escaping (RecordingResult) -> Void) {
        _model = State(initialValue: RecordingViewModel(activity: activity, onFinished: onFinished))
    }

    var body: some View {
        ZStack {
            CameraPreview(session: model.camera.session)
                .ignoresSafeArea()
            overlay
        }
        .task { await model.start() }
        .onDisappear { model.cancel() }
        .navigationBarBackButtonHidden(model.phase == .recording)
        .toolbar(.hidden, for: .tabBar)
    }

    @ViewBuilder
    private var overlay: some View {
        VStack {
            HStack(spacing: 8) {
                framingBadge
                voiceToggle
            }
            .padding(.top, 8)
            Spacer()
            switch model.phase {
            case .preparing:
                ProgressView().tint(.white)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.white)
                    .padding()
                    .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                    .padding()
            case .ready:
                Button {
                    model.beginPositioning()
                } label: {
                    Label("Start set", systemImage: "record.circle")
                }
                .buttonStyle(KodoProminentButtonStyle())
                .padding(.bottom, 40)
            case .positioning:
                VStack(spacing: 14) {
                    Text("Walk into position — recording starts once framing holds green")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .shadow(radius: 4)
                        .padding(.horizontal, 32)
                    HStack(spacing: 12) {
                        Button {
                            model.forceStart()
                        } label: {
                            Label("Record now", systemImage: "record.circle")
                        }
                        .buttonStyle(KodoProminentButtonStyle())
                        Button("Cancel") {
                            model.cancelPositioning()
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                }
                .padding(.bottom, 40)
            case .countdown(let tick):
                Text("\(tick)")
                    .font(.system(size: 120, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
                    .padding(.bottom, 120)
            case .recording:
                VStack(spacing: 16) {
                    if model.liveRepCount > 0 {
                        // Readable from the bar, 3 m away.
                        Text("\(model.liveRepCount)")
                            .font(.system(size: 96, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(radius: 8)
                            .contentTransition(.numericText())
                    }
                    Text(timeString(model.elapsed))
                        .font(.title.monospacedDigit().bold())
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                    Button {
                        Task { await model.stopAndFinish() }
                    } label: {
                        Label("Finish set", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(KodoProminentButtonStyle())
                }
                .padding(.bottom, 40)
            case .finishing:
                ProgressView("Saving…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding(.bottom, 60)
            }
        }
    }

    private var voiceToggle: some View {
        Button {
            voiceEnabled.toggle()
            model.voice.enabled = voiceEnabled
        } label: {
            Image(systemName: voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.45), in: Circle())
        }
        .accessibilityLabel(voiceEnabled ? "Mute voice coach" : "Unmute voice coach")
    }

    private var framingBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: model.framing == .fullBodyVisible
                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            Text(model.framing.message)
            if model.usesLiDAR {
                Image(systemName: "sensor.fill")
                    .help("LiDAR depth active")
            }
        }
        .font(.subheadline.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            model.framing == .fullBodyVisible ? .green.opacity(0.75) : .orange.opacity(0.85),
            in: Capsule()
        )
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
