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
        var heightSamples: [Double] = []
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
            let request2D = VNDetectHumanBodyPoseRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
            try? handler.perform([request, request2D])
            if let observation = request.results?.first {
                let jointFrame = frame(from: observation, pose2D: request2D.results?.first, at: time)
                frames.append(jointFrame)
                if observation.bodyHeight > 0 { heights.append(Float(observation.bodyHeight)) }
                if let depthData, let focal = depthReader?.focalLengthPixels,
                   let sample = measuredHeight(
                       imagePoints: jointFrame.imagePoints,
                       depthData: depthData,
                       videoPixelHeight: CVPixelBufferGetHeight(pixelBuffer),
                       focalPixels: Double(focal)
                   ) {
                    heightSamples.append(sample)
                }
            }
            if windowDuration > 0 { progress?(min(max(time - windowStart, 0) / windowDuration, 1)) }
        }

        // Vision's RGB-only bodyHeight is only a prior (~1.80 for any adult);
        // with LiDAR distance and the camera's focal length the height is
        // measured directly instead. Squatting shrinks the pixel span, so
        // standing frames sit at the top of the sample distribution.
        var bodyHeight = heights.isEmpty ? nil : heights.sorted()[heights.count / 2]
        if heightSamples.count >= minimumHeightSamples {
            let sorted = heightSamples.sorted()
            bodyHeight = Float(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))])
            usedDepth = true
        }
        return JointSeries(
            frames: frames,
            bodyHeight: bodyHeight,
            usedDepth: usedDepth
        )
    }

    /// Sample count below which the depth-based height is considered noise.
    private static let minimumHeightSamples = 5
    /// LiDAR measures the near torso surface; the skeleton's vertical plane
    /// runs roughly this much deeper along the viewing ray.
    private static let torsoSurfaceOffset = 0.13
    /// Ankle joints sit about this far above the floor.
    private static let ankleHeightOffset = 0.07

    /// Pinhole height measurement: the skeleton's vertical pixel span times
    /// the LiDAR-measured distance, divided by the camera's focal length.
    private static func measuredHeight(
        imagePoints: [BodyJoint: SIMD2<Float>],
        depthData: AVDepthData,
        videoPixelHeight: Int,
        focalPixels: Double
    ) -> Double? {
        guard focalPixels > 100,
              let top = imagePoints[.topHead],
              let leftAnkle = imagePoints[.leftAnkle],
              let rightAnkle = imagePoints[.rightAnkle],
              let root = imagePoints[.root],
              let surface = depthValue(depthData, x: Double(root.x), y: Double(root.y))
        else { return nil }
        // Plausible camera→lifter distances only.
        let distance = surface + torsoSurfaceOffset
        guard distance > 0.5, distance < 8 else { return nil }

        // Vertical span only: the camera's 45° yaw foreshortens horizontal
        // extents but leaves vertical ones intact.
        let span = Double(top.y - (leftAnkle.y + rightAnkle.y) / 2) * Double(videoPixelHeight)
        guard span > 0 else { return nil }
        let height = span * distance / focalPixels + ankleHeightOffset
        // Outside human range = depth hit the background or a foreground
        // object, or the lifter is bent over; standing frames win the
        // percentile anyway.
        return (1.0 ... 2.3).contains(height) ? height : nil
    }

    /// Depth map value at a Vision-normalized point (bottom-left origin), in
    /// meters; nil for LiDAR holes.
    private static func depthValue(_ depthData: AVDepthData, x: Double, y: Double) -> Double? {
        guard depthData.depthDataType == kCVPixelFormatType_DepthFloat16 else { return nil }
        let map = depthData.depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let column = min(max(Int(x * Double(width - 1)), 0), width - 1)
        let row = min(max(Int((1 - y) * Double(height - 1)), 0), height - 1)
        let rowBase = base + row * CVPixelBufferGetBytesPerRow(map)
        let value = Double(rowBase.loadUnaligned(fromByteOffset: column * 2, as: Float16.self))
        return value.isFinite && value > 0 ? value : nil
    }

    private static func frame(
        from observation: VNHumanBodyPose3DObservation,
        pose2D: VNHumanBodyPoseObservation?,
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
        // The 3D observation's image points are its model skeleton
        // re-projected through Vision's *assumed* camera, so they drift off
        // the body toward the frame edges (worst at the legs). The 2D
        // detector returns actually-detected pixel locations — prefer those
        // for anything drawn or measured in image space.
        if let detected = try? pose2D?.recognizedPoints(.all) {
            func detectedPoint(_ name: VNHumanBodyPoseObservation.JointName) -> SIMD2<Float>? {
                guard let point = detected[name], point.confidence > 0.3 else { return nil }
                return SIMD2(Float(point.location.x), Float(point.location.y))
            }
            for (joint, name) in Self.pose2DNames {
                if let point = detectedPoint(name) { imagePoints[joint] = point }
            }
            if let root = detectedPoint(.root), let neck = detectedPoint(.neck) {
                imagePoints[.spine] = (root + neck) / 2
                // The 2D set has no head-top joint; extend past the nose so
                // the drawn head segment still covers the head.
                if let nose = detectedPoint(.nose) {
                    imagePoints[.centerHead] = nose
                    imagePoints[.topHead] = nose + (nose - neck) * 0.6
                }
            }
        }
        return JointFrame(time: time, positions: positions, imagePoints: imagePoints)
    }

    private static let pose2DNames: [(BodyJoint, VNHumanBodyPoseObservation.JointName)] = [
        (.root, .root), (.centerShoulder, .neck),
        (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
        (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
        (.leftHip, .leftHip), (.rightHip, .rightHip),
        (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
        (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle),
    ]
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
