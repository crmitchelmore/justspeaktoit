#if os(iOS)
import ActivityKit
import Foundation
import os.log

/// ActivityKit attributes for live transcription sessions.
/// Defines the static and dynamic content shown in Live Activities and Dynamic Island.
public struct TranscriptionActivityAttributes: ActivityAttributes {

    /// Static content that doesn't change during the activity.
    public struct ContentState: Codable, Hashable {
        /// Current transcription status
        public var status: TranscriptionStatus
        /// Most recent text snippet (last ~100 chars for compact display)
        public var lastSnippet: String
        /// Number of words transcribed so far
        public var wordCount: Int
        /// Duration in seconds
        public var duration: Int
        /// Provider being used
        public var provider: String
        /// Optional error message
        public var errorMessage: String?

        public init(
            status: TranscriptionStatus = .idle,
            lastSnippet: String = "",
            wordCount: Int = 0,
            duration: Int = 0,
            provider: String = "Apple Speech",
            errorMessage: String? = nil
        ) {
            self.status = status
            self.lastSnippet = lastSnippet
            self.wordCount = wordCount
            self.duration = duration
            self.provider = provider
            self.errorMessage = errorMessage
        }
    }

    /// Transcription session status
    public enum TranscriptionStatus: String, Codable, Hashable {
        case idle
        case arming
        case armed
        case recording
        case finalising
        case listening
        case processing
        case paused
        case error
        case completed
    }

    /// Session identifier
    public var sessionId: String
    /// Start time of the session
    public var startTime: Date

    public init(sessionId: String = UUID().uuidString, startTime: Date = Date()) {
        self.sessionId = sessionId
        self.startTime = startTime
    }
}

// MARK: - Activity Manager

/// Manages Live Activity lifecycle for transcription sessions.
@MainActor
public final class TranscriptionActivityManager: ObservableObject {
    public static let shared = TranscriptionActivityManager()

    @Published public private(set) var currentActivity: Activity<TranscriptionActivityAttributes>?
    @Published public private(set) var isActivityRunning = false

    private var updateThrottleTask: Task<Void, Never>?
    private var lastUpdateTime: Date = .distantPast
    private let minimumUpdateInterval: TimeInterval = 1.0 // Throttle to 1 update per second

    /// Ordering and run ownership for every content publication (issue #983).
    /// A reused activity outlives the run that primed it, so without this an
    /// older `.arming` write — or a previous run's snippet — can complete after
    /// the capture-proof state and leave proven capture displayed as
    /// preparation.
    private var order = ActivityPublicationOrder()
    /// Publications are applied in submission order by chaining them: ActivityKit
    /// gives no ordering guarantee across concurrent `update` calls.
    private var publishChain: Task<Void, Never>?
    /// The most recently *submitted* state. `activity.content.state` lags behind
    /// anything still queued, so derived fields (provider, error) read this.
    private var latestState: TranscriptionActivityAttributes.ContentState?

    private init() {}

    /// Starts a new Live Activity for transcription. Returns whether one is now
    /// active — callers that require a Live Activity (e.g. `AudioRecordingIntent`
    /// background recording) must not proceed when this returns `false`, or the
    /// system-policy check will assert (EXC_BREAKPOINT).
    @discardableResult
    public func startActivity(
        provider: String,
        initialStatus: TranscriptionActivityAttributes.TranscriptionStatus = .recording
    ) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            SpeakLogger.activity.info("Live Activities not enabled")
            return false
        }

        // Retire the previous run before anything is published for this one, so
        // a deferred update belonging to the predecessor cannot land here.
        updateThrottleTask?.cancel()
        updateThrottleTask = nil
        lastUpdateTime = .distantPast
        order.beginRun()

        let initialState = TranscriptionActivityAttributes.ContentState(
            status: initialStatus,
            provider: provider
        )

        // Reuse a primed activity when possible. ActivityKit will not allow a
        // background AppIntent to request a brand-new Live Activity, but it can
        // update one that was created while the app was foregrounded. Keeping
        // that activity idle between Action Button recordings avoids asking the
        // user to "continue in the app" on every single start.
        if let activity = currentActivity ?? Activity<TranscriptionActivityAttributes>.activities.first {
            currentActivity = activity
            isActivityRunning = true
            publish(initialState, to: activity)
            return true
        }

        let attributes = TranscriptionActivityAttributes()

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            currentActivity = activity
            isActivityRunning = true
            latestState = initialState
            SpeakLogger.activity.info("Started activity: \(activity.id, privacy: .public)")
            return true
        } catch {
            order.retire()
            SpeakLogger.activity.error(
                "Failed to start activity: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Updates the Live Activity with new transcription state.
    public func updateActivity(
        status: TranscriptionActivityAttributes.TranscriptionStatus,
        lastSnippet: String,
        wordCount: Int,
        duration: Int
    ) {
        guard let activity = currentActivity else { return }

        // Throttle updates
        let now = Date()
        guard now.timeIntervalSince(lastUpdateTime) >= minimumUpdateInterval else {
            // Schedule a deferred update
            scheduleThrottledUpdate(status: status, lastSnippet: lastSnippet, wordCount: wordCount, duration: duration)
            return
        }

        lastUpdateTime = now
        updateThrottleTask?.cancel()
        updateThrottleTask = nil

        let state = TranscriptionActivityAttributes.ContentState(
            status: status,
            lastSnippet: String(lastSnippet.suffix(100)),
            wordCount: wordCount,
            duration: duration,
            provider: latestState?.provider ?? activity.content.state.provider
        )

        publish(state, to: activity)
    }

    private func scheduleThrottledUpdate(
        status: TranscriptionActivityAttributes.TranscriptionStatus,
        lastSnippet: String,
        wordCount: Int,
        duration: Int
    ) {
        updateThrottleTask?.cancel()
        // The deferred write belongs to the run that requested it. A successor
        // run must never inherit it.
        let owner = order.currentRun
        updateThrottleTask = Task {
            try? await Task.sleep(for: .seconds(minimumUpdateInterval))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let owner, order.owns(owner) else { return }
                updateActivity(status: status, lastSnippet: lastSnippet, wordCount: wordCount, duration: duration)
            }
        }
    }

    /// Marks the activity as completed. Headless recordings keep it primed so
    /// the next Action Button invocation can start entirely in the background.
    public func completeActivity(
        finalWordCount: Int,
        duration: Int,
        keepPrimed: Bool = false,
        primedMessage: String = "Ready for the Action Button",
        primedStatus: TranscriptionActivityAttributes.TranscriptionStatus = .idle
    ) {
        guard let activity = currentActivity else { return }

        updateThrottleTask?.cancel()
        updateThrottleTask = nil

        let finalState = TranscriptionActivityAttributes.ContentState(
            status: .completed,
            lastSnippet: "Transcription complete",
            wordCount: finalWordCount,
            duration: duration,
            provider: latestState?.provider ?? activity.content.state.provider
        )

        if keepPrimed {
            let owner = order.currentRun
            publish(finalState, to: activity)
            // The idle continuation is submitted only after the delay, and only
            // while this run still owns the activity: a capture that starts
            // during the delay has already published its own preparation state
            // and must not be overwritten by the previous run's priming copy.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, activity.activityState == .active else { return }
                guard let owner, order.owns(owner) else { return }
                let idleState = TranscriptionActivityAttributes.ContentState(
                    status: primedStatus,
                    lastSnippet: primedMessage,
                    provider: finalState.provider
                )
                publish(idleState, to: activity)
            }
            return
        }

        // Ending supersedes every outstanding publication for this activity.
        order.retire()
        latestState = nil
        currentActivity = nil
        isActivityRunning = false
        enqueuePublication {
            await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .after(.now + 5))
        }
    }

    /// Ends the current activity immediately.
    public func endActivity() {
        updateThrottleTask?.cancel()
        updateThrottleTask = nil

        guard let activity = currentActivity else { return }

        // Clear state synchronously and end the captured activity, so a new
        // activity started right after (e.g. `startActivity` calls this first)
        // isn't orphaned when the async end completes and nils `currentActivity`.
        order.retire()
        latestState = nil
        currentActivity = nil
        isActivityRunning = false

        enqueuePublication {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Reports an error to the Live Activity.
    public func reportError(_ message: String) {
        guard let activity = currentActivity else { return }

        var state = latestState ?? activity.content.state
        state.status = .error
        state.errorMessage = message

        publish(state, to: activity)
    }

    /// Submits one content publication, ordered behind everything already
    /// queued and skipped if a newer publication supersedes it before it runs.
    private func publish(
        _ state: TranscriptionActivityAttributes.ContentState,
        to activity: Activity<TranscriptionActivityAttributes>
    ) {
        guard let ticket = order.submit() else { return }
        latestState = state
        enqueuePublication { [weak self] in
            guard let self, self.order.isCurrent(ticket) else { return }
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    /// Chains asynchronous activity work so it is applied in submission order.
    private func enqueuePublication(_ body: @escaping @MainActor () async -> Void) {
        let previous = publishChain
        publishChain = Task { @MainActor in
            await previous?.value
            await body()
        }
    }
}
#endif
