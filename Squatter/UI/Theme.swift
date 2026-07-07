import SwiftUI

/// Score ring used across the app: gradient arc, rounded numerals, color
/// graded by score.
struct ScoreRing: View {
    let score: Int
    var diameter: CGFloat = 76

    var body: some View {
        let lineWidth = diameter * 0.1
        ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(CGFloat(score) / 100, 0.02))
                .stroke(
                    AngularGradient(
                        colors: [color.opacity(0.45), color],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * Double(score) / 100)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(.system(size: diameter * 0.34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(width: diameter, height: diameter)
    }

    private var color: Color {
        switch score {
        case 85...: .green
        case 60 ..< 85: .orange
        default: .red
        }
    }
}

extension View {
    /// Primary action buttons float on Liquid Glass on iOS 26 (controls sit
    /// "on top" of content per the design language); bordered-prominent on
    /// earlier systems.
    @ViewBuilder
    func prominentActionStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}
