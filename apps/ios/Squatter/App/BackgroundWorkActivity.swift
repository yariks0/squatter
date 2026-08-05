import BackgroundTasks
import UIKit

/// Keeps a long user-initiated job running when the user leaves the app or
/// locks the screen. Used by set analysis and by the AI coach call, which
/// blocks on the model for 90–120 s and would otherwise be suspended the
/// moment the screen locks. Two layers, held for the duration of one run:
///
/// - `UIApplication.beginBackgroundTask` — every OS version; buys the ~30 s
///   grace window so short analyses simply finish.
/// - `BGContinuedProcessingTask` (iOS 26+) — the user-initiated continued
///   processing API: the system shows a live progress pill and lets the
///   work run to completion in the background. Progress updates are
///   mandatory (stalled tasks are expired), so extraction progress is
///   forwarded here.
///
/// If neither protects us (old OS past the grace window, task expired), the
/// process is suspended mid-decode; `PoseExtractor`'s reader-resume path
/// then recovers on return via `waitForRetry` below, which parks until the
/// app is active instead of burning resume attempts while backgrounded.
@MainActor
final class BackgroundWorkActivity {
    private var uikitTask: UIBackgroundTaskIdentifier = .invalid
    /// `BGContinuedProcessingTask` on iOS 26+; typed as `AnyObject` so the
    /// stored property needs no availability gate.
    private var continuedTask: AnyObject?
    private var finished = false
    private var lastFraction = 0.0

    /// Continued-processing identifiers are one per submission: the plist
    /// permits the `com.yarik.squatter.analysis.*` wildcard and each run
    /// registers + submits a fresh suffix. Both callers share the one
    /// permitted family — the identifier is internal, and only `title` and
    /// `subtitle` reach the user — so adding a job needs no plist change.
    private static let identifierPrefix = "com.yarik.squatter.analysis."

    /// What the system's progress pill shows while the job runs.
    private let title: String
    private let subtitle: String

    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    func begin() {
        guard uikitTask == .invalid, !finished else { return }
        uikitTask = UIApplication.shared.beginBackgroundTask(withName: "squatter-work") {
            [weak self] in
            self?.endUIKitTask()
        }
        if #available(iOS 26.0, *) { submitContinuedTask() }
    }

    func report(_ fraction: Double) {
        lastFraction = fraction
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = Int64((fraction * 100).rounded())
        }
    }

    func end(success: Bool) {
        finished = true
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
            task.setTaskCompleted(success: success)
            continuedTask = nil
        }
        endUIKitTask()
    }

    /// `PoseExtractor`'s reader-stall hook: while the app is active a quick
    /// retry matches the old behavior; a stall in the background means the
    /// decoder is gone until the user returns, so park until then — the
    /// process is suspended for most of that wait anyway.
    static func waitForRetry() async {
        while !Task.isCancelled,
              await MainActor.run(body: { UIApplication.shared.applicationState == .background }) {
            try? await Task.sleep(for: .seconds(1))
        }
        try? await Task.sleep(for: .milliseconds(600))
    }

    private func endUIKitTask() {
        guard uikitTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(uikitTask)
        uikitTask = .invalid
    }

    @available(iOS 26.0, *)
    private func submitContinuedTask() {
        let identifier = Self.identifierPrefix + UUID().uuidString
        // Registration is exempt from the register-before-launch rule for
        // continued processing tasks; the handler fires once the scheduler
        // starts the (already running) work and hands us the task to feed
        // progress into.
        // `using: nil` runs this handler on the scheduler's own serial queue,
        // never the main actor. The closure is formed inside a @MainActor
        // method, so without an explicit @Sendable it inherits main-actor
        // isolation and Swift 6's isolation prologue trips
        // dispatch_assert_queue — SIGTRAP before the body runs, killing every
        // analysis on device (2026-08-03). Stay non-isolated, hop explicitly.
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: nil
        ) { @Sendable [weak self] task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            nonisolated(unsafe) let adopted = continued
            Task { @MainActor in self?.adopt(adopted) }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: title, subtitle: subtitle
        )
        // .fail over .queue: the work runs regardless — if the system has no
        // room now, a queued grant later would adopt a task for work that may
        // already be done.
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)
    }

    @available(iOS 26.0, *)
    private func adopt(_ task: BGContinuedProcessingTask) {
        guard !finished else {
            // The work won the race with the scheduler; close the task out.
            task.progress.totalUnitCount = 100
            task.progress.completedUnitCount = 100
            task.setTaskCompleted(success: true)
            return
        }
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = Int64((lastFraction * 100).rounded())
        // Same isolation trap as the launch handler above: the system fires
        // expiration off the main actor, so this closure must not inherit
        // `adopt`'s main-actor isolation.
        task.expirationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                guard let self, !self.finished,
                      let expired = self.continuedTask as? BGContinuedProcessingTask
                else { return }
                self.continuedTask = nil
                expired.setTaskCompleted(success: false)
                // The analysis itself keeps its state; the reader-stall
                // path resumes it when the app is foregrounded again.
            }
        }
        continuedTask = task
    }
}
