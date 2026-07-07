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
        case countdown(Int)
        case recording
        case finishing
        case failed(String)
    }

    private(set) var phase: Phase = .preparing
    private(set) var framing: FramingChecker.Status = .noBody
    private(set) var elapsed: TimeInterval = 0
    private(set) var usesLiDAR = false

    let camera = CameraService()
    private var framingChecker: FramingChecker?
    private var timerTask: Task<Void, Never>?
    private let onFinished: (RecordingResult) -> Void

    init(onFinished: @escaping (RecordingResult) -> Void) {
        self.onFinished = onFinished
    }

    func start() async {
        guard await CameraService.requestPermission() else {
            phase = .failed(CameraService.CameraError.permissionDenied.localizedDescription)
            return
        }
        let checker = FramingChecker { [weak self] status in
            Task { @MainActor in self?.framing = status }
        }
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

    func beginCountdown() {
        guard phase == .ready else { return }
        timerTask = Task { [self] in
            for tick in stride(from: 5, through: 1, by: -1) {
                phase = .countdown(tick)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            await beginRecording()
        }
    }

    private func beginRecording() async {
        do {
            try await camera.startRecording()
            // Audible confirmation that the set is being recorded (the
            // system begin-record chime), heard from squat distance.
            AudioServicesPlaySystemSound(1113)
            phase = .recording
            elapsed = 0
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
        camera.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

struct RecordView: View {
    @State private var model: RecordingViewModel
    @Environment(\.dismiss) private var dismiss

    init(onFinished: @escaping (RecordingResult) -> Void) {
        _model = State(initialValue: RecordingViewModel(onFinished: onFinished))
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
            framingBadge
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
                    model.beginCountdown()
                } label: {
                    Label("Start set", systemImage: "record.circle")
                        .font(.title2.bold())
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.bottom, 40)
            case .countdown(let tick):
                Text("\(tick)")
                    .font(.system(size: 120, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
                    .padding(.bottom, 120)
            case .recording:
                VStack(spacing: 16) {
                    Text(timeString(model.elapsed))
                        .font(.title.monospacedDigit().bold())
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                    Button {
                        Task { await model.stopAndFinish() }
                    } label: {
                        Label("Finish set", systemImage: "stop.circle.fill")
                            .font(.title2.bold())
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
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
