import AVKit
import SwiftUI

/// Playback + trim for a recording before analysis: fresh sets land here
/// right after recording, and older unanalyzed attempts reopen here. Dragging
/// the trim handles cuts setup/walk-away time; analyzing a trimmed selection
/// cuts the file itself — only the selection is kept on disk.
struct AttemptReviewView: View {
    let videoURL: URL
    let depthSidecarURL: URL?
    let onAnalyze: (RecordingResult, ActivityType) -> Void

    @State private var player: AVPlayer
    @State private var duration: TimeInterval = 0
    @State private var trimStart: TimeInterval = 0
    @State private var trimEnd: TimeInterval = 0
    @State private var activity: ActivityType
    @State private var weightText = ""
    @State private var detectedPlates: [PlateDetector.Sighting] = []
    @State private var plateScan: PlateScanStatus = .searching
    /// What prefill last wrote — an unchanged field may be re-prefilled on
    /// activity switch, a typed or detection-derived value may not.
    @State private var lastPrefilledText = ""
    /// Trim start of the last empty-handed rescan, to skip redundant passes.
    @State private var rescannedFrom: TimeInterval = -1
    /// True while the selection is being cut out of the file on disk.
    @State private var trimming = false

    /// Shortest analyzable window — roughly one slow rep.
    private static let minimumWindow: TimeInterval = 2

    init(
        videoURL: URL,
        depthSidecarURL: URL?,
        initialActivity: ActivityType = .squat,
        onAnalyze: @escaping (RecordingResult, ActivityType) -> Void
    ) {
        self.videoURL = videoURL
        self.depthSidecarURL = depthSidecarURL
        self.onAnalyze = onAnalyze
        _activity = State(initialValue: initialActivity)
        _player = State(initialValue: AVPlayer(url: videoURL))
    }

    var body: some View {
        VStack(spacing: 16) {
            VideoPlayer(player: player)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            if duration > Self.minimumWindow {
                trimSection
            }

            HStack(spacing: 6) {
                if let date = creationDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                if duration > 0 {
                    Text("· \(Int(duration.rounded())) s")
                }
                if depthSidecarURL != nil {
                    Label("LiDAR depth", systemImage: "sensor.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            KodoSegmentedPicker(
                options: ActivityType.allCases,
                label: \.displayName,
                selection: $activity
            )

            weightField

            PlatePickerView(
                weightText: $weightText,
                detected: detectedPlates,
                scanStatus: plateScan
            )

            Button(action: analyze) {
                if trimming {
                    Label("Trimming recording…", systemImage: "scissors")
                } else {
                    Label(analyzeTitle, systemImage: "waveform.path.ecg")
                }
            }
            .buttonStyle(KodoProminentButtonStyle(fullWidth: true))
            .disabled(trimming)
        }
        .padding()
        .navigationTitle("Recorded set")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            duration = (try? await AVURLAsset(url: videoURL).load(.duration).seconds) ?? 0
            trimStart = 0
            trimEnd = duration
            prefillWeight()
            player.play()
            // Plate recognition off the setup frames — suggestion only, the
            // field stays the user's.
            if depthSidecarURL == nil {
                plateScan = .noDepth
            } else if let detection = await PlateDetector.detect(
                videoURL: videoURL, depthSidecarURL: depthSidecarURL
            ), !detection.sightings.isEmpty {
                detectedPlates = detection.sightings
                plateScan = .found
            } else {
                plateScan = .none
            }
        }
        .onChange(of: activity) { prefillWeight() }
        .onDisappear { player.pause() }
    }

    /// Hands the recording to analysis. A trimmed selection is first cut out
    /// of the file on disk (`RecordingTrimmer`) — the uncut original is
    /// deleted and the review state rebases to the trimmed timeline, so
    /// coming back to this screen shows the file that actually exists. If
    /// the cut fails the original stays untouched and analysis falls back to
    /// reading just the selected window.
    private func analyze() {
        if let weight = enteredWeightKg {
            UserDefaults.standard.set(weight, forKey: Self.lastWeightKey(for: activity))
        }
        let recording = RecordingResult(
            videoURL: videoURL,
            depthSidecarURL: depthSidecarURL,
            duration: duration,
            usedLiDAR: depthSidecarURL != nil,
            analysisRange: selectedRange,
            weightKg: enteredWeightKg
        )
        guard let range = selectedRange else {
            onAnalyze(recording, activity)
            return
        }
        trimming = true
        player.pause()
        Task {
            defer { trimming = false }
            if let trimmed = try? await RecordingTrimmer.trim(recording, to: range) {
                rebase(to: trimmed)
                onAnalyze(trimmed, activity)
            } else {
                onAnalyze(recording, activity)
            }
        }
    }

    /// Points the review state at the trimmed file: full-range handles, new
    /// duration, and a fresh player item (the old one still reads the
    /// deleted original through its open file handle).
    private func rebase(to trimmed: RecordingResult) {
        duration = trimmed.duration
        trimStart = 0
        trimEnd = trimmed.duration
        rescannedFrom = -1
        player.replaceCurrentItem(with: AVPlayerItem(asset: AVURLAsset(url: trimmed.videoURL)))
    }

    /// Load on the bar: optional, but it feeds the load–velocity profile
    /// and 1RM estimate, so the last-used weight per lift is prefilled.
    private var weightField: some View {
        HStack(spacing: 8) {
            Image(systemName: "scalemass")
                .foregroundStyle(.secondary)
            TextField("Weight on the bar", text: $weightText)
                .keyboardType(.decimalPad)
            Text("kg")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var enteredWeightKg: Double? {
        let weight = Double(weightText.replacingOccurrences(of: ",", with: "."))
        return weight.flatMap { $0 > 0 ? $0 : nil }
    }

    private static func lastWeightKey(for activity: ActivityType) -> String {
        "lastWeightKg.\(activity.rawValue)"
    }

    private func prefillWeight() {
        // Only touch a field that is empty or still holds the previous
        // prefill — switching activity must not clobber a typed weight or a
        // plate-detection total.
        guard weightText.isEmpty || weightText == lastPrefilledText else { return }
        let stored = UserDefaults.standard.double(forKey: Self.lastWeightKey(for: activity))
        weightText = stored > 0 ? String(format: "%g", stored) : ""
        lastPrefilledText = weightText
    }

    private var trimSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TrimRangeBar(
                duration: duration,
                minimumWindow: Self.minimumWindow,
                start: $trimStart,
                end: $trimEnd
            ) { time in
                player.pause()
                player.seek(
                    to: CMTime(seconds: time, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero
                )
            } onScrubEnded: {
                rescanPlatesInTrimmedWindow()
            }
            Text(selectedRange == nil
                ? "Drag the handles to trim to just your reps — analysis skips the rest."
                : "Analyzing \(timeLabel(trimStart)) – \(timeLabel(trimEnd)) only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Non-nil only when the handles were actually moved off the ends.
    private var selectedRange: ClosedRange<TimeInterval>? {
        guard duration > 0, trimEnd > trimStart else { return nil }
        let trimmed = trimStart > 0.01 || trimEnd < duration - 0.01
        return trimmed ? trimStart ... trimEnd : nil
    }

    /// Fallback pass when the primary scan came up empty: the primary scan
    /// covers the first seconds of the raw file, but if the lifter trimmed a
    /// long walk-in away, the frames worth scanning start at the trim point.
    private func rescanPlatesInTrimmedWindow() {
        guard plateScan == .none, trimStart > 1, let range = selectedRange,
              abs(trimStart - rescannedFrom) > 0.5
        else { return }
        rescannedFrom = trimStart
        plateScan = .searching
        Task {
            if let detection = await PlateDetector.detect(
                videoURL: videoURL, depthSidecarURL: depthSidecarURL, within: range
            ), !detection.sightings.isEmpty {
                detectedPlates = detection.sightings
                plateScan = .found
            } else {
                plateScan = .none
            }
        }
    }

    private var analyzeTitle: String {
        selectedRange == nil ? "Analyze this set" : "Analyze selected part"
    }

    private func timeLabel(_ time: TimeInterval) -> String {
        Duration.seconds(time).formatted(.time(pattern: .minuteSecond))
    }

    private var creationDate: Date? {
        (try? videoURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}

/// Two-handle range selector over the recording's timeline. Dragging a handle
/// seeks the player so the cut point can be lined up by eye.
private struct TrimRangeBar: View {
    let duration: TimeInterval
    let minimumWindow: TimeInterval
    @Binding var start: TimeInterval
    @Binding var end: TimeInterval
    var onScrub: (TimeInterval) -> Void
    var onScrubEnded: () -> Void = {}

    private let handleWidth: CGFloat = 22
    private let barHeight: CGFloat = 40

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let startX = position(of: start, in: width)
            let endX = position(of: end, in: width)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 10)
                    .fill(.tint.opacity(0.25))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.tint, lineWidth: 2)
                    )
                    .frame(width: max(endX - startX, handleWidth))
                    .offset(x: startX)

                // Drag locations must be read in the bar's coordinate space —
                // the handles are offset views, so their local space always
                // reports x near zero and the handle sticks at the left edge.
                handle(at: startX, systemImage: "chevron.compact.left")
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.spaceName))
                            .onChanged { value in
                                start = min(
                                    max(0, time(at: value.location.x, in: width)),
                                    end - minimumWindow
                                )
                                onScrub(start)
                            }
                            .onEnded { _ in onScrubEnded() }
                    )
                handle(at: endX - handleWidth, systemImage: "chevron.compact.right")
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.spaceName))
                            .onChanged { value in
                                end = max(
                                    min(duration, time(at: value.location.x, in: width)),
                                    start + minimumWindow
                                )
                                onScrub(end)
                            }
                            .onEnded { _ in onScrubEnded() }
                    )
            }
            .coordinateSpace(name: Self.spaceName)
        }
        .frame(height: barHeight)
    }

    private static let spaceName = "trimBar"

    private func handle(at x: CGFloat, systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.accentColor)
            .frame(width: handleWidth, height: barHeight)
            .overlay(
                Image(systemName: systemImage)
                    .font(.footnote.bold())
                    .foregroundStyle(.white)
            )
            // contentShape must come *before* offset: offset is a geometry
            // effect that doesn't move the layout frame, and a hit shape
            // applied outside it stays pinned at the un-offset position —
            // both handles then overlap at the bar's left edge and the top
            // one swallows every drag.
            .contentShape(Rectangle().inset(by: -12))
            .offset(x: x)
    }

    private func position(of time: TimeInterval, in width: CGFloat) -> CGFloat {
        duration > 0 ? CGFloat(time / duration) * width : 0
    }

    private func time(at x: CGFloat, in width: CGFloat) -> TimeInterval {
        width > 0 ? TimeInterval(min(max(x / width, 0), 1)) * duration : 0
    }
}
