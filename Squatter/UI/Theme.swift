import SwiftUI
import UIKit

/// Kodo palette (Mazda "Soul of Motion"): Soul Red Crystal accent reserved
/// for the headline quality metric, machine-gray neutrals, and a sculpted
/// card surface — machine gray in dark mode, rhodium silver in light.
enum Kodo {
    static let soulRed = Color(red: 0.63, green: 0.09, blue: 0.16)
    static let soulRedBright = Color(red: 0.85, green: 0.17, blue: 0.24)
    static let titanium = dynamic(
        light: UIColor(white: 0.44, alpha: 1), dark: UIColor(white: 0.74, alpha: 1)
    )
    static let cardTop = dynamic(
        light: UIColor(red: 0.965, green: 0.965, blue: 0.975, alpha: 1),
        dark: UIColor(red: 0.165, green: 0.17, blue: 0.18, alpha: 1)
    )
    static let cardBottom = dynamic(
        light: UIColor(red: 0.885, green: 0.89, blue: 0.905, alpha: 1),
        dark: UIColor(red: 0.09, green: 0.095, blue: 0.105, alpha: 1)
    )
    static let cardEdge = dynamic(
        light: UIColor(white: 1, alpha: 0.65), dark: UIColor(white: 1, alpha: 0.07)
    )
    static let hairline = dynamic(
        light: UIColor(white: 0, alpha: 0.08), dark: UIColor(white: 1, alpha: 0.08)
    )
    static let inkPrimary = dynamic(
        light: UIColor(white: 0.08, alpha: 0.9), dark: UIColor(white: 1, alpha: 0.92)
    )
    static let inkSecondary = dynamic(
        light: UIColor(white: 0.25, alpha: 0.55), dark: UIColor(white: 1, alpha: 0.55)
    )

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    /// Traffic-light grading shared by the score ring and chart marks.
    static func grade(for score: Int) -> Color {
        switch score {
        case 85...: .green
        case 60 ..< 85: .orange
        default: .red
        }
    }
}

/// App mark: a squat-motion curve — descent, bottom, drive back up — swept
/// in Soul Red across a sculpted dark badge. Drawn, not an asset, so it
/// scales and adapts for free.
struct KodoEmblem: View {
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Kodo.cardTop, Kodo.cardBottom],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            motionCurve
                .stroke(
                    LinearGradient(
                        colors: [Kodo.soulRed, Kodo.soulRedBright],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round)
                )
            Circle()
                .fill(Kodo.soulRedBright)
                .frame(width: size * 0.11, height: size * 0.11)
                .offset(x: size * 0.31, y: size * -0.17)
        }
        .frame(width: size, height: size)
        // The badge is dark in both schemes — the mark keeps its identity.
        .environment(\.colorScheme, .dark)
        .accessibilityLabel("Squatter")
    }

    /// Descent → deep bottom → powerful ascent, in unit space.
    private var motionCurve: Path {
        Path { path in
            path.move(to: CGPoint(x: size * 0.20, y: size * 0.36))
            path.addCurve(
                to: CGPoint(x: size * 0.52, y: size * 0.72),
                control1: CGPoint(x: size * 0.28, y: size * 0.40),
                control2: CGPoint(x: size * 0.36, y: size * 0.70)
            )
            path.addCurve(
                to: CGPoint(x: size * 0.81, y: size * 0.33),
                control1: CGPoint(x: size * 0.68, y: size * 0.74),
                control2: CGPoint(x: size * 0.76, y: size * 0.52)
            )
        }
    }
}

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

    private var color: Color { Kodo.grade(for: score) }
}

/// Kodo primary action: a Soul Red capsule with a machined edge highlight
/// and a soft red bloom, compressing slightly under the finger.
struct KodoProminentButtonStyle: ButtonStyle {
    /// Stretch the capsule to the available width (list/detail actions).
    var fullWidth = false
    /// Smaller type and tighter padding for secondary contexts.
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(compact ? .body : .title3, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, 26)
            .padding(.vertical, compact ? 10 : 13)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Kodo.soulRedBright, Kodo.soulRed],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            )
            .shadow(
                color: Kodo.soulRed.opacity(configuration.isPressed ? 0.15 : 0.35),
                radius: 14, y: 6
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

