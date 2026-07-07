import AVFoundation
import simd
import Vision

enum PoseExtractionError: LocalizedError {
    case noVideoTrack
    case readerFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The recording has no video track."
        case .readerFailed: "Could not read the recording."
        }
    }
}

/// Offline pose extraction: reads the recorded video (and LiDAR depth sidecar
/// when present), runs Vision's 3D body pose per frame, and produces a
/// `JointSeries` for the metrics pipeline.
enum PoseExtractor {
    /// Analysis frame rate. Squat dynamics live well below 7.5 Hz, so 15 fps
    /// halves the work at 30 fps capture with no metric loss.
    static let targetFrameRate = 15.0

    static func extract(
        videoURL: URL,
        depthSidecarURL: URL?,
        timeRange: ClosedRange<TimeInterval>? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> JointSeries {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PoseExtractionError.noVideoTrack
        }
        let duration = try await asset.load(.duration).seconds
        let movieStart = try await track.load(.timeRange).start.seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PoseExtractionError.readerFailed }
        reader.add(output)
        if let timeRange {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: movieStart + timeRange.lowerBound, preferredTimescale: 600),
                duration: CMTime(seconds: timeRange.upperBound - timeRange.lowerBound, preferredTimescale: 600)
            )
        }
        guard reader.startReading() else { throw PoseExtractionError.readerFailed }
        defer { reader.cancelReading() }

        let depthReader = depthSidecarURL.flatMap { try? DepthSidecarReader(url: $0) }
        var upcomingDepth = depthReader?.next()
        var previousDepth: DepthSidecarFrame?
        let depthTolerance = 1.0 / targetFrameRate

        var frames: [JointFrame] = []
        var heights: [Float] = []
        var scaleRatios: [Double] = []
        var usedDepth = false
        var lastAnalyzedTime = -Double.infinity
        let minInterval = 1.0 / targetFrameRate - 1e-6
        // Progress is reported over the analyzed window; frame times stay on
        // the movie timeline so trimmed analyses still sync with playback of
        // the full recording (overlays, rep timeline, keyframes).
        let windowStart = timeRange?.lowerBound ?? 0
        let windowDuration = timeRange.map { $0.upperBound - $0.lowerBound } ?? duration

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let time = presentationTime - movieStart
            guard time - lastAnalyzedTime >= minInterval else { continue }
            lastAnalyzedTime = time

            // Advance the depth stream to the record closest to this frame.
            while let next = upcomingDepth, next.time <= time {
                previousDepth = next
                upcomingDepth = depthReader?.next()
            }
            var closestDepth = previousDepth
            if let next = upcomingDepth,
               abs(next.time - time) < abs((closestDepth?.time ?? -.infinity) - time) {
                closestDepth = next
            }
            var depthData: AVDepthData? = closestDepth.flatMap {
                abs($0.time - time) <= depthTolerance ? $0.depthData : nil
            }
            // Depth is only sampled at joint image points, so its orientation
            // must match the video frame. Sidecars recorded before the depth
            // connection was rotated are landscape; skip depth for those.
            if let depth = depthData {
                let map = depth.depthDataMap
                let depthPortrait = CVPixelBufferGetHeight(map) >= CVPixelBufferGetWidth(map)
                let videoPortrait = CVPixelBufferGetHeight(pixelBuffer) >= CVPixelBufferGetWidth(pixelBuffer)
                if depthPortrait != videoPortrait { depthData = nil }
            }

            // Depth is deliberately NOT handed to Vision. Sidecar depth has no
            // camera calibration (the dictionary representation we persist
            // drops it, and the rotated capture connection invalidates the
            // intrinsics anyway), and VNDetectHumanBodyPose3DRequest's camera
            // registration hard-aborts on such depth (C++ assert in
            // AltruisticBodyPoseKit's PoseRefiner — not a catchable error).
            // Instead LiDAR provides what it is actually good for here: the
            // metric scale, measured directly off the depth map below.
            let request = VNDetectHumanBodyPose3DRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
            try? handler.perform([request])
            if let observation = request.results?.first {
                frames.append(frame(from: observation, at: time))
                if observation.bodyHeight > 0 { heights.append(Float(observation.bodyHeight)) }
                if let depthData, let ratio = depthScaleRatio(observation: observation, depthData: depthData) {
                    scaleRatios.append(ratio)
                }
            }
            if windowDuration > 0 { progress?(min(max(time - windowStart, 0) / windowDuration, 1)) }
        }

        // LiDAR scale correction: Vision's RGB-only skeleton is metrically
        // scaled by its body-height guess; the measured/estimated camera
        // distance ratio corrects that guess with real geometry.
        var bodyHeight = heights.isEmpty ? nil : heights.sorted()[heights.count / 2]
        if let height = bodyHeight, scaleRatios.count >= minimumScaleSamples {
            bodyHeight = height * Float(scaleRatios.sorted()[scaleRatios.count / 2])
            usedDepth = true
        }
        return JointSeries(
            frames: frames,
            bodyHeight: bodyHeight,
            usedDepth: usedDepth
        )
    }

    /// Sample count below which the depth-based scale is considered noise.
    private static let minimumScaleSamples = 5
    /// LiDAR measures the near torso surface; the root joint is the pelvis
    /// center, roughly this much deeper along the viewing ray.
    private static let torsoSurfaceOffset = 0.13

    /// LiDAR-measured distance at the root joint's image point divided by
    /// Vision's estimated camera distance to the root. The median of this
    /// ratio over a set corrects the skeleton's metric scale.
    private static func depthScaleRatio(
        observation: VNHumanBodyPose3DObservation,
        depthData: AVDepthData
    ) -> Double? {
        guard depthData.depthDataType == kCVPixelFormatType_DepthFloat16,
              let rootPoint = try? observation.pointInImage(.root) else { return nil }

        let map = depthData.depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        // Vision image points are normalized with a bottom-left origin;
        // pixel buffers have row 0 at the top.
        let x = min(max(Int(rootPoint.x * Double(width - 1)), 0), width - 1)
        let y = min(max(Int((1 - rootPoint.y) * Double(height - 1)), 0), height - 1)
        let row = base + y * CVPixelBufferGetBytesPerRow(map)
        let surface = Double(row.loadUnaligned(fromByteOffset: x * 2, as: Float16.self))
        // Plausible camera→lifter distances only; LiDAR holes are NaN/0.
        guard surface.isFinite, surface > 0.5, surface < 8 else { return nil }
        let measured = surface + torsoSurfaceOffset

        let camera = observation.cameraOriginMatrix.columns.3
        let estimated = Double(simd_length(SIMD3(camera.x, camera.y, camera.z)))
        guard estimated > 0.5 else { return nil }
        let ratio = measured / estimated
        // A sample far outside plausible height-prior error means the depth
        // hit the background or a foreground object, not the lifter.
        return (0.6 ... 1.4).contains(ratio) ? ratio : nil
    }

    private static func frame(
        from observation: VNHumanBodyPose3DObservation,
        at time: TimeInterval
    ) -> JointFrame {
        var positions: [BodyJoint: SIMD3<Float>] = [:]
        var imagePoints: [BodyJoint: SIMD2<Float>] = [:]
        for joint in BodyJoint.allCases {
            let visionName = joint.visionName
            guard let point = try? observation.recognizedPoint(visionName) else { continue }
            let translation = point.position.columns.3
            positions[joint] = SIMD3(translation.x, translation.y, translation.z)
            if let imagePoint = try? observation.pointInImage(visionName) {
                imagePoints[joint] = SIMD2(Float(imagePoint.x), Float(imagePoint.y))
            }
        }
        return JointFrame(time: time, positions: positions, imagePoints: imagePoints)
    }
}

private extension BodyJoint {
    var visionName: VNHumanBodyPose3DObservation.JointName {
        switch self {
        case .root: .root
        case .spine: .spine
        case .centerShoulder: .centerShoulder
        case .centerHead: .centerHead
        case .topHead: .topHead
        case .leftShoulder: .leftShoulder
        case .rightShoulder: .rightShoulder
        case .leftElbow: .leftElbow
        case .rightElbow: .rightElbow
        case .leftWrist: .leftWrist
        case .rightWrist: .rightWrist
        case .leftHip: .leftHip
        case .rightHip: .rightHip
        case .leftKnee: .leftKnee
        case .rightKnee: .rightKnee
        case .leftAnkle: .leftAnkle
        case .rightAnkle: .rightAnkle
        }
    }
}
