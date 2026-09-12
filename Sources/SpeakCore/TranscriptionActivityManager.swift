#if os(iOS)
import ActivityKit
import Foundation
import os.log

/// Manages Live Activity lifecycle for transcription sessions.
///
/// Every piece of asynchronous work — the observer, throttled updates, the
/// result row's idle reset, in-flight writes and ending — belongs to one
/// recording run. A new run supersedes all of it synchronously, so nothing an
/// earlier run scheduled can land on the activity a later run owns, even when
/// the `Activity` object itself is reused (issue #932).
@MainActor
public final class TranscriptionActivityManager: ObservableObject {
    public static let shared = TranscriptionActivityManager()

    @Published public private(set) var currentActivity: Activity<TranscriptionActivityAttributes>?
    @Published public private(set) var isActivityRunning = false

    /// How long a finished capture stays on screen as a result row before it is
    /// dismissed (or, when primed, reverts to the idle Action Button label).
    /// The activity itself stays reusable throughout, so a primed headless start
    /// is unaffected.
    public static let resultRowDuration: TimeInterval = 180

    /// Internal rather than private because the result-row API that owns the
    /// row (`markCompletionCopied`) lives in this type's result-row extension,
    /// in its own file. Still not settable from outside the module.
    var activity: (any TranscriptionActivityHandle)?
    var runID = UUID()
    private var observerTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var updateThrottleTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var pendingUpdate: (state: TranscriptionActivityAttributes.ContentState, timestamp: Date)?
    /// The most recently *submitted* state. `activity.content.state` lags behind
    /// anything still in flight, so derived fields (provider, error) read this.
    /// Internal for the result-row extension, like `activity`.
    var latestState: TranscriptionActivityAttributes.ContentState?
    private var inFlightUpdates: [String: Int] = [:]
    private var lastPayloadTimestamp: Date = .distantPast
    private var retiringIDs: Set<String> = []
    private var lastUpdateTime: Date = .distantPast
    private let minimumUpdateInterval: TimeInterval = 1
    private let activitiesEnabled: () -> Bool
    private let activities: () -> [any TranscriptionActivityHandle]
    private let request: (TranscriptionActivityAttributes.ContentState) throws -> any TranscriptionActivityHandle
    private let sleep: (TimeInterval) async throws -> Void

    private convenience init() {
        self.init(
            activitiesEnabled: { ActivityAuthorizationInfo().areActivitiesEnabled },
            activities: { Activity<TranscriptionActivityAttributes>.activities },
            request: { state in
                try Activity.request(attributes: TranscriptionActivityAttributes(),
                                     content: .init(state: state, staleDate: nil), pushType: nil)
            }
        )
    }

    init(
        activitiesEnabled: @escaping () -> Bool,
        activities: @escaping () -> [any TranscriptionActivityHandle],
        request: @escaping (TranscriptionActivityAttributes.ContentState) throws -> any TranscriptionActivityHandle,
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.activitiesEnabled = activitiesEnabled
        self.activities = activities
        self.request = request
        self.sleep = sleep
    }

    /// Starts a Live Activity for transcription, reusing only an *active* one.
    /// Returns whether one is now active — callers that require a Live Activity
    /// (e.g. `AudioRecordingIntent` background recording) must not proceed when
    /// this returns `false`, or the system-policy check will assert
    /// (EXC_BREAKPOINT). Foreground recovery remains the caller's responsibility.
    @discardableResult
    public func startActivity(
        provider: String,
        initialStatus: TranscriptionActivityAttributes.TranscriptionStatus = .recording
    ) -> Bool {
        beginRun()
        guard activitiesEnabled() else {
            if let activity { retire(activity, finalState: nil) } else { clearActivity() }
            SpeakLogger.activity.info("Live Activities not enabled")
            return false
        }
        // Before timestamp support, an unfinished write cannot safely cross runs
        // on the same activity. Retire only this owned activity and use normal recovery.
        if let activity, !activity.supportsUpdateTimestamps, inFlightUpdates[activity.id] != nil {
            retire(activity, finalState: nil)
        }
        let state = TranscriptionActivityAttributes.ContentState(status: initialStatus, provider: provider)
        // Reuse a primed activity when possible. ActivityKit will not allow a
        // background AppIntent to request a brand-new Live Activity, but it can
        // update one that was created while the app was foregrounded. A stale
        // activity has outdated content, but is deliberately not reused under
        // our active-only policy. Inspect every candidate after rejecting the cache.
        if let candidate = ([activity].compactMap { $0 } + activities()).first(where: {
            $0.activityState == .active && !retiringIDs.contains($0.id)
                && ($0.supportsUpdateTimestamps || inFlightUpdates[$0.id] == nil)
        }) {
            adopt(candidate)
            enqueueUpdate(state, activity: candidate, runID: runID)
            return true
        }
        clearActivity()
        do {
            let candidate = try request(state)
            guard candidate.activityState == .active else { return false }
            adopt(candidate)
            latestState = state
            SpeakLogger.activity.info("Started activity: \(candidate.id, privacy: .public)")
            return true
        } catch {
            SpeakLogger.activity.error("Failed to start activity: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Opens a new run: everything the previous run scheduled is superseded now,
    /// before anything is published for this one.
    private func beginRun() {
        runID = UUID()
        completionTask?.cancel()
        completionTask = nil
        updateThrottleTask?.cancel()
        updateThrottleTask = nil
        updateTask?.cancel()
        updateTask = nil
        pendingUpdate = nil
        observerTask?.cancel()
        observerTask = nil
        lastUpdateTime = .distantPast
    }

    private func adopt(_ candidate: any TranscriptionActivityHandle) {
        activity = candidate
        currentActivity = candidate.nativeActivity
        isActivityRunning = true
        let observedRun = runID
        observerTask = candidate.observeState { [weak self] state in
            guard let self, self.runID == observedRun, self.activity?.id == candidate.id else { return }
            guard state != .active else { return }
            self.beginRun()
            self.clearActivity()
        }
    }

    private func clearActivity() {
        observerTask?.cancel()
        observerTask = nil
        activity = nil
        latestState = nil
        currentActivity = nil
        isActivityRunning = false
    }

    private func isCurrent(_ candidate: any TranscriptionActivityHandle, runID: UUID) -> Bool {
        self.runID == runID && activity?.id == candidate.id && candidate.activityState == .active
    }

    /// Coalesce writes within a run to one in-flight call and one latest payload.
    /// New runs never await old writes; timestamps protect reuse on iOS 17.2+.
    /// Activity.request publishes its initial content independently of this queue.
    func enqueueUpdate(
        _ state: TranscriptionActivityAttributes.ContentState,
        activity: any TranscriptionActivityHandle,
        runID: UUID
    ) {
        latestState = state
        pendingUpdate = (state, nextPayloadTimestamp())
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            while !Task.isCancelled, self?.isCurrent(activity, runID: runID) == true,
                  let next = self?.pendingUpdate {
                self?.pendingUpdate = nil
                self?.inFlightUpdates[activity.id, default: 0] += 1
                await activity.updateTranscription(next.state, timestamp: next.timestamp)
                self?.finishWrite(activity.id)
            }
            guard self?.runID == runID else { return }
            self?.updateTask = nil
        }
    }

    private func nextPayloadTimestamp() -> Date {
        lastPayloadTimestamp = max(Date(), lastPayloadTimestamp.addingTimeInterval(0.001))
        return lastPayloadTimestamp
    }

    private func finishWrite(_ activityID: String) {
        guard let count = inFlightUpdates[activityID] else { return }
        inFlightUpdates[activityID] = count > 1 ? count - 1 : nil
    }

    /// Updates the Live Activity with new transcription state, throttled to one
    /// write per second. A deferred write belongs to the run that requested it.
    public func updateActivity(
        status: TranscriptionActivityAttributes.TranscriptionStatus,
        lastSnippet: String,
        wordCount: Int,
        duration: Int
    ) {
        guard let activity, activity.activityState == .active else { return }
        updateThrottleTask?.cancel()
        let state = TranscriptionActivityAttributes.ContentState(
            status: status, lastSnippet: String(lastSnippet.suffix(100)), wordCount: wordCount,
            duration: duration, provider: (latestState ?? activity.transcriptionState).provider
        )
        let currentRun = runID
        let remaining = minimumUpdateInterval - Date().timeIntervalSince(lastUpdateTime)
        if remaining > 0 {
            updateThrottleTask = Task { [weak self, sleep] in
                do { try await sleep(remaining) } catch { return }
                guard !Task.isCancelled, let self, self.isCurrent(activity, runID: currentRun) else { return }
                self.lastUpdateTime = Date()
                self.enqueueUpdate(state, activity: activity, runID: currentRun)
            }
        } else {
            lastUpdateTime = Date()
            enqueueUpdate(state, activity: activity, runID: currentRun)
        }
    }

    /// Explicit outcome variant; the original entry point remains neutral and source-compatible.
    ///
    /// The completed row stays on screen for `resultRowDuration`. A primed
    /// activity then returns to its idle label — unless a new recording has
    /// taken the activity over in the meantime, in which case the reset was
    /// superseded and never publishes.
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
        guard let activity else { return }
        let provider = (latestState ?? activity.transcriptionState).provider
        beginRun()
        guard activity.activityState == .active else {
            clearActivity()
            return
        }
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
            provider: provider,
            completionOutcome: completionOutcome,
            resultPreview: resultPreview,
            resultCompletionID: resultCompletionID
        )
        guard keepPrimed, activity.supportsUpdateTimestamps || inFlightUpdates[activity.id] == nil else {
            retire(activity, finalState: finalState)
            return
        }
        adopt(activity)
        let completionRun = runID
        enqueueUpdate(finalState, activity: activity, runID: completionRun)
        completionTask = Task { [weak self, sleep] in
            do { try await sleep(Self.resultRowDuration) } catch { return }
            guard !Task.isCancelled, let self, self.isCurrent(activity, runID: completionRun) else { return }
            let idleState = TranscriptionActivityAttributes.ContentState(
                status: primedStatus, lastSnippet: primedMessage, provider: finalState.provider
            )
            self.enqueueUpdate(idleState, activity: activity, runID: completionRun)
        }
    }

    /// Ends the current activity immediately.
    public func endActivity() {
        beginRun()
        guard let activity else { return }
        retire(activity, finalState: nil)
    }

    private func retire(
        _ activity: any TranscriptionActivityHandle,
        finalState: TranscriptionActivityAttributes.ContentState?
    ) {
        // Detach synchronously and exclude it from adoption while end is suspended.
        // The end task owns this retired activity only, and never clears a newer run.
        retiringIDs.insert(activity.id)
        clearActivity()
        let timestamp = nextPayloadTimestamp()
        Task { [weak self] in
            await activity.endTranscription(finalState, timestamp: timestamp)
            self?.retiringIDs.remove(activity.id)
        }
    }

    /// Reports an error to the Live Activity.
    public func reportError(_ message: String) {
        guard let activity else { return }
        updateThrottleTask?.cancel()
        completionTask?.cancel()
        var state = latestState ?? activity.transcriptionState
        state.status = .error
        state.errorMessage = message
        enqueueUpdate(state, activity: activity, runID: runID)
    }
}
#endif
