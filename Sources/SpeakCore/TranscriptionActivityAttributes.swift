import Foundation

#if os(iOS)
import ActivityKit
import os.log
#endif

/// ActivityKit attributes for live transcription sessions.
/// Defines the static and dynamic content shown in Live Activities and Dynamic Island.
public struct TranscriptionActivityAttributes {

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
        /// Only describes confirmed completion effects; older payloads remain neutral.
        public var completionOutcome: TranscriptionCompletionOutcome
        /// First line of the completed transcript, empty unless it was published
        /// to the App Group and is therefore retrievable by the result actions.
        public var resultPreview: String
        /// Identifies the completion whose transcript this row is offering.
        ///
        /// A Live Activity is reused across sessions and a finished row stays on
        /// screen for `TranscriptionActivityManager.resultRowDuration`, so "the
        /// last completed transcript" is not the same thing as "the transcript
        /// this row was rendered from". The row's Copy action carries this id and
        /// the App Group stores it beside the published text, so a row can only
        /// ever copy its own completion. Empty when nothing retrievable was
        /// published, and absent from payloads written before this existed.
        public var resultCompletionID: String

        public init(
            status: TranscriptionStatus = .idle,
            lastSnippet: String = "",
            wordCount: Int = 0,
            duration: Int = 0,
            provider: String = "Apple Speech",
            errorMessage: String? = nil,
            completionOutcome: TranscriptionCompletionOutcome = .ready,
            resultPreview: String = "",
            resultCompletionID: String = ""
        ) {
            self.status = status
            self.lastSnippet = lastSnippet
            self.wordCount = wordCount
            self.duration = duration
            self.provider = provider
            self.errorMessage = errorMessage
            self.completionOutcome = completionOutcome
            self.resultPreview = resultPreview
            self.resultCompletionID = resultCompletionID
        }

        private enum CodingKeys: String, CodingKey { // swiftlint:disable:this nesting
            case status, lastSnippet, wordCount, duration, provider, errorMessage
            case completionOutcome, resultPreview, resultCompletionID
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.status = try container.decode(TranscriptionStatus.self, forKey: .status)
            self.lastSnippet = try container.decode(String.self, forKey: .lastSnippet)
            self.wordCount = try container.decode(Int.self, forKey: .wordCount)
            self.duration = try container.decode(Int.self, forKey: .duration)
            self.provider = try container.decode(String.self, forKey: .provider)
            self.errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
            self.completionOutcome = try container.decodeIfPresent(
                TranscriptionCompletionOutcome.self, forKey: .completionOutcome
            ) ?? .ready
            self.resultPreview = try container.decodeIfPresent(String.self, forKey: .resultPreview) ?? ""
            self.resultCompletionID = try container.decodeIfPresent(
                String.self, forKey: .resultCompletionID
            ) ?? ""
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

#if os(iOS)
extension TranscriptionActivityAttributes: ActivityAttributes {}

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

    /// How long a finished capture stays on screen as a result row before it is
    /// dismissed (or, when primed, reverts to the idle Action Button label).
    /// The activity itself stays reusable throughout, so a primed headless start
    /// is unaffected.
    public static let resultRowDuration: TimeInterval = 180

    /// The deferred reset that returns a primed activity to its idle label once
    /// the result row's window is over, held so it can be cancelled.
    /// Internal rather than private so the result-row lifecycle can live in
    /// `TranscriptionActivityManager+ResultRow.swift`.
    var resultRowResetTask: Task<Void, Never>?
    /// Identifies the completion the current result row belongs to. A new
    /// recording, or a later completion, replaces it — which is what tells the
    /// deferred reset that the activity has moved on without it.
    var resultRowToken: UUID?

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

        // A primed activity is reused, so a recording started inside the previous
        // completion's result-row window inherits that window's pending reset.
        // Retire it here: this activity now belongs to a live session, and the
        // older completion must not be able to write idle over it.
        self.retireResultRow()

        // Reuse a primed activity when possible. ActivityKit will not allow a
        // background AppIntent to request a brand-new Live Activity, but it can
        // update one that was created while the app was foregrounded. Keeping
        // that activity idle between Action Button recordings avoids asking the
        // user to "continue in the app" on every single start.
        if let activity = currentActivity ?? Activity<TranscriptionActivityAttributes>.activities.first {
            currentActivity = activity
            isActivityRunning = true
            let state = TranscriptionActivityAttributes.ContentState(
                status: initialStatus,
                provider: provider
            )
            Task {
                await activity.update(.init(state: state, staleDate: nil))
            }
            return true
        }

        let attributes = TranscriptionActivityAttributes()
        let initialState = TranscriptionActivityAttributes.ContentState(
            status: initialStatus,
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
            SpeakLogger.activity.info("Started activity: \(activity.id, privacy: .public)")
            return true
        } catch {
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
    public func completeActivity(
        finalWordCount: Int,
        duration: Int,
        keepPrimed: Bool = false,
        primedMessage: String = "Ready for the Action Button",
        primedStatus: TranscriptionActivityAttributes.TranscriptionStatus = .idle
    ) {
        completeActivity(
            finalWordCount: finalWordCount,
            duration: duration,
            keepPrimed: keepPrimed,
            primedMessage: primedMessage,
            primedStatus: primedStatus,
            completionOutcome: .ready,
            resultPreview: "",
            resultCompletionID: ""
        )
    }

    /// Explicit outcome variant; the original entry point remains neutral and source-compatible.
    public func completeActivity(
        finalWordCount: Int,
        duration: Int,
        keepPrimed: Bool = false,
        primedMessage: String = "Ready for the Action Button",
        primedStatus: TranscriptionActivityAttributes.TranscriptionStatus = .idle,
        completionOutcome: TranscriptionCompletionOutcome,
        resultPreview: String = "",
        resultCompletionID: String = ""
    ) {
        guard let activity = currentActivity else { return }

        let finalState = TranscriptionActivityAttributes.ContentState(
            status: .completed,
            lastSnippet: completionOutcome.message,
            wordCount: finalWordCount,
            duration: duration,
            provider: activity.content.state.provider,
            completionOutcome: completionOutcome,
            resultPreview: resultPreview,
            resultCompletionID: resultCompletionID
        )

        // This completion owns the result row from here. Any earlier row's
        // pending reset is retired, and this token is what the reset scheduled
        // below checks before it writes anything.
        self.retireResultRow()
        let token = UUID()
        self.resultRowToken = token

        if keepPrimed {
            Task { await activity.update(.init(state: finalState, staleDate: nil)) }
            // Created here rather than after the update so there is no window in
            // which a newer session cannot cancel it.
            self.resultRowResetTask = Task {
                try? await Task.sleep(for: .seconds(Self.resultRowDuration))
                // The activity is reused, so by now it may be showing a newer
                // recording or a newer completion. Only the completion that
                // scheduled this reset may apply it: an expired row must never
                // write idle over a session that is still running.
                guard !Task.isCancelled,
                      self.resultRowToken == token,
                      activity.activityState == .active else { return }
                let idleState = TranscriptionActivityAttributes.ContentState(
                    status: primedStatus,
                    lastSnippet: primedMessage,
                    provider: finalState.provider
                )
                await activity.update(.init(state: idleState, staleDate: nil))
                self.resultRowToken = nil
            }
        } else {
            Task {
                await activity.end(
                    .init(state: finalState, staleDate: nil),
                    dismissalPolicy: .after(.now + Self.resultRowDuration)
                )
                currentActivity = nil
                isActivityRunning = false
            }
        }
    }

    /// Ends the current activity immediately.
    public func endActivity() {
        self.retireResultRow()
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
