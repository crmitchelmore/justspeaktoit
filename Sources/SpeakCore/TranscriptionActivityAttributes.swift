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
    /// Ordering and run ownership for every content publication (issue #983).
    /// A reused activity outlives the run that primed it, so without this an
    /// older `.arming` write — or a previous run's snippet — can complete after
    /// the capture-proof state and leave proven capture displayed as
    /// preparation.
    var order = ActivityPublicationOrder()
    /// Publications are applied in submission order by chaining them: ActivityKit
    /// gives no ordering guarantee across concurrent `update` calls.
    var publishChain: Task<Void, Never>?
    /// The most recently *submitted* state. `activity.content.state` lags behind
    /// anything still queued, so derived fields (provider, error) read this.
    var latestState: TranscriptionActivityAttributes.ContentState?

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

        // Retire the previous run before anything is published for this one, so
        // a deferred update belonging to the predecessor cannot land here.
        updateThrottleTask?.cancel()
        updateThrottleTask = nil
        lastUpdateTime = .distantPast
        order.beginRun()
        // A primed activity is reused, so a recording started inside the previous
        // completion's result-row window inherits that window's pending reset.
        // Retire it here too: this activity now belongs to a live session, and
        // the older completion must not be able to write idle over it.
        self.retireResultRow()

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
    ///
    /// `completionMessage` is the capture receipt (issue #1008): what the
    /// transcript's delivery actually did, built from observed results. When
    /// none is supplied the row keeps its neutral "Transcription complete".
    public func completeActivity(
        finalWordCount: Int,
        duration: Int,
        keepPrimed: Bool = false,
        primedMessage: String = "Ready for the Action Button",
        primedStatus: TranscriptionActivityAttributes.TranscriptionStatus = .idle,
        completionMessage: String? = nil
    ) {
        completeActivity(
            finalWordCount: finalWordCount,
            duration: duration,
            keepPrimed: keepPrimed,
            primedMessage: primedMessage,
            primedStatus: primedStatus,
            completionOutcome: .ready,
            resultPreview: "",
            completionMessage: completionMessage,
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
        completionMessage: String? = nil,
        resultCompletionID: String = ""
    ) {
        guard let activity = currentActivity else { return }

        updateThrottleTask?.cancel()
        updateThrottleTask = nil

        let finalState = TranscriptionActivityAttributes.ContentState(
            status: .completed,
            // The receipt's headline when the caller has one (issue #1008),
            // else the resolved outcome's own message. The result row's
            // headline still comes from `completionOutcome`, so a richer
            // snippet can never turn into a delivery claim the lane did not
            // earn (issue #945).
            lastSnippet: completionMessage ?? completionOutcome.message,
            wordCount: finalWordCount,
            duration: duration,
            provider: latestState?.provider ?? activity.content.state.provider,
            completionOutcome: completionOutcome,
            resultPreview: resultPreview,
            resultCompletionID: resultCompletionID
        )

        // This completion owns the result row from here. Any earlier row's
        // pending reset is cancelled, and this token is what the reset
        // scheduled below checks before it writes anything.
        //
        // Two guards, not one, because they cover different failures: the run
        // `order` says whether this run still owns the activity at all, and the
        // token plus a *held, cancellable* task means an expired row's reset
        // can be retired outright rather than merely no-op when it wakes.
        self.retireResultRow()
        let token = UUID()
        self.resultRowToken = token

        if keepPrimed {
            let owner = order.currentRun
            publish(finalState, to: activity)
            // The idle continuation is submitted only after the delay, and only
            // while this run still owns the activity: a capture that starts
            // during the delay has already published its own preparation state
            // and must not be overwritten by the previous run's priming copy.
            // Held so a newer session can cancel it rather than wait it out.
            self.resultRowResetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.resultRowDuration))
                guard !Task.isCancelled, activity.activityState == .active else { return }
                guard let owner, order.owns(owner) else { return }
                guard self.resultRowToken == token else { return }
                let idleState = TranscriptionActivityAttributes.ContentState(
                    status: primedStatus,
                    lastSnippet: primedMessage,
                    provider: finalState.provider
                )
                publish(idleState, to: activity)
                self.resultRowToken = nil
            }
            return
        }

        // Ending supersedes every outstanding publication for this activity.
        order.retire()
        latestState = nil
        currentActivity = nil
        isActivityRunning = false
        enqueuePublication {
            await activity.end(
                .init(state: finalState, staleDate: nil),
                dismissalPolicy: .after(.now + Self.resultRowDuration)
            )
        }
    }
}
#endif
