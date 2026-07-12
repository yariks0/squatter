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
        let windowStart = timeRange?.lowerBound ?? 0
        let windowEnd = timeRange?.upperBound ?? duration

        func makeReader(from start: TimeInterval) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw PoseExtractionError.readerFailed }
            reader.add(output)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: movieStart + start, preferredTimescale: 600),
                end: CMTime(seconds: movieStart + windowEnd, preferredTimescale: 600)
            )
            guard reader.startReading() else { throw PoseExtractionError.readerFailed }
            return (reader, output)
        }

        var (reader, output) = try makeReader(from: windowStart)
        defer { reader.cancelReading() }

        let depthReader = depthSidecarURL.flatMap { try? DepthSidecarReader(url: $0) }
        var upcomingDepth = depthReader?.next()
        var previousDepth: DepthSidecarFrame?
        let depthTolerance = 1.0 / targetFrameRate

        var frames: [JointFrame] = []
        var heights: [Float] = []
        var heightSamples: [Double] = []
        var barTrack: [BarSample] = []
        var imageAspectRatio: Float?
        var lastScale: Double?
        var usedDepth = false
        var lastAnalyzedTime = -Double.infinity
        let minInterval = 1.0 / targetFrameRate - 1e-6
        // Progress is reported over the analyzed window; frame times stay on
        // the movie timeline so trimmed analyses still sync with playback of
        // the full recording (overlays, rep timeline, keyframes).
        let windowDuration = windowEnd - windowStart
        var resumeProgressMark = -Double.infinity
        var resumesWithoutProgress = 0

        while true {
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                if imageAspectRatio == nil {
                    imageAspectRatio = Float(CVPixelBufferGetWidth(pixelBuffer))
                        / Float(CVPixelBufferGetHeight(pixelBuffer))
                }
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let time = presentationTime - movieStart
                guard time - lastAnalyzedTime >= minInterval else {
                    // Frames the 3D pass skips still feed the bar track: the
                    // 2D detector is cheap, and full-capture-rate wrists
                    // double the temporal resolution of bar velocity.
                    if time > (barTrack.last?.time ?? -.infinity),
                       let wristY = detectedWristY(in: pixelBuffer) {
                        barTrack.append(BarSample(time: time, y: wristY, scale: lastScale))
                    }
                    continue
                }
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
                    var jointFrame = frame(from: observation, pose2D: request2D.results?.first, at: time)
                    if let depthData, let focal = depthReader?.focalLengthPixels, focal > 100,
                       let depth = bodyDepth(imagePoints: jointFrame.imagePoints, depthData: depthData) {
                        // The skeleton's vertical plane runs ~torsoSurfaceOffset
                        // behind the LiDAR-visible surface; that plane also
                        // sets the metric scale for bar velocity. A propped
                        // phone tilts, compressing vertical image spans by
                        // ~cos(pitch) — undone here when the sidecar carries
                        // the recorded pitch (v3+).
                        let plane = depth + torsoSurfaceOffset
                        let pitchScale = depthReader?.cameraPitchRadians
                            .map { 1.0 / max(0.5, cos(Double($0))) } ?? 1.0
                        jointFrame.metersPerImageHeight = Float(
                            pitchScale * plane * Double(CVPixelBufferGetHeight(pixelBuffer)) / Double(focal)
                        )
                        // Height samples only from a plausible filming
                        // distance — the walk to the phone after the set
                        // produces clipped, foreshortened frames that still
                        // land inside the naive human-height band.
                        if plane >= minimumHeightSampleDepth, plane < 8,
                           let sample = measuredHeight(
                               imagePoints: jointFrame.imagePoints,
                               metersPerImageHeight: Double(jointFrame.metersPerImageHeight!)
                           ) {
                            heightSamples.append(sample)
                        }
                    }
                    if let scale = jointFrame.metersPerImageHeight {
                        lastScale = Double(scale)
                    }
                    let wrists = [jointFrame.imagePoints[.leftWrist], jointFrame.imagePoints[.rightWrist]]
                        .compactMap { $0 }
                    if !wrists.isEmpty, time > (barTrack.last?.time ?? -.infinity) {
                        let wristY = wrists.reduce(0.0) { $0 + Double($1.y) } / Double(wrists.count)
                        barTrack.append(BarSample(time: time, y: wristY, scale: lastScale))
                    }
                    frames.append(jointFrame)
                    if observation.bodyHeight > 0 { heights.append(Float(observation.bodyHeight)) }
                }
                if windowDuration > 0 { progress?(min(max(time - windowStart, 0) / windowDuration, 1)) }
            }
            if reader.status == .completed { break }

            // The sample stream also ends when the decoder is torn down mid-file
            // (app backgrounded, memory pressure) — returning what was read so
            // far would silently cut the set short and analyze a fraction of the
            // reps (seen on device 2026-07-09: 22.5 s of a 40.5 s bench set,
            // 1 rep of 8). Resume from the last analyzed frame; give up only
            // when repeated attempts make no progress.
            if lastAnalyzedTime > resumeProgressMark {
                resumeProgressMark = lastAnalyzedTime
                resumesWithoutProgress = 0
            }
            resumesWithoutProgress += 1
            guard resumesWithoutProgress <= Self.maxReaderResumes else {
                throw reader.error ?? PoseExtractionError.readerFailed
            }
            try await Task.sleep(for: .milliseconds(600))
            reader.cancelReading()
            // A failed re-creation (still backgrounded) burns an attempt and
            // loops; the cancelled reader yields no samples and lands back here.
            if let resumed = try? makeReader(from: max(lastAnalyzedTime, windowStart)) {
                (reader, output) = resumed
            }
        }

        // Vision's RGB-only bodyHeight is only a prior (~1.80 for any adult);
        // with LiDAR distance and the camera's focal length the height is
        // measured directly instead. Squatting shrinks the pixel span, so
        // standing frames fill the top of the sample distribution — the
        // median of the top quartile reads them while staying robust to the
        // handful of walking/turning outliers above.
        var bodyHeight = heights.isEmpty ? nil : heights.sorted()[heights.count / 2]
        if heightSamples.count >= minimumHeightSamples {
            let sorted = heightSamples.sorted()
            let topQuartile = Array(sorted[(sorted.count * 3) / 4 ..< sorted.count])
            bodyHeight = Float(topQuartile[topQuartile.count / 2])
            usedDepth = true
        }
        return JointSeries(
            frames: frames,
            bodyHeight: bodyHeight,
            usedDepth: usedDepth,
            barTrack: barTrack.isEmpty ? nil : barTrack,
            imageAspectRatio: imageAspectRatio
        )
    }

    /// Confident wrist-midpoint image y from the 2D detector alone — the
    /// full-rate bar-track path for frames the 3D pass skips.
    private static func detectedWristY(in pixelBuffer: CVPixelBuffer) -> Double? {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
        guard let points = try? request.results?.first?.recognizedPoints(.all) else { return nil }
        let wrists = [points[.leftWrist], points[.rightWrist]].compactMap { point -> Double? in
            guard let point, point.confidence >= 0.3 else { return nil }
            return Double(point.location.y)
        }
        guard !wrists.isEmpty else { return nil }
        return wrists.reduce(0, +) / Double(wrists.count)
    }

    /// Consecutive reader re-creations without a new frame before extraction
    /// gives up and surfaces the failure.
    private static let maxReaderResumes = 4
    /// Sample count below which the depth-based height is considered noise.
    private static let minimumHeightSamples = 5
    /// LiDAR measures the near torso surface; the skeleton's vertical plane
    /// runs roughly this much deeper along the viewing ray.
    private static let torsoSurfaceOffset = 0.13
    /// Ankle joints sit about this far above the floor.
    private static let ankleHeightOffset = 0.07
    /// Body depth below which no height sample is taken: closer than any
    /// plausible filming spot, i.e. the lifter walking to the phone.
    private static let minimumHeightSampleDepth = 1.8
    /// Torso depth readings spreading wider than this mean something (a
    /// hand, the bar, a rack post) sits in front of part of the torso.
    private static let maxTorsoDepthSpread = 0.4
    /// How far past the nose the head-top estimate extends along the
    /// neck→nose line, in fractions of that segment. First calibration
    /// against the lifter's known 1.80 m on the 2026-07 squat recordings —
    /// those lack recorded camera pitch, which moves sessions ±4%, so this
    /// is provisional until pitch-carrying (sidecar v3) footage exists.
    static let headTopExtensionFactor: Float = 0.75

    /// Median LiDAR depth across the torso joints — robust against a hand,
    /// the bar, or a plate in front of any single point (the old
    /// root-pixel-only read measured the lifter's hands, shrinking every
    /// scale-dependent metric by several percent).
    private static func bodyDepth(
        imagePoints: [BodyJoint: SIMD2<Float>],
        depthData: AVDepthData
    ) -> Double? {
        let torso: [BodyJoint] = [.root, .leftHip, .rightHip, .leftShoulder, .rightShoulder]
        let readings = torso.compactMap { joint in
            imagePoints[joint].flatMap { depthValue(depthData, x: Double($0.x), y: Double($0.y)) }
        }
        guard readings.count >= 3 else { return nil }
        let sorted = readings.sorted()
        guard sorted[sorted.count - 1] - sorted[0] <= maxTorsoDepthSpread else { return nil }
        return sorted[sorted.count / 2]
    }

    /// Pinhole height measurement: the skeleton's vertical image span times
    /// the metric scale of the lifter's depth plane.
    private static func measuredHeight(
        imagePoints: [BodyJoint: SIMD2<Float>],
        metersPerImageHeight: Double
    ) -> Double? {
        guard let top = imagePoints[.topHead],
              let leftAnkle = imagePoints[.leftAnkle],
              let rightAnkle = imagePoints[.rightAnkle],
              let root = imagePoints[.root]
        else { return nil }
        // The whole measurement chain must sit inside the frame: clipped
        // ankles or a cropped head make the span a lie.
        let margin: Float = 0.02
        for point in [top, leftAnkle, rightAnkle, root] {
            guard point.x > margin, point.x < 1 - margin,
                  point.y > margin, point.y < 1 - margin else { return nil }
        }

        // Vertical span only: the camera's 45° yaw foreshortens horizontal
        // extents but leaves vertical ones intact.
        let span = Double(top.y - (leftAnkle.y + rightAnkle.y) / 2)
        guard span > 0 else { return nil }
        let height = span * metersPerImageHeight + ankleHeightOffset
        // Outside human range = depth hit the background or a foreground
        // object, or the lifter is bent over; standing frames win the
        // percentile anyway.
        return (1.0 ... 2.3).contains(height) ? height : nil
    }

    /// Depth map value at a Vision-normalized point (bottom-left origin), in
    /// meters; nil for LiDAR holes. Internal: `PlateDetector` samples the
    /// same sidecar maps at the plate faces.
    static func depthValue(_ depthData: AVDepthData, x: Double, y: Double) -> Double? {
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
        var confidences: [BodyJoint: Float] = [:]
        if let detected = try? pose2D?.recognizedPoints(.all) {
            func detectedPoint(_ name: VNHumanBodyPoseObservation.JointName) -> SIMD2<Float>? {
                guard let point = detected[name], point.confidence > 0.3 else { return nil }
                return SIMD2(Float(point.location.x), Float(point.location.y))
            }
            for (joint, name) in Self.pose2DNames {
                // Confidence is kept even below the acceptance gate — a low
                // number tells the overlay the retained re-projected point is
                // a guess, not a detection.
                if let point = detected[name] { confidences[joint] = Float(point.confidence) }
                if let point = detectedPoint(name) { imagePoints[joint] = point }
            }
            // Derived joints inherit their weakest constituent's confidence
            // (neck is recorded under .centerShoulder by the loop above).
            let neckConfidence = confidences[.centerShoulder] ?? 0
            if let root = detectedPoint(.root), let neck = detectedPoint(.neck) {
                imagePoints[.spine] = (root + neck) / 2
                confidences[.spine] = min(confidences[.root] ?? 0, neckConfidence)
                // The 2D set has no head-top joint; extend past the nose to
                // the crown (factor calibrated against a known body height —
                // it feeds the metric height measurement, not just drawing).
                if let nose = detectedPoint(.nose) {
                    imagePoints[.centerHead] = nose
                    imagePoints[.topHead] = nose + (nose - neck) * Self.headTopExtensionFactor
                    let derived = min(Float(detected[.nose]?.confidence ?? 0), neckConfidence)
                    confidences[.centerHead] = derived
                    confidences[.topHead] = derived
                }
            }
        }
        return JointFrame(
            time: time, positions: positions, imagePoints: imagePoints,
            jointConfidences: confidences.isEmpty ? nil : confidences
        )
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
