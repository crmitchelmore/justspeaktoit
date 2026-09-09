#if os(iOS)
import ActivityKit
import Foundation
import os.log

/// A narrow ActivityKit boundary lets lifecycle races be exercised without system UI.
@MainActor
protocol TranscriptionActivityHandle: AnyObject {
    var nativeActivity: Activity<TranscriptionActivityAttributes>? { get }
    var id: String { get }
    var activityState: ActivityState { get }
    var transcriptionState: TranscriptionActivityAttributes.ContentState { get }
    func updateTranscription(_ state: TranscriptionActivityAttributes.ContentState) async
    func endTranscription(_ state: TranscriptionActivityAttributes.ContentState?) async
    func observeState(_ handler: @escaping @MainActor (ActivityState) -> Void) -> Task<Void, Never>
}

extension Activity: TranscriptionActivityHandle where Attributes == TranscriptionActivityAttributes {
    var nativeActivity: Activity<TranscriptionActivityAttributes>? { self }
    var transcriptionState: TranscriptionActivityAttributes.ContentState { content.state }

    func updateTranscription(_ state: TranscriptionActivityAttributes.ContentState) async {
        await update(.init(state: state, staleDate: nil))
    }

    func endTranscription(_ state: TranscriptionActivityAttributes.ContentState?) async {
        await end(state.map { .init(state: $0, staleDate: nil) },
                  dismissalPolicy: state == nil ? .immediate : .after(.now + 5))
    }

    func observeState(_ handler: @escaping @MainActor (ActivityState) -> Void) -> Task<Void, Never> {
        Task {
            for await state in activityStateUpdates {
                guard !Task.isCancelled else { return }
                handler(state)
            }
        }
    }
}

/// Manages Live Activity lifecycle for transcription sessions.
@MainActor
public final class TranscriptionActivityManager: ObservableObject {
    public static let shared = TranscriptionActivityManager()

    @Published public private(set) var currentActivity: Activity<TranscriptionActivityAttributes>?
    @Published public private(set) var isActivityRunning = false

    private var activity: (any TranscriptionActivityHandle)?
    private var runID = UUID()
    private var observerTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var updateThrottleTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
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

    /// Reuses only active activities. Required background recording must not
    /// start audio if this returns false; foreground recovery remains the caller's responsibility.
    @discardableResult
    public func startActivity(
        provider: String,
        initialStatus: TranscriptionActivityAttributes.TranscriptionStatus = .recording
    ) -> Bool {
        beginRun()
        guard activitiesEnabled() else {
            clearActivity()
            SpeakLogger.activity.info("Live Activities not enabled")
            return false
        }
        let state = TranscriptionActivityAttributes.ContentState(status: initialStatus, provider: provider)
        // A stale activity has outdated content, but is deliberately not reused
        // under our active-only policy. Inspect every candidate after rejecting the cache.
        if let candidate = ([activity].compactMap { $0 } + activities()).first(where: {
            $0.activityState == .active && !retiringIDs.contains($0.id)
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
            SpeakLogger.activity.info("Started activity: \(candidate.id, privacy: .public)")
            return true
        } catch {
            SpeakLogger.activity.error("Failed to start activity: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func beginRun() {
        runID = UUID()
        completionTask?.cancel()
        completionTask = nil
        updateThrottleTask?.cancel()
        updateThrottleTask = nil
        updateTask?.cancel()
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
        currentActivity = nil
        isActivityRunning = false
    }

    private func isCurrent(_ candidate: any TranscriptionActivityHandle, runID: UUID) -> Bool {
        self.runID == runID && activity?.id == candidate.id && candidate.activityState == .active
    }

    /// Serialise ActivityKit writes: even an update already suspended inside
    /// ActivityKit must finish before a replacement run publishes its first state.
    private func enqueueUpdate(
        _ state: TranscriptionActivityAttributes.ContentState,
        activity: any TranscriptionActivityHandle,
        runID: UUID
    ) {
        let previous = updateTask
        updateTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, self.isCurrent(activity, runID: runID) else { return }
            await activity.updateTranscription(state)
        }
    }

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
            duration: duration, provider: activity.transcriptionState.provider
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

    /// Keeps a completed headless activity primed for the next Action Button invocation.
    public func completeActivity(
        finalWordCount: Int,
        duration: Int,
        keepPrimed: Bool = false,
        primedMessage: String = "Ready for the Action Button",
        primedStatus: TranscriptionActivityAttributes.TranscriptionStatus = .idle
    ) {
        guard let activity else { return }
        beginRun()
        let finalState = TranscriptionActivityAttributes.ContentState(
            status: .completed, lastSnippet: "Transcription complete", wordCount: finalWordCount,
            duration: duration, provider: activity.transcriptionState.provider
        )
        guard keepPrimed else {
            retire(activity, finalState: finalState)
            return
        }
        adopt(activity)
        let completionRun = runID
        enqueueUpdate(finalState, activity: activity, runID: completionRun)
        let finalUpdate = updateTask
        completionTask = Task { [weak self, sleep] in
            await finalUpdate?.value
            do { try await sleep(5) } catch { return }
            guard !Task.isCancelled, let self, self.isCurrent(activity, runID: completionRun) else { return }
            let idleState = TranscriptionActivityAttributes.ContentState(
                status: primedStatus, lastSnippet: primedMessage, provider: finalState.provider
            )
            self.enqueueUpdate(idleState, activity: activity, runID: completionRun)
        }
    }

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
        let previous = updateTask
        Task { [weak self] in
            await previous?.value
            await activity.endTranscription(finalState)
            self?.retiringIDs.remove(activity.id)
        }
    }

    public func reportError(_ message: String) {
        guard let activity else { return }
        updateThrottleTask?.cancel()
        completionTask?.cancel()
        var state = activity.transcriptionState
        state.status = .error
        state.errorMessage = message
        enqueueUpdate(state, activity: activity, runID: runID)
    }
}
#endif
