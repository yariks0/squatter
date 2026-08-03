import SwiftUI

/// The drills the coach may prescribe, each with a looping animation. Kept
/// deliberately small and canonical: the model tags a corrective with the
/// closest topic (or "none"), exactly like `FormHintTopic` on findings, so
/// the app never has to render an arbitrary exercise name.
enum ExerciseHintTopic: String, CaseIterable, Sendable {
    // Mobility — restoring range the lifter doesn't currently own.
    case ankleRock
    case deepSquatHold
    case hipFlexorLunge
    case thoracicExtension
    case shoulderOpener
    // Strength — holding a range they can already reach, under load.
    case gobletSquat
    case pausedSquat
    case splitSquat
    case bandedHipAbduction
    case romanianDeadlift
    case deadBug

    var isMobility: Bool {
        switch self {
        case .ankleRock, .deepSquatHold, .hipFlexorLunge, .thoracicExtension, .shoulderOpener:
            true
        case .gobletSquat, .pausedSquat, .splitSquat, .bandedHipAbduction, .romanianDeadlift, .deadBug:
            false
        }
    }

    var displayName: String {
        switch self {
        case .ankleRock: "Knee-to-wall ankle rock"
        case .deepSquatHold: "Deep squat hold"
        case .hipFlexorLunge: "Half-kneeling hip flexor stretch"
        case .thoracicExtension: "Thoracic extension over a roller"
        case .shoulderOpener: "Overhead shoulder opener"
        case .gobletSquat: "Goblet squat"
        case .pausedSquat: "Paused squat"
        case .splitSquat: "Split squat"
        case .bandedHipAbduction: "Banded hip abduction"
        case .romanianDeadlift: "Romanian deadlift"
        case .deadBug: "Dead bug"
        }
    }

    /// Seconds for one out-and-back cycle — stretches breathe slower than
    /// strength reps, and a held position needs time to read as a hold.
    var period: Double {
        switch self {
        case .deepSquatHold, .hipFlexorLunge, .thoracicExtension, .shoulderOpener: 6
        case .ankleRock, .pausedSquat: 5
        default: 4
        }
    }

    /// Fraction of the cycle spent parked at the end position. Stretches and
    /// paused work are mostly hold; a rep barely pauses at all.
    var holdFraction: Double {
        switch self {
        case .deepSquatHold, .hipFlexorLunge, .thoracicExtension, .shoulderOpener: 0.5
        case .pausedSquat, .ankleRock: 0.35
        default: 0.1
        }
    }
}

/// Looping animation of one corrective drill: a schematic figure cycling
/// through the movement's range, held at the end when the drill is a hold.
/// Falls back to a static end position under Reduce Motion.
struct ExerciseHintView: View {
    let topic: ExerciseHintTopic

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                canvas(progress: 1)
            } else {
                TimelineView(.animation) { timeline in
                    canvas(progress: progress(at: timeline.date))
                }
            }
        }
        .frame(height: 118)
        .frame(maxWidth: .infinity)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topLeading) {
            Text(topic.displayName)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .accessibilityElement()
        .accessibilityLabel("\(topic.displayName) demonstration")
    }

    private func canvas(progress: CGFloat) -> some View {
        Canvas { context, size in
            var diagram = ExerciseDiagram(
                context: context,
                size: size,
                accent: topic.isMobility ? .teal : .purple
            )
            diagram.draw(topic, t: progress)
        }
    }

    /// 0 → 1 → 0 over one period, with a dwell at 1 for held drills. Eased so
    /// the figure settles into the end position instead of snapping.
    private func progress(at date: Date) -> CGFloat {
        let period = topic.period
        let cycle = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        let hold = topic.holdFraction
        let travel = (1 - hold) / 2
        let raw: Double = if cycle < travel {
            cycle / travel
        } else if cycle < travel + hold {
            1
        } else {
            1 - (cycle - travel - hold) / travel
        }
        // Smoothstep: no visible velocity discontinuity entering the hold.
        return CGFloat(raw * raw * (3 - 2 * raw))
    }
}

/// Side-view joint set in unit space (0…1, y down). One pose per end of the
/// movement; the diagram interpolates between them.
private struct Joints {
    var head: (CGFloat, CGFloat)
    var shoulder: (CGFloat, CGFloat)
    var hip: (CGFloat, CGFloat)
    var knee: (CGFloat, CGFloat)
    var ankle: (CGFloat, CGFloat)
    /// Where the hands (and any implement) sit.
    var hand: (CGFloat, CGFloat)

    static func lerp(_ a: Joints, _ b: Joints, _ t: CGFloat) -> Joints {
        func mix(_ p: (CGFloat, CGFloat), _ q: (CGFloat, CGFloat)) -> (CGFloat, CGFloat) {
            (p.0 + (q.0 - p.0) * t, p.1 + (q.1 - p.1) * t)
        }
        return Joints(
            head: mix(a.head, b.head), shoulder: mix(a.shoulder, b.shoulder),
            hip: mix(a.hip, b.hip), knee: mix(a.knee, b.knee),
            ankle: mix(a.ankle, b.ankle), hand: mix(a.hand, b.hand)
        )
    }
}

/// Unit-space drawing helpers, mirroring `FormDiagram` so both hint styles
/// share one visual language.
private struct ExerciseDiagram {
    let context: GraphicsContext
    let size: CGSize
    let accent: Color

    private var ink: Color { Color.primary.opacity(0.55) }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }

    private func path(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: point(first.0, first.1))
        for next in points.dropFirst() { path.addLine(to: point(next.0, next.1)) }
        return path
    }

    private func stroke(
        _ points: [(CGFloat, CGFloat)], _ color: Color,
        width: CGFloat = 2.5, dash: [CGFloat] = []
    ) {
        context.stroke(
            path(points),
            with: .color(color),
            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash)
        )
    }

    private func disc(_ x: CGFloat, _ y: CGFloat, radius: CGFloat, _ color: Color) {
        let center = point(x, y)
        let r = radius * size.height
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
            with: .color(color)
        )
    }

    private func arrow(from: (CGFloat, CGFloat), to: (CGFloat, CGFloat), _ color: Color) {
        stroke([from, to], color, width: 2)
        let tip = point(to.0, to.1)
        let tail = point(from.0, from.1)
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        var head = Path()
        for side in [angle + 2.6, angle - 2.6] {
            head.move(to: tip)
            head.addLine(to: CGPoint(x: tip.x + 6 * cos(side), y: tip.y + 6 * sin(side)))
        }
        context.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ color: Color) {
        context.draw(
            Text(text).font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(color),
            at: point(x, y)
        )
    }

    private func floor(_ y: CGFloat = 0.90) {
        stroke([(0.06, y), (0.94, y)], ink.opacity(0.5), width: 1.5)
    }

    /// Head → shoulder → hip → knee → ankle → toe, facing right.
    private func figure(_ j: Joints, limb: Color? = nil, trunk: Color? = nil) {
        stroke([j.shoulder, j.hip], trunk ?? ink)
        stroke([j.hip, j.knee, j.ankle], limb ?? ink)
        stroke([j.ankle, (j.ankle.0 + 0.08, j.ankle.1)], limb ?? ink)
        disc(j.head.0, j.head.1, radius: 0.05, trunk ?? ink)
    }

    mutating func draw(_ topic: ExerciseHintTopic, t: CGFloat) {
        switch topic {
        case .ankleRock:
            floor()
            stroke([(0.88, 0.20), (0.88, 0.90)], ink.opacity(0.5), width: 3) // the wall
            let start = Joints(
                head: (0.34, 0.20), shoulder: (0.36, 0.30), hip: (0.38, 0.54),
                knee: (0.56, 0.68), ankle: (0.56, 0.90), hand: (0.44, 0.44)
            )
            let end = Joints(
                head: (0.40, 0.22), shoulder: (0.42, 0.32), hip: (0.42, 0.56),
                knee: (0.78, 0.66), ankle: (0.56, 0.90), hand: (0.52, 0.46)
            )
            let j = Joints.lerp(start, end, t)
            // Trailing leg stays put; the front knee is the whole point.
            stroke([j.hip, (0.30, 0.74), (0.24, 0.90)], ink)
            figure(j, limb: accent)
            // The heel must never leave the floor — that's the whole drill.
            disc(0.56, 0.90, radius: 0.022, .green)
            label("heel down", 0.30, 0.97, .green)
            arrow(from: (0.62, 0.44), to: (0.62 + 0.16 * t, 0.44), accent)

        case .deepSquatHold:
            floor()
            let stand = Joints(
                head: (0.50, 0.14), shoulder: (0.50, 0.24), hip: (0.49, 0.52),
                knee: (0.50, 0.72), ankle: (0.50, 0.90), hand: (0.44, 0.44)
            )
            let bottom = Joints(
                head: (0.54, 0.32), shoulder: (0.51, 0.42), hip: (0.36, 0.72),
                knee: (0.60, 0.64), ankle: (0.50, 0.90), hand: (0.48, 0.56)
            )
            let j = Joints.lerp(stand, bottom, t)
            figure(j, limb: accent)
            stroke([j.shoulder, j.hand], ink) // elbows inside the knees
            if t > 0.85 { label("hold", 0.22, 0.30, accent) }

        case .hipFlexorLunge:
            floor()
            // Half-kneeling, rear knee down; the pelvis tucks and drives forward.
            let hip: (CGFloat, CGFloat) = (0.46 + 0.08 * t, 0.56)
            let shoulder: (CGFloat, CGFloat) = (0.44 + 0.07 * t, 0.30)
            stroke([shoulder, hip], ink)
            disc(0.43 + 0.07 * t, 0.20, radius: 0.05, ink)
            stroke([hip, (0.68, 0.66), (0.70, 0.90)], ink) // front leg planted
            stroke([hip, (0.30, 0.88), (0.16, 0.86)], accent) // rear thigh + shin down
            disc(0.30, 0.88, radius: 0.02, accent) // rear knee on the floor
            arrow(from: (0.48, 0.44), to: (0.48 + 0.12 * t, 0.44), accent)
            label("tuck + press", 0.72, 0.30, accent)

        case .thoracicExtension:
            floor()
            // Supine over a roller, upper back opening backwards.
            disc(0.46, 0.72, radius: 0.055, ink.opacity(0.5)) // the roller
            stroke([(0.62, 0.66), (0.74, 0.78), (0.74, 0.90)], ink) // hip → knee → foot
            let apex: (CGFloat, CGFloat) = (0.30 - 0.06 * t, 0.62 + 0.12 * t)
            var spine = Path()
            spine.move(to: point(0.62, 0.66))
            spine.addQuadCurve(to: point(apex.0, apex.1), control: point(0.44, 0.56 + 0.10 * t))
            context.stroke(
                spine, with: .color(accent),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            disc(apex.0 - 0.03, apex.1 + 0.02, radius: 0.05, accent)
            arrow(from: (0.30, 0.42), to: (0.24, 0.50 + 0.10 * t), accent)
            label("open over the roller", 0.62, 0.34, accent)

        case .shoulderOpener:
            floor()
            let j = Joints(
                head: (0.48, 0.22), shoulder: (0.48, 0.32), hip: (0.48, 0.58),
                knee: (0.49, 0.74), ankle: (0.48, 0.90), hand: (0.48, 0.32)
            )
            figure(j)
            // Arms sweep from in front of the chest to overhead and back.
            let elbow: (CGFloat, CGFloat) = (0.62 - 0.10 * t, 0.40 - 0.16 * t)
            let hand: (CGFloat, CGFloat) = (0.70 - 0.18 * t, 0.30 - 0.22 * t)
            stroke([j.shoulder, elbow, hand], accent)
            stroke([(0.48, 0.10), (0.48, 0.62)], ink.opacity(0.35), width: 1, dash: [3, 3])
            label("reach overhead", 0.74, 0.72, accent)

        case .gobletSquat, .pausedSquat:
            floor()
            let stand = Joints(
                head: (0.50, 0.14), shoulder: (0.50, 0.24), hip: (0.49, 0.52),
                knee: (0.50, 0.72), ankle: (0.50, 0.90), hand: (0.40, 0.32)
            )
            let bottom = Joints(
                head: (0.53, 0.28), shoulder: (0.50, 0.38), hip: (0.36, 0.70),
                knee: (0.59, 0.63), ankle: (0.50, 0.90), hand: (0.40, 0.46)
            )
            let j = Joints.lerp(stand, bottom, t)
            figure(j, limb: accent)
            if topic == .gobletSquat {
                stroke([j.shoulder, j.hand], ink) // arms cradling the bell
                disc(j.hand.0, j.hand.1, radius: 0.045, .secondary)
            } else {
                disc(j.shoulder.0, j.shoulder.1, radius: 0.03, .secondary) // bar on the back
                stroke([(j.shoulder.0 - 0.10, j.shoulder.1), (j.shoulder.0 + 0.10, j.shoulder.1)],
                       .secondary, width: 3)
                if t > 0.85 { label("pause 2 s", 0.22, 0.34, accent) }
            }

        case .splitSquat:
            floor()
            stroke([(0.72, 0.72), (0.92, 0.72)], ink.opacity(0.45), width: 4) // the bench
            stroke([(0.80, 0.72), (0.80, 0.90)], ink.opacity(0.45), width: 2)
            let hip: (CGFloat, CGFloat) = (0.46, 0.50 + 0.18 * t)
            let shoulder: (CGFloat, CGFloat) = (0.46, 0.26 + 0.16 * t)
            disc(0.46, 0.17 + 0.16 * t, radius: 0.05, ink)
            stroke([shoulder, hip], ink)
            stroke([hip, (0.36, 0.72 + 0.06 * t), (0.36, 0.90)], accent) // front leg works
            stroke([hip, (0.62, 0.74), (0.74, 0.72)], ink) // rear foot on the bench
            arrow(from: (0.24, 0.46), to: (0.24, 0.46 + 0.20 * t), accent)

        case .bandedHipAbduction:
            // Front view: the band resists the knees pushing apart.
            floor()
            stroke([(0.36, 0.34), (0.64, 0.34)], ink) // pelvis
            disc(0.50, 0.24, radius: 0.05, ink)
            let kneeSpread = 0.04 + 0.10 * t
            let leftKnee: (CGFloat, CGFloat) = (0.46 - kneeSpread, 0.60)
            let rightKnee: (CGFloat, CGFloat) = (0.54 + kneeSpread, 0.60)
            stroke([(0.38, 0.34), leftKnee, (0.30, 0.90)], accent)
            stroke([(0.62, 0.34), rightKnee, (0.70, 0.90)], accent)
            // The band across the knees, stretched by the spread.
            stroke([leftKnee, rightKnee], .orange, width: 3)
            arrow(from: (leftKnee.0 + 0.02, 0.50), to: (leftKnee.0 - 0.06, 0.50), accent)
            arrow(from: (rightKnee.0 - 0.02, 0.50), to: (rightKnee.0 + 0.06, 0.50), accent)
            label("drive knees out", 0.50, 0.98, accent)

        case .romanianDeadlift:
            floor()
            let stand = Joints(
                head: (0.46, 0.14), shoulder: (0.46, 0.24), hip: (0.46, 0.52),
                knee: (0.47, 0.72), ankle: (0.46, 0.90), hand: (0.46, 0.50)
            )
            let hinged = Joints(
                head: (0.24, 0.34), shoulder: (0.28, 0.40), hip: (0.54, 0.54),
                knee: (0.50, 0.72), ankle: (0.46, 0.90), hand: (0.32, 0.72)
            )
            let j = Joints.lerp(stand, hinged, t)
            // Back stays one straight line — that's the point of the drill.
            stroke([j.shoulder, j.hip], accent)
            stroke([j.hip, j.knee, j.ankle], ink)
            stroke([j.ankle, (j.ankle.0 + 0.08, j.ankle.1)], ink)
            disc(j.head.0, j.head.1, radius: 0.05, accent)
            stroke([j.shoulder, j.hand], ink) // arms hang straight down
            disc(j.hand.0, j.hand.1, radius: 0.03, .secondary) // the bar
            arrow(from: (0.72, 0.42), to: (0.72 + 0.10 * t, 0.42), accent)
            label("hips back", 0.80, 0.34, accent)

        case .deadBug:
            floor()
            // Supine, low back pinned; opposite arm and leg reach away.
            stroke([(0.34, 0.72), (0.66, 0.72)], ink, width: 2.5) // trunk on the floor
            disc(0.30, 0.70, radius: 0.05, ink)
            stroke([(0.34, 0.72), (0.34, 0.86)], .green, width: 2) // ribs down marker
            // Arm overhead and leg out, both extending together.
            let hand: (CGFloat, CGFloat) = (0.34 - 0.16 * t, 0.56 - 0.02 * t)
            stroke([(0.38, 0.70), (0.36 - 0.06 * t, 0.60), hand], accent)
            let foot: (CGFloat, CGFloat) = (0.78 + 0.14 * t, 0.60 + 0.14 * t)
            stroke([(0.64, 0.72), (0.74, 0.58), foot], accent)
            label("back flat", 0.50, 0.98, .green)
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 14) {
            ForEach(ExerciseHintTopic.allCases, id: \.rawValue) { topic in
                ExerciseHintView(topic: topic)
            }
        }
        .padding()
    }
}
