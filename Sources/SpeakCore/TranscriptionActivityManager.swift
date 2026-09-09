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
    var supportsUpdateTimestamps: Bool { get }
    var transcriptionState: TranscriptionActivityAttributes.ContentState { get }
    func updateTranscription(_ state: TranscriptionActivityAttributes.ContentState, timestamp: Date) async
    func endTranscription(_ state: TranscriptionActivityAttributes.ContentState?, timestamp: Date) async
    func observeState(_ handler: @escaping @MainActor (ActivityState) -> Void) -> Task<Void, Never>
}

extension Activity: TranscriptionActivityHandle where Attributes == TranscriptionActivityAttributes {
    var nativeActivity: Activity<TranscriptionActivityAttributes>? { self }
    var transcriptionState: TranscriptionActivityAttributes.ContentState { content.state }
    var supportsUpdateTimestamps: Bool {
        if #available(iOS 17.2, *) { return true }
        return false
    }

    func updateTranscription(_ state: TranscriptionActivityAttributes.ContentState, timestamp: Date) async {
        if #available(iOS 17.2, *) {
            // ActivityKit ignores a payload older than its last accepted update.
            await update(.init(state: state, staleDate: nil), timestamp: timestamp)
        } else {
            await update(.init(state: state, staleDate: nil))
        }
    }

    func endTranscription(_ state: TranscriptionActivityAttributes.ContentState?, timestamp: Date) async {
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        let policy: ActivityUIDismissalPolicy = state == nil ? .immediate : .after(.now + 5)
        if #available(iOS 17.2, *) {
            await end(content, dismissalPolicy: policy, timestamp: timestamp)
        } else {
            await end(content, dismissalPolicy: policy)
        }
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
    private var pendingUpdate: (state: TranscriptionActivityAttributes.ContentState, timestamp: Date)?
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

    /// Reuses only active activities. Required background recording must not
    /// start audio if this returns false; foreground recovery remains the caller's responsibility.
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
        // A stale activity has outdated content, but is deliberately not reused
        // under our active-only policy. Inspect every candidate after rejecting the cache.
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
        currentActivity = nil
        isActivityRunning = false
    }

    private func isCurrent(_ candidate: any TranscriptionActivityHandle, runID: UUID) -> Bool {
        self.runID == runID && activity?.id == candidate.id && candidate.activityState == .active
    }

    /// Coalesce writes within a run to one in-flight call and one latest payload.
    /// New runs never await old writes; timestamps protect reuse on iOS 17.2+.
    /// Activity.request publishes its initial content independently of this queue.
    private func enqueueUpdate(
        _ state: TranscriptionActivityAttributes.ContentState,
        activity: any TranscriptionActivityHandle,
        runID: UUID
    ) {
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
        guard activity.activityState == .active else {
            clearActivity()
            return
        }
        let finalState = TranscriptionActivityAttributes.ContentState(
            status: .completed, lastSnippet: "Transcription complete", wordCount: finalWordCount,
            duration: duration, provider: activity.transcriptionState.provider
        )
        guard keepPrimed, activity.supportsUpdateTimestamps || inFlightUpdates[activity.id] == nil else {
            retire(activity, finalState: finalState)
            return
        }
        adopt(activity)
        let completionRun = runID
        enqueueUpdate(finalState, activity: activity, runID: completionRun)
        completionTask = Task { [weak self, sleep] in
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
        let timestamp = nextPayloadTimestamp()
        Task { [weak self] in
            await activity.endTranscription(finalState, timestamp: timestamp)
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
