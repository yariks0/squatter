import AVFoundation

/// Physically cuts a recording down to the user's selected timeline window.
/// The video is remuxed (passthrough, no re-encode) to just the selection,
/// the depth sidecar is rewritten with rebased timestamps, and the uncut
/// originals are replaced in place — same URLs, same creation date — so the
/// walk-in/walk-away footage stops taking disk space and every downstream
/// consumer (analysis, playback, coach keyframes) sees one consistent file.
enum RecordingTrimmer {
    enum TrimError: LocalizedError {
        case exportUnavailable
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .exportUnavailable: "This recording cannot be trimmed."
            case .exportFailed: "Trimming the recording failed."
            }
        }
    }

    /// Replaces the files behind `recording` with just `range` and returns
    /// the recording rebased to the trimmed timeline (no `analysisRange`).
    /// Passthrough export cuts at the sync frame at or before the requested
    /// start, so the kept clip may begin slightly early; the actual start is
    /// measured from the exported duration and the sidecar is shifted by
    /// exactly that, keeping depth aligned to the video. Throws with the
    /// original files untouched.
    static func trim(
        _ recording: RecordingResult, to range: ClosedRange<TimeInterval>
    ) async throws -> RecordingResult {
        let asset = AVURLAsset(url: recording.videoURL)
        let originalDuration = try await asset.load(.duration).seconds
        let end = min(range.upperBound, originalDuration)

        let temporaryVideo = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: temporaryVideo) }
        try await export(asset, over: range.lowerBound ... end, to: temporaryVideo)

        let trimmedDuration = try await AVURLAsset(url: temporaryVideo).load(.duration).seconds
        guard trimmedDuration > 0 else { throw TrimError.exportFailed }
        let actualStart = max(0, end - trimmedDuration)

        // Rebase the sidecar before touching the original video: an aborted
        // trim must never leave a cut video next to an unshifted sidecar —
        // depth would silently mismatch every frame.
        var temporarySidecar: URL?
        if let sidecarURL = recording.depthSidecarURL {
            let trimmed = try trimmedSidecar(
                try Data(contentsOf: sidecarURL, options: .mappedIfSafe),
                keeping: actualStart ... end,
                rebasedTo: actualStart
            )
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(DepthSidecar.fileExtension)
            try trimmed.write(to: destination)
            temporarySidecar = destination
        }

        // Keep the original creation date: recordings list and session rows
        // sort and label by it, and a trim must not make an old set "new".
        let creationDate = (try? recording.videoURL.resourceValues(forKeys: [.creationDateKey]))?
            .creationDate
        _ = try FileManager.default.replaceItemAt(recording.videoURL, withItemAt: temporaryVideo)
        if let sidecarURL = recording.depthSidecarURL, let temporarySidecar {
            _ = try? FileManager.default.replaceItemAt(sidecarURL, withItemAt: temporarySidecar)
        }
        if let creationDate {
            try? FileManager.default.setAttributes(
                [.creationDate: creationDate], ofItemAtPath: recording.videoURL.path
            )
        }

        return RecordingResult(
            videoURL: recording.videoURL,
            depthSidecarURL: recording.depthSidecarURL,
            duration: trimmedDuration,
            usedLiDAR: recording.usedLiDAR,
            analysisRange: nil,
            weightKg: recording.weightKg
        )
    }

    private static func export(
        _ asset: AVAsset, over range: ClosedRange<TimeInterval>, to destination: URL
    ) async throws {
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough
        ) else { throw TrimError.exportUnavailable }
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
            end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
        )
        if #available(iOS 18, *) {
            try await session.export(to: destination, as: .mov)
        } else {
            session.outputURL = destination
            session.outputFileType = .mov
            await session.export()
            guard session.status == .completed else {
                throw session.error ?? TrimError.exportFailed
            }
        }
    }

    /// Depth records this far outside the kept window survive the cut, so
    /// the frames at the very edges of the trimmed video still find a depth
    /// match within `PoseExtractor`'s tolerance.
    static let sidecarSlack: TimeInterval = 0.2

    /// Rewrites sidecar bytes to only the records near `range` (± slack),
    /// shifting each timestamp by `-timeOffset` so the sidecar lines up with
    /// a video whose new zero is `timeOffset` on the old timeline. Records
    /// are copied verbatim (no depth decode); the header — version, focal
    /// length, camera pitch — is preserved as-is.
    static func trimmedSidecar(
        _ data: Data, keeping range: ClosedRange<TimeInterval>, rebasedTo timeOffset: TimeInterval
    ) throws -> Data {
        guard data.count >= 8, data.prefix(4) == DepthSidecar.magic else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func read<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
            T(littleEndian: data.subdata(in: offset ..< offset + MemoryLayout<T>.size)
                .withUnsafeBytes { $0.loadUnaligned(as: T.self) })
        }
        let version = read(UInt32.self, at: 4)
        guard version <= DepthSidecar.version else { throw CocoaError(.fileReadCorruptFile) }
        let headerLength = version >= 3 ? 16 : (version >= 2 ? 12 : 8)
        guard data.count >= headerLength else { throw CocoaError(.fileReadCorruptFile) }

        var trimmed = data.subdata(in: 0 ..< headerLength)
        var offset = headerLength
        while offset + 16 <= data.count {
            let time = Double(bitPattern: read(UInt64.self, at: offset))
            let descriptionLength = Int(read(UInt32.self, at: offset + 8))
            let depthLength = Int(read(UInt32.self, at: offset + 12))
            let recordEnd = offset + 16 + descriptionLength + depthLength
            guard recordEnd <= data.count else { break }
            if time >= range.lowerBound - sidecarSlack, time <= range.upperBound + sidecarSlack {
                withUnsafeBytes(of: (time - timeOffset).bitPattern.littleEndian) {
                    trimmed.append(contentsOf: $0)
                }
                trimmed.append(data.subdata(in: offset + 8 ..< recordEnd))
            }
            offset = recordEnd
        }
        return trimmed
    }
}
