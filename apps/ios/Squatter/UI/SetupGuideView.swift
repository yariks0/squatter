import SwiftUI

struct SetupGuideView: View {
    var activity: ActivityType = .squat
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: activity.systemImage)
                    .font(.system(size: 56))
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.tint)

                switch activity {
                case .squat: squatSteps
                case .benchPress: benchSteps
                case .deadlift: deadliftSteps
                }

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

    @ViewBuilder
    private var squatSteps: some View {
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
            icon: "waveform",
            title: "The phone talks you in",
            text: "Tap start and walk to the bar — the phone speaks placement guidance, counts down by itself once framing holds green, then counts your reps out loud (and calls “high” on shallow ones). Mute it with the speaker button."
        )
        step(
            icon: "stop.circle",
            title: "Finish when you rack",
            text: "Tap finish at the phone when you're done; extra seconds don't hurt the analysis."
        )
        step(
            icon: "lightbulb.max",
            title: "Good light helps",
            text: "Even lighting and contrast between you and the background improve tracking. Avoid strong backlight."
        )
    }

    @ViewBuilder
    private var benchSteps: some View {
        step(
            icon: "iphone.gen3",
            title: "Prop up your phone",
            text: "About 3 meters away at bench height, propped steady in portrait. That distance keeps you, the bench, and the bar in frame and stays within LiDAR range."
        )
        step(
            icon: "angle",
            title: "45° from the foot of the bench",
            text: "Halfway between side-on and foot-on, level with the bench. This one angle shows bar path, touch point, and elbow tuck — a pure side view hides one arm behind the other."
        )
        step(
            icon: "person.crop.rectangle",
            title: "Whole body and bar in frame",
            text: "Head to feet visible for the entire set, including the bar at lockout. The indicator on the next screen turns green when framing is right."
        )
        step(
            icon: "waveform",
            title: "The phone talks you in",
            text: "Tap start and lie back — the phone speaks placement guidance, counts down by itself once framing holds green, then counts your reps out loud. If it can't see you on the bench, tap “Record now” or wait; it starts anyway after a while."
        )
        step(
            icon: "stop.circle",
            title: "Finish when you rack",
            text: "Tap finish at the phone when you're done; extra seconds don't hurt the analysis."
        )
        step(
            icon: "lightbulb.max",
            title: "Good light helps",
            text: "Even lighting and contrast between you and the background improve tracking. Avoid strong backlight, and make sure the plates don't hide your arms from the camera."
        )
    }

    @ViewBuilder
    private var deadliftSteps: some View {
        step(
            icon: "iphone.gen3",
            title: "Prop up your phone",
            text: "About 3 meters away, roughly knee height, propped steady in portrait. That distance keeps you and the plates in frame and stays within LiDAR range."
        )
        step(
            icon: "angle",
            title: "Stand at a 45° angle",
            text: "Face halfway between head-on and side-on. This one angle shows the back line, the bar path, and hip–shoulder timing — straight-on hides the hinge entirely."
        )
        step(
            icon: "person.crop.rectangle",
            title: "Whole body and bar in frame",
            text: "Head to feet visible for the entire set, plates on the floor included. The indicator on the next screen turns green when framing is right."
        )
        step(
            icon: "waveform",
            title: "The phone talks you in",
            text: "Tap start and walk to the bar — the phone speaks placement guidance, counts down by itself once framing holds green, then counts your pulls out loud. Mute it with the speaker button."
        )
        step(
            icon: "lightbulb.max",
            title: "Good light helps",
            text: "Even lighting and contrast between you and the background improve tracking. Avoid strong backlight, and keep chalk dust off the lens."
        )
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
