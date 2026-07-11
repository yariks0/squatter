import AVFoundation
import Foundation
import Vision
import simd

/// Reads the plate sizes off the bar in the setup frames of a recording.
///
/// The detector never claims a total weight — plates stack behind each
/// other, so counts are unknowable from one view. What *is* measurable is
/// which plate diameters are on the bar: the 2D wrists locate the bar line,
/// the sleeves sit a known distance out along it, and the LiDAR sidecar
/// gives meters-per-pixel at each plate's own depth plane. Circular
/// contours at the sleeve whose metric diameter lands in plate range become
/// diameter clusters the UI matches against the user's `PlateCatalog`
/// (all-black gym plates classify by diameter alone) or offers to teach.
enum PlateDetector {
    struct Detection: Sendable, Equatable {
        /// Distinct plate-face diameters seen on the bar, meters, largest
        /// first. Classes, not counts — identical plates stack invisibly.
        var diametersMeters: [Double]
    }

    static func detect(
        videoURL: URL, depthSidecarURL: URL?, within range: ClosedRange<TimeInterval>? = nil
    ) async -> Detection? {
        // Metric diameter needs the LiDAR sidecar; without it a 45 cm plate
        // at 4 m and a 25 cm plate at 2.2 m are the same pixels.
        guard let depthSidecarURL,
              let depthReader = try? DepthSidecarReader(url: depthSidecarURL),
              let focal = depthReader.focalLengthPixels, focal > 100
        else { return nil }

        let asset = AVURLAsset(url: videoURL)
        guard let duration = try? await asset.load(.duration).seconds, duration > 1 else {
            return nil
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)

        // Early standing frames: the lifter has the bar, the set hasn't
        // started. Ascending times so the sequential sidecar read keeps up.
        let start = range?.lowerBound ?? 0
        let end = min(range?.upperBound ?? duration, duration)
        var upcomingDepth = depthReader.next()
        var samples: [Double] = []

        for time in stride(from: start + 0.4, to: min(start + 6.5, end), by: 1.0) {
            guard let cgImage = try? await generator.image(
                at: CMTime(seconds: time, preferredTimescale: 600)
            ).image else { continue }

            let pose = VNDetectHumanBodyPoseRequest()
            try? VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([pose])
            guard let points = try? pose.results?.first?.recognizedPoints(.all) else { continue }
            func location(_ name: VNHumanBodyPoseObservation.JointName) -> SIMD2<Double>? {
                guard let point = points[name], point.confidence >= 0.3 else { return nil }
                return SIMD2(point.location.x, point.location.y)
            }
            // Full body standing with hands on the bar.
            guard let leftWrist = location(.leftWrist), let rightWrist = location(.rightWrist),
                  location(.leftAnkle) != nil, location(.rightAnkle) != nil else { continue }

            while let next = upcomingDepth, next.time < time - 0.2 {
                upcomingDepth = depthReader.next()
            }
            guard let depthFrame = upcomingDepth, abs(depthFrame.time - time) < 0.4 else { continue }

            samples.append(contentsOf: plateDiameters(
                in: cgImage, depthData: depthFrame.depthData, focalPixels: Double(focal),
                pitchRadians: depthReader.cameraPitchRadians.map(Double.init),
                leftWrist: leftWrist, rightWrist: rightWrist
            ))
        }

        // A diameter must be seen at least twice across frames/sides to
        // count — single circles are gym clutter.
        let clusters = cluster(samples)
        guard !clusters.isEmpty else { return nil }
        return Detection(diametersMeters: clusters)
    }

    // MARK: - Single frame

    private static func plateDiameters(
        in cgImage: CGImage, depthData: AVDepthData, focalPixels: Double,
        pitchRadians: Double?, leftWrist: SIMD2<Double>, rightWrist: SIMD2<Double>
    ) -> [Double] {
        let width = Double(cgImage.width)
        let height = Double(cgImage.height)
        // Vision-normalized (bottom-left) → pixels (top-left).
        func pixels(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(p.x * width, (1 - p.y) * height) }
        let left = pixels(leftWrist)
        let right = pixels(rightWrist)
        let grip = simd_length(right - left)
        guard grip > 20 else { return [] }
        let direction = (right - left) / grip
        let center = (left + right) / 2
        // A vertical image drop compresses by cos(pitch) on a tilted camera;
        // diameters are measured vertically below.
        let pitchFactor = pitchRadians.map { 1.0 / max(0.5, cos($0)) } ?? 1.0

        var diameters: [Double] = []
        for sign in [-1.0, 1.0] {
            // Plate depth at the sleeve, from the sidecar itself — the near
            // and far sleeve differ by most of a meter at a 45° view, which
            // would swing the diameter ~25% if the body plane were used.
            // First pass: assume ~3.5 m to place the probe, then re-probe at
            // the measured depth.
            var plateDepth = 3.5
            for _ in 0 ..< 2 {
                let metersPerPixel = plateDepth / focalPixels
                let probe = center + direction * (sign * sleeveMidOffsetMeters / metersPerPixel)
                guard let sampled = medianDepth(
                    depthData, aroundPixelX: probe.x / width, pixelY: probe.y / height
                ) else { break }
                plateDepth = sampled
            }
            let metersPerPixel = plateDepth / focalPixels
            let end = center + direction * (sign * sleeveMidOffsetMeters / metersPerPixel)
            let side = plateRegionMeters / metersPerPixel
            let crop = CGRect(
                x: end.x - side / 2, y: end.y - side / 2, width: side, height: side
            ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard crop.width > 40, crop.height > 40, let region = cgImage.cropping(to: crop)
            else { continue }

            diameters.append(contentsOf: circularContourHeights(in: region).compactMap { extent in
                let meters = extent * Double(region.height) * metersPerPixel * pitchFactor
                return AnalysisTuning.plateDiameterRangeMeters.contains(meters) ? meters : nil
            })
        }
        return diameters
    }

    /// Bar center to mid-sleeve for a standard 2.2 m bar: sleeves start at
    /// ±0.655 m and run ~0.41 m; plates load from the inside.
    private static let sleeveMidOffsetMeters = 0.78
    /// Crop size around each sleeve — the largest plate plus margin.
    private static let plateRegionMeters = 0.62

    /// Vertical extents (fraction of crop height) of plate-like contours: a
    /// plate face reads as an ellipse whose *vertical* axis is the true
    /// diameter — the horizontal axis forshortens with camera yaw.
    private static func circularContourHeights(in cgImage: CGImage) -> [Double] {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 2
        request.maximumImageDimension = 512
        try? VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])
        guard let observation = request.results?.first else { return [] }

        var extents: [Double] = []
        func walk(_ contour: VNContour, depth: Int) {
            defer {
                if depth < 3 {
                    for child in contour.childContours { walk(child, depth: depth + 1) }
                }
            }
            let points = contour.normalizedPoints
            guard points.count >= 12 else { return }
            var minX: Float = 1, maxX: Float = 0, minY: Float = 1, maxY: Float = 0
            var area: Float = 0
            var perimeter: Float = 0
            for (index, point) in points.enumerated() {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
                let next = points[(index + 1) % points.count]
                area += point.x * next.y - next.x * point.y
                perimeter += simd_length(next - point)
            }
            area = abs(area) / 2
            let boxWidth = maxX - minX
            let boxHeight = maxY - minY
            guard boxHeight > 0.25, boxHeight < 0.98, perimeter > 0 else { return }
            // Ellipse gates: vertical axis dominant or equal (yaw squeezes
            // width, never height), solid roundness, centered in the crop.
            let aspect = boxWidth / boxHeight
            guard aspect > 0.3, aspect < 1.25 else { return }
            let circularity = 4 * Float.pi * area / (perimeter * perimeter)
            guard circularity > 0.55 else { return }
            let centerX = (minX + maxX) / 2, centerY = (minY + maxY) / 2
            guard abs(centerX - 0.5) < 0.3, abs(centerY - 0.5) < 0.3 else { return }
            extents.append(Double(boxHeight))
        }
        for contour in observation.topLevelContours { walk(contour, depth: 0) }
        return extents
    }

    /// Median sidecar depth over a small grid at a pixel-normalized point
    /// (top-left origin), in meters.
    private static func medianDepth(
        _ depthData: AVDepthData, aroundPixelX x: Double, pixelY y: Double
    ) -> Double? {
        var readings: [Double] = []
        for dx in [-0.02, 0.0, 0.02] {
            for dy in [-0.02, 0.0, 0.02] {
                let px = min(max(x + dx, 0), 1)
                let py = min(max(y + dy, 0), 1)
                // depthValue expects Vision-normalized (bottom-left) coords.
                if let value = PoseExtractor.depthValue(depthData, x: px, y: 1 - py),
                   value > 0.5, value < 8 {
                    readings.append(value)
                }
            }
        }
        guard readings.count >= 3 else { return nil }
        return readings.sorted()[readings.count / 2]
    }

    /// Groups raw diameter samples into distinct plate classes; a class
    /// needs two sightings to survive.
    static func cluster(_ samples: [Double]) -> [Double] {
        guard !samples.isEmpty else { return [] }
        var clusters: [[Double]] = []
        for sample in samples.sorted() {
            if var last = clusters.last, let anchor = last.first,
               sample - anchor <= AnalysisTuning.plateDiameterToleranceMeters {
                last.append(sample)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([sample])
            }
        }
        return clusters
            .filter { $0.count >= 2 }
            .map { $0.sorted()[$0.count / 2] }
            .sorted(by: >)
    }
}
