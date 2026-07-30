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
    var reps: [RepMetrics] = []
    var activity: ActivityType = .squat

    var body: some View {
        VideoPlayer(player: playback.player) {
            SkeletonOverlay(
                series: series, reps: reps, activity: activity, time: playback.currentTime
            )
        }
        .aspectRatio(9 / 16, contentMode: .fit)
    }
}

private struct SkeletonOverlay: View {
    let series: JointSeries
    let reps: [RepMetrics]
    let activity: ActivityType
    let time: TimeInterval

    var body: some View {
        Canvas { context, size in
            guard let frame = series.nearestFrame(to: time) else { return }
            let faults = FormFaultDetector.faults(
                in: frame, at: frame.time, reps: reps, activity: activity
            )
            // Classification (fault red / ok green / uncertain dim, uncertain
            // wins) lives in SkeletonRenderer, shared with the coach keyframe
            // compositor.
            let segments = SkeletonRenderer.segments(frame: frame, faults: faults, size: size)
            func path(_ state: SkeletonRenderer.SegmentState) -> Path {
                var path = Path()
                for bone in segments.bones where bone.state == state {
                    path.move(to: bone.from)
                    path.addLine(to: bone.to)
                }
                return path
            }
            context.stroke(
                path(.ok), with: .color(.green.opacity(0.8)),
                lineWidth: SkeletonRenderer.okLineWidth
            )
            context.stroke(
                path(.fault), with: .color(.red.opacity(0.9)),
                lineWidth: SkeletonRenderer.faultLineWidth
            )
            context.stroke(
                path(.uncertain), with: .color(.green.opacity(0.25)),
                lineWidth: SkeletonRenderer.uncertainLineWidth
            )
            let radius = SkeletonRenderer.jointDotRadius
            for joint in segments.joints {
                let color: Color = switch joint.state {
                case .uncertain: .green.opacity(0.25)
                case .fault: .red
                case .ok: .green
                }
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: joint.point.x - radius, y: joint.point.y - radius,
                        width: radius * 2, height: radius * 2
                    )),
                    with: .color(color)
                )
            }
        }
        .allowsHitTesting(false)
    }
}
