#if os(iOS)
import ActivityKit
import Foundation

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

    private init() {}

    /// Starts a new Live Activity for transcription. Returns whether one is now
    /// active — callers that require a Live Activity (e.g. `AudioRecordingIntent`
    /// background recording) must not proceed when this returns `false`, or the
    /// system-policy check will assert (EXC_BREAKPOINT).
    @discardableResult
    public func startActivity(provider: String) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[ActivityManager] Live Activities not enabled")
            return false
        }

        // Reuse a primed activity when possible. ActivityKit will not allow a
        // background AppIntent to request a brand-new Live Activity, but it can
        // update one that was created while the app was foregrounded. Keeping
        // that activity idle between Action Button recordings avoids asking the
        // user to "continue in the app" on every single start.
        if let activity = currentActivity ?? Activity<TranscriptionActivityAttributes>.activities.first {
            currentActivity = activity
            isActivityRunning = true
            let state = TranscriptionActivityAttributes.ContentState(
                status: .listening,
                provider: provider
            )
            Task {
                await activity.update(.init(state: state, staleDate: nil))
            }
            return true
        }

        let attributes = TranscriptionActivityAttributes()
        let initialState = TranscriptionActivityAttributes.ContentState(
            status: .listening,
            provider: provider
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            currentActivity = activity
            isActivityRunning = true
            print("[ActivityManager] Started activity: \(activity.id)")
            return true
        } catch {
            print("[ActivityManager] Failed to start activity: \(error)")
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

        let state = TranscriptionActivityAttributes.ContentState(
            status: status,
            lastSnippet: String(lastSnippet.suffix(100)),
            wordCount: wordCount,
            duration: duration,
            provider: activity.content.state.provider
        )

        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    private func scheduleThrottledUpdate(
        status: TranscriptionActivityAttributes.TranscriptionStatus,
        lastSnippet: String,
        wordCount: Int,
        duration: Int
    ) {
        updateThrottleTask?.cancel()
        updateThrottleTask = Task {
            try? await Task.sleep(for: .seconds(minimumUpdateInterval))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                updateActivity(status: status, lastSnippet: lastSnippet, wordCount: wordCount, duration: duration)
            }
        }
    }

    /// Marks the activity as completed. Headless recordings keep it primed so
    /// the next Action Button invocation can start entirely in the background.
    public func completeActivity(finalWordCount: Int, duration: Int, keepPrimed: Bool = false) {
        guard let activity = currentActivity else { return }

        let finalState = TranscriptionActivityAttributes.ContentState(
            status: .completed,
            lastSnippet: "Transcription complete",
            wordCount: finalWordCount,
            duration: duration,
            provider: activity.content.state.provider
        )

        Task {
            if keepPrimed {
                await activity.update(.init(state: finalState, staleDate: nil))
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, activity.activityState == .active else { return }
                let idleState = TranscriptionActivityAttributes.ContentState(
                    status: .idle,
                    lastSnippet: "Ready for the Action Button",
                    provider: finalState.provider
                )
                await activity.update(.init(state: idleState, staleDate: nil))
            } else {
                await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .after(.now + 5))
                await MainActor.run {
                    currentActivity = nil
                    isActivityRunning = false
                }
            }
        }
    }

    /// Ends the current activity immediately.
    public func endActivity() {
        updateThrottleTask?.cancel()

        guard let activity = currentActivity else { return }

        // Clear state synchronously and end the captured activity, so a new
        // activity started right after (e.g. `startActivity` calls this first)
        // isn't orphaned when the async end completes and nils `currentActivity`.
        currentActivity = nil
        isActivityRunning = false

        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Reports an error to the Live Activity.
    public func reportError(_ message: String) {
        guard let activity = currentActivity else { return }

        var state = activity.content.state
        state.status = .error
        state.errorMessage = message

        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }
}
#endif
