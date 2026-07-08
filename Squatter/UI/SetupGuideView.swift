import SwiftUI

struct SetupGuideView: View {
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "figure.strengthtraining.functional")
                    .font(.system(size: 56))
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.tint)

                step(
                    icon: "iphone.gen3",
                    title: "Prop up your phone",
                    text: "About 3 meters away, roughly knee-to-hip height, propped steady in portrait. That distance keeps your whole body in frame and stays within LiDAR range."
                )
                step(
                    icon: "angle",
                    title: "Stand at a 45° angle",
                    text: "Face halfway between head-on and side-on. This one angle shows both squat depth and knee tracking — straight-on hides depth, a pure side view hides knees caving."
                )
                step(
                    icon: "person.crop.rectangle",
                    title: "Whole body in frame",
                    text: "Head to feet visible for the entire set, including the deepest point. The indicator on the next screen turns green when framing is right."
                )
                step(
                    icon: "timer",
                    title: "5-second countdown",
                    text: "Start the countdown, get set, squat. Tap finish when you rack — or walk to the phone; extra seconds don't hurt the analysis."
                )
                step(
                    icon: "lightbulb.max",
                    title: "Good light helps",
                    text: "Even lighting and contrast between you and the background improve tracking. Avoid strong backlight."
                )

                Button(action: onContinue) {
                    Label("Open camera", systemImage: "arrow.right")
                }
                .buttonStyle(KodoProminentButtonStyle(fullWidth: true))
                .padding(.top, 8)
            }
            .padding()
        }
        .navigationTitle("Set up your shot")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
