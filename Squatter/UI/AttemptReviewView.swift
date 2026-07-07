import AVKit
import SwiftUI

/// Playback + trim for a recording before analysis: fresh sets land here
/// right after recording, and older unanalyzed attempts reopen here. Dragging
/// the trim handles cuts setup/walk-away time so analysis runs on just the
/// actual reps.
struct AttemptReviewView: View {
    let videoURL: URL
    let depthSidecarURL: URL?
    let onAnalyze: (RecordingResult) -> Void

    @State private var player: AVPlayer
    @State private var duration: TimeInterval = 0
    @State private var trimStart: TimeInterval = 0
    @State private var trimEnd: TimeInterval = 0

    /// Shortest analyzable window — roughly one slow rep.
    private static let minimumWindow: TimeInterval = 2

    init(videoURL: URL, depthSidecarURL: URL?, onAnalyze: @escaping (RecordingResult) -> Void) {
        self.videoURL = videoURL
        self.depthSidecarURL = depthSidecarURL
        self.onAnalyze = onAnalyze
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

            Button {
                onAnalyze(RecordingResult(
                    videoURL: videoURL,
                    depthSidecarURL: depthSidecarURL,
                    duration: duration,
                    usedLiDAR: depthSidecarURL != nil,
                    analysisRange: selectedRange
                ))
            } label: {
                Label(analyzeTitle, systemImage: "waveform.path.ecg")
                    .font(.system(.title3, design: .rounded).bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .prominentActionStyle()
        }
        .padding()
        .navigationTitle("Recorded set")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            duration = (try? await AVURLAsset(url: videoURL).load(.duration).seconds) ?? 0
            trimEnd = duration
            player.play()
        }
        .onDisappear { player.pause() }
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
        let trimmed = trimStart > 0.2 || trimEnd < duration - 0.2
        return trimmed ? trimStart ... trimEnd : nil
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
            .offset(x: x)
            .contentShape(Rectangle().inset(by: -12))
    }

    private func position(of time: TimeInterval, in width: CGFloat) -> CGFloat {
        duration > 0 ? CGFloat(time / duration) * width : 0
    }

    private func time(at x: CGFloat, in width: CGFloat) -> TimeInterval {
        width > 0 ? TimeInterval(min(max(x / width, 0), 1)) * duration : 0
    }
}
