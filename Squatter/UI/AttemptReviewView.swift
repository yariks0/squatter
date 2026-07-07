import AVKit
import SwiftUI

/// Playback for a recording that was never analyzed (the app was closed
/// mid-flow or analysis failed), with the option to run analysis now.
struct AttemptReviewView: View {
    let videoURL: URL
    let depthSidecarURL: URL?
    let onAnalyze: (RecordingResult) -> Void

    @State private var player: AVPlayer
    @State private var duration: TimeInterval = 0

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
                    usedLiDAR: depthSidecarURL != nil
                ))
            } label: {
                Label("Analyze this set", systemImage: "waveform.path.ecg")
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
            player.play()
        }
        .onDisappear { player.pause() }
    }

    private var creationDate: Date? {
        (try? videoURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}
