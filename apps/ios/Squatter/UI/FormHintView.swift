import SwiftUI

/// Wrong-vs-right diagram for a coaching topic: two schematic stick-figure
/// panels, the fault stroked red on the left and the corrected position
/// green on the right, so a cue reads at a glance without any text.
struct FormHintView: View {
    let topic: FormHintTopic

    var body: some View {
        HStack(spacing: 10) {
            panel(correct: false)
            panel(correct: true)
        }
        // Two letterboxed panels side by side: each figure is capped by the
        // panel's height, so this drives how large the diagrams read.
        .frame(height: 150)
    }

    private func panel(correct: Bool) -> some View {
        Canvas { context, size in
            var diagram = FormDiagram(
                context: context,
                size: size,
                accent: correct ? .green : .red
            )
            diagram.draw(topic, correct: correct)
        }
        .frame(maxWidth: .infinity)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            Image(systemName: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(correct ? .green : .red)
                .padding(5)
        }
        .accessibilityLabel(correct ? "Correct position" : "Faulty position")
    }
}

/// Unit-space (0…1, y down) drawing helpers over a `GraphicsContext`.
private struct FormDiagram {
    let context: GraphicsContext
    let size: CGSize
    let accent: Color

    private var ink: Color { Color.primary.opacity(0.55) }

    /// Square unit space, letterboxed into the panel — see the matching note
    /// in `ExerciseDiagram`. Both hint styles share one visual language, so
    /// they share this mapping too.
    private var side: CGFloat { min(size.width, size.height) }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(
            x: (size.width - side) / 2 + x * side,
            y: (size.height - side) / 2 + y * side
        )
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
        let r = radius * side
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
            head.addLine(to: CGPoint(x: tip.x + 7 * cos(side), y: tip.y + 7 * sin(side)))
        }
        context.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ color: Color) {
        context.draw(
            Text(text).font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(color),
            at: point(x, y)
        )
    }

    private func floor(_ y: CGFloat = 0.92) {
        stroke([(0.06, y), (0.94, y)], ink.opacity(0.5), width: 1.5)
    }

    /// Side-view squatting figure facing right; joints in unit space.
    private func sideFigure(
        head: (CGFloat, CGFloat), shoulder: (CGFloat, CGFloat), hip: (CGFloat, CGFloat),
        knee: (CGFloat, CGFloat), ankle: (CGFloat, CGFloat),
        torso torsoColor: Color? = nil, legs legColor: Color? = nil
    ) {
        stroke([shoulder, hip], torsoColor ?? ink)
        stroke([hip, knee, ankle], legColor ?? ink)
        stroke([ankle, (ankle.0 + 0.09, ankle.1)], legColor ?? ink)
        disc(head.0, head.1, radius: 0.055, torsoColor ?? ink)
        disc(shoulder.0, shoulder.1, radius: 0.028, .secondary) // bar on the back
    }

    /// Side view of a lifter on a bench, head to the left; returns nothing,
    /// arms are drawn by the caller since they carry the fault.
    private func benchFigure() {
        stroke([(0.12, 0.68), (0.66, 0.68)], ink.opacity(0.45), width: 4) // bench pad
        stroke([(0.20, 0.68), (0.20, 0.92)], ink.opacity(0.45), width: 2) // legs of the bench
        stroke([(0.58, 0.68), (0.58, 0.92)], ink.opacity(0.45), width: 2)
        disc(0.18, 0.60, radius: 0.05, ink) // head
        stroke([(0.24, 0.62), (0.52, 0.63)], ink) // torso on the pad
        stroke([(0.52, 0.63), (0.66, 0.74), (0.70, 0.92)], ink) // thigh + shin to the floor
    }

    mutating func draw(_ topic: FormHintTopic, correct: Bool) {
        switch topic {
        case .squatDepth:
            floor()
            // Dashed parallel line through the knee: the depth reference.
            stroke([(0.12, 0.62), (0.88, 0.62)], ink.opacity(0.5), width: 1, dash: [3, 3])
            label("parallel", 0.80, 0.56, .secondary)
            if correct {
                sideFigure(
                    head: (0.53, 0.28), shoulder: (0.50, 0.38), hip: (0.34, 0.70),
                    knee: (0.56, 0.62), ankle: (0.48, 0.92), torso: nil, legs: accent
                )
                arrow(from: (0.24, 0.55), to: (0.24, 0.70), accent)
            } else {
                sideFigure(
                    head: (0.51, 0.16), shoulder: (0.48, 0.26), hip: (0.36, 0.50),
                    knee: (0.58, 0.62), ankle: (0.50, 0.92), torso: nil, legs: accent
                )
            }
        case .torsoLean:
            floor()
            if correct {
                sideFigure(
                    head: (0.50, 0.24), shoulder: (0.47, 0.34), hip: (0.36, 0.68),
                    knee: (0.58, 0.60), ankle: (0.50, 0.92), torso: accent
                )
            } else {
                sideFigure(
                    head: (0.66, 0.36), shoulder: (0.60, 0.42), hip: (0.34, 0.66),
                    knee: (0.56, 0.60), ankle: (0.48, 0.92), torso: accent
                )
                arrow(from: (0.52, 0.28), to: (0.66, 0.28), accent)
            }
        case .kneeValgus:
            // Front view: hips, two legs, feet planted.
            floor()
            stroke([(0.34, 0.30), (0.66, 0.30)], ink) // pelvis
            disc(0.50, 0.20, radius: 0.055, ink)
            if correct {
                stroke([(0.34, 0.30), (0.28, 0.60), (0.26, 0.92)], accent)
                stroke([(0.66, 0.30), (0.72, 0.60), (0.74, 0.92)], accent)
                arrow(from: (0.36, 0.60), to: (0.24, 0.60), accent)
                arrow(from: (0.64, 0.60), to: (0.76, 0.60), accent)
            } else {
                stroke([(0.34, 0.30), (0.46, 0.60), (0.30, 0.92)], accent)
                stroke([(0.66, 0.30), (0.54, 0.60), (0.70, 0.92)], accent)
                arrow(from: (0.34, 0.60), to: (0.44, 0.60), accent)
                arrow(from: (0.66, 0.60), to: (0.56, 0.60), accent)
            }
        case .stanceWidth:
            floor()
            disc(0.50, 0.16, radius: 0.055, ink)
            stroke([(0.36, 0.28), (0.64, 0.28)], ink) // shoulders
            stroke([(0.50, 0.28), (0.50, 0.52)], ink) // trunk
            // Shoulder-width guides down to the floor.
            stroke([(0.36, 0.28), (0.36, 0.92)], ink.opacity(0.4), width: 1, dash: [3, 3])
            stroke([(0.64, 0.28), (0.64, 0.92)], ink.opacity(0.4), width: 1, dash: [3, 3])
            if correct {
                stroke([(0.50, 0.52), (0.38, 0.72), (0.36, 0.92)], accent)
                stroke([(0.50, 0.52), (0.62, 0.72), (0.64, 0.92)], accent)
            } else {
                stroke([(0.50, 0.52), (0.46, 0.72), (0.46, 0.92)], accent)
                stroke([(0.50, 0.52), (0.54, 0.72), (0.54, 0.92)], accent)
            }
        case .squatLockout:
            floor()
            if correct {
                sideFigure(
                    head: (0.50, 0.12), shoulder: (0.50, 0.22), hip: (0.49, 0.52),
                    knee: (0.50, 0.72), ankle: (0.50, 0.92), torso: nil, legs: accent
                )
            } else {
                sideFigure(
                    head: (0.52, 0.20), shoulder: (0.51, 0.30), hip: (0.44, 0.56),
                    knee: (0.55, 0.72), ankle: (0.50, 0.92), torso: nil, legs: accent
                )
            }
        case .elbowsDown:
            floor()
            // Standing under the bar, seen from the side; the arm carries
            // the fault: elbow swung up behind vs pointing at the floor.
            sideFigure(
                head: (0.52, 0.16), shoulder: (0.50, 0.28), hip: (0.47, 0.56),
                knee: (0.52, 0.74), ankle: (0.49, 0.92)
            )
            if correct {
                stroke([(0.50, 0.30), (0.38, 0.44)], accent) // upper arm down-back
                stroke([(0.38, 0.44), (0.42, 0.30)], accent.opacity(0.7)) // forearm up to the bar
                arrow(from: (0.30, 0.34), to: (0.30, 0.52), accent)
            } else {
                stroke([(0.50, 0.30), (0.30, 0.26)], accent) // upper arm swung high
                stroke([(0.30, 0.26), (0.36, 0.16)], accent.opacity(0.7))
                arrow(from: (0.24, 0.42), to: (0.24, 0.22), accent)
            }
        case .barOverMidfoot:
            floor()
            if correct {
                sideFigure(
                    head: (0.53, 0.26), shoulder: (0.50, 0.36), hip: (0.36, 0.68),
                    knee: (0.58, 0.60), ankle: (0.50, 0.92)
                )
                // The bar's plumb line lands on the midfoot.
                stroke([(0.50, 0.40), (0.50, 0.90)], accent, width: 1, dash: [3, 3])
                disc(0.50, 0.90, radius: 0.02, accent)
            } else {
                sideFigure(
                    head: (0.66, 0.34), shoulder: (0.61, 0.42), hip: (0.36, 0.68),
                    knee: (0.58, 0.60), ankle: (0.48, 0.92)
                )
                // Plumb line falls ahead of the toes.
                stroke([(0.61, 0.46), (0.61, 0.90)], accent, width: 1, dash: [3, 3])
                disc(0.61, 0.90, radius: 0.02, accent)
                arrow(from: (0.52, 0.86), to: (0.64, 0.86), accent)
            }
        case .controlDescent:
            floor()
            sideFigure(
                head: (0.62, 0.22), shoulder: (0.59, 0.32), hip: (0.48, 0.58),
                knee: (0.66, 0.56), ankle: (0.58, 0.92)
            )
            if correct {
                arrow(from: (0.30, 0.30), to: (0.30, 0.66), accent)
                label("1–2 s", 0.30, 0.20, accent)
            } else {
                // Free-fall: doubled rushed arrows.
                arrow(from: (0.26, 0.28), to: (0.26, 0.66), accent)
                arrow(from: (0.34, 0.28), to: (0.34, 0.66), accent)
                label("drop", 0.30, 0.18, accent)
            }
        case .benchTouch:
            floor()
            benchFigure()
            if correct {
                stroke([(0.38, 0.62), (0.46, 0.50), (0.40, 0.44)], ink) // arm folded, bar at chest
                disc(0.40, 0.41, radius: 0.035, accent)
                stroke([(0.40, 0.34), (0.40, 0.20)], accent, width: 1, dash: [3, 3])
            } else {
                stroke([(0.38, 0.62), (0.47, 0.44), (0.40, 0.30)], ink)
                disc(0.40, 0.27, radius: 0.035, accent)
                // The gap the bar never closes.
                stroke([(0.40, 0.33), (0.40, 0.56)], accent, width: 1, dash: [3, 3])
            }
        case .elbowFlare:
            // Top-down view: head at the left, shoulders vertical, the bar line.
            disc(0.16, 0.50, radius: 0.05, ink)
            stroke([(0.28, 0.24), (0.28, 0.76)], ink) // shoulder line
            stroke([(0.28, 0.32), (0.62, 0.36)], ink.opacity(0.4), width: 4) // torso hint
            stroke([(0.28, 0.68), (0.62, 0.64)], ink.opacity(0.4), width: 4)
            if correct {
                stroke([(0.28, 0.28), (0.46, 0.14)], accent) // upper arms swept ~60°
                stroke([(0.28, 0.72), (0.46, 0.86)], accent)
                stroke([(0.46, 0.14), (0.56, 0.18)], ink) // forearms to the bar
                stroke([(0.46, 0.86), (0.56, 0.82)], ink)
                stroke([(0.56, 0.10), (0.56, 0.90)], .secondary, width: 3)
                label("45–70°", 0.44, 0.50, accent)
            } else {
                stroke([(0.28, 0.28), (0.28, 0.08)], accent) // arms straight out: a T
                stroke([(0.28, 0.72), (0.28, 0.92)], accent)
                stroke([(0.28, 0.08), (0.40, 0.08)], ink)
                stroke([(0.28, 0.92), (0.40, 0.92)], ink)
                stroke([(0.40, 0.04), (0.40, 0.96)], .secondary, width: 3)
                label("90°", 0.36, 0.50, accent)
            }
        case .forearmVertical:
            // Seen from the foot of the bench: shoulders, elbows, bar overhead.
            floor()
            stroke([(0.30, 0.70), (0.70, 0.70)], ink) // shoulder line on the pad
            disc(0.50, 0.76, radius: 0.05, ink)
            if correct {
                stroke([(0.34, 0.70), (0.26, 0.52)], ink)
                stroke([(0.66, 0.70), (0.74, 0.52)], ink)
                stroke([(0.26, 0.52), (0.26, 0.24)], accent) // vertical forearms
                stroke([(0.74, 0.52), (0.74, 0.24)], accent)
                stroke([(0.14, 0.22), (0.86, 0.22)], .secondary, width: 3)
            } else {
                stroke([(0.34, 0.70), (0.22, 0.52)], ink)
                stroke([(0.66, 0.70), (0.78, 0.52)], ink)
                stroke([(0.22, 0.52), (0.36, 0.26)], accent) // tipped-in forearms
                stroke([(0.78, 0.52), (0.64, 0.26)], accent)
                stroke([(0.24, 0.24), (0.76, 0.24)], .secondary, width: 3)
            }
        case .barPath:
            floor()
            benchFigure()
            disc(0.28, 0.56, radius: 0.02, ink) // shoulder joint
            stroke([(0.28, 0.16), (0.28, 0.56)], ink.opacity(0.4), width: 1, dash: [3, 3])
            if correct {
                // J-curve: touch low on the chest, lock out over the shoulder.
                var curve = Path()
                curve.move(to: point(0.42, 0.52))
                curve.addQuadCurve(to: point(0.28, 0.20), control: point(0.44, 0.24))
                context.stroke(curve, with: .color(accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                arrow(from: (0.30, 0.24), to: (0.28, 0.20), accent)
                disc(0.42, 0.52, radius: 0.03, ink)
            } else {
                arrow(from: (0.42, 0.52), to: (0.42, 0.20), accent) // pressed straight up
                disc(0.42, 0.52, radius: 0.03, ink)
            }
        case .benchLockout:
            floor()
            benchFigure()
            if correct {
                stroke([(0.36, 0.62), (0.36, 0.24)], accent) // arms straight
                disc(0.36, 0.21, radius: 0.035, .secondary)
            } else {
                stroke([(0.36, 0.62), (0.46, 0.44), (0.40, 0.30)], accent) // elbow still bent
                disc(0.40, 0.27, radius: 0.035, .secondary)
            }
        case .neutralSpine:
            floor()
            // Hinged over the bar, seen from the side; the back line carries
            // the fault: rounded arc vs one straight line hips-to-head.
            stroke([(0.42, 0.66), (0.55, 0.60), (0.52, 0.92)], ink) // thigh + shin
            stroke([(0.55, 0.92), (0.64, 0.92)], ink)
            disc(0.30, 0.62, radius: 0.035, .secondary) // the bar
            stroke([(0.33, 0.62), (0.36, 0.42)], ink.opacity(0.7)) // arm to the hips' line
            if correct {
                stroke([(0.42, 0.66), (0.24, 0.34)], accent) // flat back
                disc(0.21, 0.28, radius: 0.05, accent)
            } else {
                var arc = Path()
                arc.move(to: point(0.42, 0.66))
                arc.addQuadCurve(to: point(0.24, 0.36), control: point(0.24, 0.62))
                context.stroke(arc, with: .color(accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                disc(0.24, 0.30, radius: 0.05, accent)
                arrow(from: (0.14, 0.52), to: (0.22, 0.46), accent)
            }
        case .barClose:
            floor()
            // Mid-pull from the side: shins vertical, the bar either grazing
            // the legs or swung out front.
            stroke([(0.50, 0.50), (0.58, 0.62), (0.56, 0.92)], ink) // torso hint→knee→ankle
            stroke([(0.46, 0.36), (0.50, 0.50)], ink)
            disc(0.44, 0.28, radius: 0.05, ink)
            if correct {
                disc(0.56, 0.68, radius: 0.04, accent) // bar against the leg
                stroke([(0.48, 0.42), (0.56, 0.64)], ink.opacity(0.7)) // arm
                stroke([(0.60, 0.30), (0.60, 0.90)], accent, width: 1, dash: [3, 3])
            } else {
                disc(0.74, 0.68, radius: 0.04, accent) // bar out front
                stroke([(0.48, 0.42), (0.74, 0.64)], ink.opacity(0.7))
                arrow(from: (0.62, 0.80), to: (0.74, 0.80), accent)
                stroke([(0.58, 0.30), (0.58, 0.90)], ink.opacity(0.4), width: 1, dash: [3, 3])
            }
        case .hipsRiseEarly:
            floor()
            // First inches of the pull: hips and shoulders keep their angle
            // together vs the hips popping up while the bar stays low.
            disc(0.34, 0.60, radius: 0.035, .secondary) // bar still low
            stroke([(0.38, 0.60), (0.42, 0.46)], ink.opacity(0.7)) // arm
            if correct {
                stroke([(0.42, 0.46), (0.58, 0.56)], accent) // back line intact
                stroke([(0.58, 0.56), (0.66, 0.68), (0.62, 0.92)], ink)
                disc(0.39, 0.40, radius: 0.05, accent)
                arrow(from: (0.50, 0.36), to: (0.50, 0.24), accent)
                arrow(from: (0.66, 0.48), to: (0.66, 0.36), accent)
            } else {
                stroke([(0.42, 0.46), (0.60, 0.40)], accent) // hips high, back flat-horizontal
                stroke([(0.60, 0.40), (0.66, 0.64), (0.62, 0.92)], ink)
                disc(0.39, 0.40, radius: 0.05, accent)
                arrow(from: (0.64, 0.34), to: (0.64, 0.22), accent) // hips up
                stroke([(0.44, 0.28), (0.52, 0.28)], accent, width: 1.5) // shoulders stuck
            }
        case .framing:
            floor()
            // Lifter at the right, phone at the left; the cone is the view.
            disc(0.76, 0.24, radius: 0.05, ink)
            stroke([(0.76, 0.30), (0.76, 0.62)], ink)
            stroke([(0.76, 0.62), (0.70, 0.92)], ink)
            stroke([(0.76, 0.62), (0.82, 0.92)], ink)
            stroke([(0.76, 0.38), (0.66, 0.52)], ink)
            stroke([(0.76, 0.38), (0.86, 0.52)], ink)
            if correct {
                context.fill(
                    path([(0.10, 0.44), (0.92, 0.10), (0.92, 0.92), (0.10, 0.56)]),
                    with: .color(accent.opacity(0.10))
                )
                stroke([(0.10, 0.44), (0.92, 0.10)], accent, width: 1, dash: [3, 3])
                stroke([(0.10, 0.56), (0.92, 0.92)], accent, width: 1, dash: [3, 3])
                stroke([(0.08, 0.40), (0.08, 0.60)], ink, width: 4) // the phone, stood back
                label("~3 m", 0.38, 0.80, .secondary)
            } else {
                context.fill(
                    path([(0.30, 0.48), (0.92, 0.34), (0.92, 0.92), (0.30, 0.60)]),
                    with: .color(accent.opacity(0.10))
                )
                stroke([(0.30, 0.48), (0.92, 0.34)], accent, width: 1, dash: [3, 3])
                stroke([(0.30, 0.60), (0.92, 0.92)], accent, width: 1, dash: [3, 3])
                stroke([(0.28, 0.44), (0.28, 0.64)], ink, width: 4) // phone too close
                // The head the frame cuts off.
                stroke([(0.68, 0.30), (0.86, 0.30)], accent, width: 1.5)
            }
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 14) {
            ForEach(FormHintTopic.allCases, id: \.rawValue) { topic in
                VStack(alignment: .leading, spacing: 4) {
                    Text(topic.rawValue).font(.caption.bold())
                    FormHintView(topic: topic)
                }
            }
        }
        .padding()
    }
}
