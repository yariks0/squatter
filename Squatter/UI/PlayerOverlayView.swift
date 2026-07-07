import AVKit
import SwiftUI

@MainActor
@Observable
final class PlaybackModel {
    let player: AVPlayer
    private(set) var currentTime: TimeInterval = 0
    // Torn down in deinit, which is nonisolated in Swift 6.
    nonisolated(unsafe) private var observer: Any?

    init(videoURL: URL) {
        player = AVPlayer(url: videoURL)
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
            }
        }
    }

    func seek(to seconds: TimeInterval) {
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
    }
}

/// Video playback with the tracked skeleton drawn on top, so the user can see
/// what the analysis saw.
struct PlayerOverlayView: View {
    let playback: PlaybackModel
    let series: JointSeries

    var body: some View {
        VideoPlayer(player: playback.player) {
            SkeletonOverlay(series: series, time: playback.currentTime)
        }
        .aspectRatio(9 / 16, contentMode: .fit)
    }
}

private struct SkeletonOverlay: View {
    let series: JointSeries
    let time: TimeInterval

    var body: some View {
        Canvas { context, size in
            guard let frame = nearestFrame(to: time) else { return }
            func point(_ joint: BodyJoint) -> CGPoint? {
                guard let p = frame.imagePoints[joint] else { return nil }
                // Vision image points: normalized, origin bottom-left.
                return CGPoint(x: CGFloat(p.x) * size.width, y: (1 - CGFloat(p.y)) * size.height)
            }
            var path = Path()
            for (a, b) in BodyJoint.bones {
                guard let pa = point(a), let pb = point(b) else { continue }
                path.move(to: pa)
                path.addLine(to: pb)
            }
            context.stroke(path, with: .color(.green.opacity(0.8)), lineWidth: 3)
            for joint in BodyJoint.allCases {
                guard let p = point(joint) else { continue }
                context.fill(
                    Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                    with: .color(.green)
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func nearestFrame(to time: TimeInterval) -> JointFrame? {
        let frames = series.frames
        guard !frames.isEmpty else { return nil }
        var low = 0, high = frames.count - 1
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].time < time { low = mid + 1 } else { high = mid }
        }
        // Pick the closer of the found frame and its predecessor; hide the
        // skeleton if tracking dropped out for more than a quarter second.
        var best = frames[low]
        if low > 0, abs(frames[low - 1].time - time) < abs(best.time - time) {
            best = frames[low - 1]
        }
        return abs(best.time - time) <= 0.25 ? best : nil
    }
}
