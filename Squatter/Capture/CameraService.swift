import AVFoundation
import CoreMedia

struct RecordingResult: Sendable, Hashable {
    let videoURL: URL
    let depthSidecarURL: URL?
    let duration: TimeInterval
    let usedLiDAR: Bool
    /// Movie-timeline window to analyze (user trim); nil = whole recording.
    var analysisRange: ClosedRange<TimeInterval>?

    init(
        videoURL: URL,
        depthSidecarURL: URL?,
        duration: TimeInterval,
        usedLiDAR: Bool,
        analysisRange: ClosedRange<TimeInterval>? = nil
    ) {
        self.videoURL = videoURL
        self.depthSidecarURL = depthSidecarURL
        self.duration = duration
        self.usedLiDAR = usedLiDAR
        self.analysisRange = analysisRange
    }
}

/// Owns the capture session and recording pipeline. On LiDAR devices the
/// session runs the LiDAR depth camera with synchronized video + depth
/// outputs; depth frames are written to a sidecar next to the video so the
/// analysis pipeline can run depth-assisted 3D pose. On non-LiDAR devices
/// (e.g. iPhone 11 Pro) it records plain video.
final class CameraService: NSObject, @unchecked Sendable {
    enum CameraError: LocalizedError {
        case permissionDenied
        case noCamera
        case notRecording

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "Camera access is required to record your set."
            case .noCamera: "No back camera available."
            case .notRecording: "No recording in progress."
            }
        }
    }

    let session = AVCaptureSession()
    private(set) var hasLiDAR = false

    /// Called with camera pixel buffers (throttled by the receiver) for the
    /// live framing check. Invoked on the capture data queue.
    var frameSink: (@Sendable (CVPixelBuffer) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.yarik.squatter.session")
    private let dataQueue = DispatchQueue(label: "com.yarik.squatter.data")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var depthOutput: AVCaptureDepthDataOutput?
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var configured = false

    // Recording state, touched only on dataQueue.
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var depthWriter: DepthSidecarWriter?
    private var depthSidecarURL: URL?
    private var sessionStartTime: CMTime?
    private var lastVideoTime: CMTime?
    private var keepEveryOtherDepthFrame = true
    private var depthFrameParity = false

    // MARK: - Setup

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                do {
                    if !configured {
                        try configureSession()
                        configured = true
                    }
                    if !session.isRunning { session.startRunning() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let lidarDevice = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
        let device: AVCaptureDevice
        if let lidarDevice {
            device = lidarDevice
            hasLiDAR = true
        } else if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            device = wide
        } else {
            throw CameraError.noCamera
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.noCamera }
        session.addInput(input)
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else { throw CameraError.noCamera }
        session.addOutput(videoOutput)

        if hasLiDAR {
            let depthOutput = AVCaptureDepthDataOutput()
            depthOutput.isFilteringEnabled = true
            if session.canAddOutput(depthOutput) {
                session.addOutput(depthOutput)
                if let depthFormat = preferredDepthFormat(for: device) {
                    try device.lockForConfiguration()
                    device.activeDepthDataFormat = depthFormat
                    device.unlockForConfiguration()
                }
                let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
                synchronizer.setDelegate(self, queue: dataQueue)
                self.depthOutput = depthOutput
                self.synchronizer = synchronizer
            } else {
                hasLiDAR = false
            }
        }
        if synchronizer == nil {
            videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        }

        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90 // portrait
        }
        // Depth must match the video's portrait orientation: the analysis
        // samples the depth map at joint image points, so both must share one
        // coordinate space. (Depth is never handed to Vision itself — see
        // PoseExtractor for why that aborts the process.)
        if let depthConnection = depthOutput?.connection(with: .depthData),
           depthConnection.isVideoRotationAngleSupported(90) {
            depthConnection.videoRotationAngle = 90
        }
    }

    private func preferredDepthFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.activeFormat.supportedDepthDataFormats
            .filter { CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat16 }
            .max { lhs, rhs in
                CMVideoFormatDescriptionGetDimensions(lhs.formatDescription).width
                    < CMVideoFormatDescriptionGetDimensions(rhs.formatDescription).width
            }
    }

    // MARK: - Recording

    func startRecording() async throws {
        let recordLiDAR = hasLiDAR
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            dataQueue.async { [self] in
                do {
                    let baseURL = try FileLocations.newRecordingBaseURL()
                    let videoURL = baseURL.appendingPathExtension("mov")
                    let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
                    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                        AVVideoCodecKey: AVVideoCodecType.hevc,
                        AVVideoWidthKey: 1080,
                        AVVideoHeightKey: 1920,
                    ])
                    input.expectsMediaDataInRealTime = true
                    writer.add(input)
                    guard writer.startWriting() else {
                        throw writer.error ?? CameraError.notRecording
                    }

                    if recordLiDAR {
                        let depthURL = baseURL.appendingPathExtension(DepthSidecar.fileExtension)
                        depthWriter = try DepthSidecarWriter(url: depthURL)
                        depthSidecarURL = depthURL
                    }
                    assetWriter = writer
                    writerInput = input
                    sessionStartTime = nil
                    lastVideoTime = nil
                    depthFrameParity = false
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stopRecording() async throws -> RecordingResult {
        try await withCheckedThrowingContinuation { continuation in
            dataQueue.async { [self] in
                guard let writer = assetWriter, let input = writerInput else {
                    continuation.resume(throwing: CameraError.notRecording)
                    return
                }
                let start = sessionStartTime
                let end = lastVideoTime
                let depthURL = depthSidecarURL
                let usedLiDAR = depthWriter != nil
                try? depthWriter?.finish()
                assetWriter = nil
                writerInput = nil
                depthWriter = nil
                depthSidecarURL = nil

                guard writer.status == .writing, let start, let end else {
                    writer.cancelWriting()
                    continuation.resume(throwing: writer.error ?? CameraError.notRecording)
                    return
                }
                input.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume(returning: RecordingResult(
                            videoURL: writer.outputURL,
                            depthSidecarURL: depthURL,
                            duration: (end - start).seconds,
                            usedLiDAR: usedLiDAR
                        ))
                    } else {
                        continuation.resume(throwing: writer.error ?? CameraError.notRecording)
                    }
                }
            }
        }
    }

    // Runs on dataQueue.
    private func handle(videoSampleBuffer: CMSampleBuffer, depthData: AVDepthData?, depthTime: CMTime?) {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(videoSampleBuffer) {
            frameSink?(pixelBuffer)
        }

        guard let writer = assetWriter, let input = writerInput else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(videoSampleBuffer)
        if sessionStartTime == nil {
            writer.startSession(atSourceTime: time)
            sessionStartTime = time
        }
        if input.isReadyForMoreMediaData, input.append(videoSampleBuffer) {
            lastVideoTime = time
        }

        if let depthData, let depthTime, let depthWriter, let sessionStartTime {
            depthFrameParity.toggle()
            // Depth at half the video rate keeps the sidecar a manageable size;
            // pose accuracy needs depth trend, not every frame.
            if !keepEveryOtherDepthFrame || depthFrameParity {
                try? depthWriter.append(depthData, at: depthTime - sessionStartTime)
            }
        }
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        handle(videoSampleBuffer: sampleBuffer, depthData: nil, depthTime: nil)
    }
}

extension CameraService: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(
        _ synchronizer: AVCaptureDataOutputSynchronizer,
        didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection
    ) {
        guard
            let videoData = synchronizedDataCollection.synchronizedData(for: videoOutput)
                as? AVCaptureSynchronizedSampleBufferData,
            !videoData.sampleBufferWasDropped
        else { return }

        var depthData: AVDepthData?
        var depthTime: CMTime?
        if let depthOutput,
           let synced = synchronizedDataCollection.synchronizedData(for: depthOutput)
               as? AVCaptureSynchronizedDepthData,
           !synced.depthDataWasDropped {
            depthData = synced.depthData
            depthTime = synced.timestamp
        }
        handle(videoSampleBuffer: videoData.sampleBuffer, depthData: depthData, depthTime: depthTime)
    }
}
