#if os(iOS)
import Foundation
import SpeakCore

/// Which foreground run owns the microphone, and through which session.
///
/// One run owns capture from its claim to settlement (#701, #943). The
/// process-local ``ForegroundRecordingOwnership`` claim is what the Control and
/// intent start guards read; it is taken before the first suspension of a
/// start and released only once that run's startup unwind, cancellation
/// cleanup or owned stop has settled, so a replacement can never overlap it.
/// Each phase keeps its own session so a retired startup, a replaced session
/// or a cancelled stop cannot publish anything.
@MainActor
final class ForegroundRunOwner {
    /// What ``cancel()`` found to cancel.
    enum Cancellation {
        /// Nothing was running.
        case idle
        /// A pending start was retired; it unwinds and releases itself.
        case retiredStart
        /// Capture was cancelled; `settling` is the session whose cleanup the
        /// claim waits for.
        case cancelled(settling: (any IOSRecordingSession)?)
    }

    /// Where an accepted session callback goes.
    struct SessionEvents {
        let partial: (String, Bool, any IOSRecordingSession) -> Void
        let warning: (String) -> Void
        let failure: (Error, any IOSRecordingSession) -> Void
        let firstInput: () -> Void
    }

    private let lifecycle = RecordingLifecycleCoordinator()
    /// Exclusive provider startup, so a second call while the first awaits
    /// `session.start` cannot create a second capturing session.
    private let startup = RecordingStartupOperation()
    private let ownership: ForegroundRecordingOwnership
    private let onRelease: (UUID) -> Void
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    private(set) var ownedRunID: UUID?
    private var startingSession: (any IOSRecordingSession)?
    private(set) var activeSession: (any IOSRecordingSession)?
    private var stoppingSession: (any IOSRecordingSession)?
    private var stopWasCancelled = false
    /// A provider failure reported while starting; startup reports it only
    /// after cancellation has been ruled out.
    private var startupFailure: Error?

    init(ownership: ForegroundRecordingOwnership, onRelease: @escaping (UUID) -> Void) {
        self.ownership = ownership
        self.onRelease = onRelease
    }

    var phase: RecordingServiceState { lifecycle.state }
    var isOwned: Bool { ownership.isOwned }

    // MARK: Starting

    /// Claims a new run, or returns `nil` when one already owns capture. The
    /// caller has checked the headless service with no suspension since.
    func claim(binding handle: ForegroundCaptureHandle?) -> UUID? {
        guard !ownership.isOwned, let runID = lifecycle.beginStart() else { return nil }
        _ = ownership.claim(runID)
        ownedRunID = runID
        handle?.runID = runID
        startupFailure = nil
        return runID
    }

    func runStartup(_ body: @escaping @MainActor () async throws -> Void) async throws {
        try await startup.run(body)
    }

    func checkStart(_ runID: UUID) throws {
        try Task.checkCancellation()
        guard lifecycle.isCurrentStartRun(runID) else { throw CancellationError() }
    }

    func isCurrentStartRun(_ runID: UUID) -> Bool { lifecycle.isCurrentStartRun(runID) }

    /// Cancellation is owned by exactly this run and this session; a late
    /// installation is cancelled immediately and cannot attach to a replacement.
    func adoptStarting(_ session: any IOSRecordingSession, run runID: UUID) throws {
        startingSession = session
        guard lifecycle.installStartCancellation(for: runID, cancel: { session.cancel() }) else {
            throw CancellationError()
        }
    }

    /// The started session; activation follows the startup's final check.
    func noteStarted(_ session: any IOSRecordingSession) {
        activeSession = session
    }

    /// Activates the run, or throws when it was retired meanwhile.
    func activate(_ runID: UUID) throws {
        if let startupFailure { throw startupFailure }
        guard lifecycle.activate(runID) else { throw CancellationError() }
        startingSession = nil
    }

    /// Retires a failed or cancelled start and waits until the session it
    /// allocated has cleaned up. Call ``finishStartUnwind()`` once the caller
    /// has cleared what it published.
    func retireStart() async {
        lifecycle.retireStartRun()
        await startingSession?.awaitCancellationSettled()
        startingSession = nil
        startupFailure = nil
        activeSession = nil
    }

    func finishStartUnwind() {
        lifecycle.finishStartUnwind()
        release()
    }

    func awaitStartSettled() async {
        await lifecycle.awaitStartSettled()
    }

    // MARK: Callbacks

    /// Routes `session`'s callbacks to `events` only while this run and
    /// session are current, so a retired startup or a replaced session can
    /// publish nothing. Cancellation is never reported as a failure.
    func bind(_ session: any IOSRecordingSession, run runID: UUID, to events: SessionEvents) {
        session.onPartialResult = { [weak self, weak session] text, isFinal in
            guard let self, let session, self.accepts(runID, session: session) else { return }
            events.partial(text, isFinal, session)
        }
        session.onRecordingWarning = { [weak self, weak session] message in
            guard let self, let session, self.accepts(runID, session: session) else { return }
            events.warning(message)
        }
        session.onError = { [weak self, weak session] error in
            guard let self, let session, self.accepts(runID, session: session),
                  !(error is CancellationError) else { return }
            guard self.lifecycle.state != .starting else {
                self.startupFailure = error
                return
            }
            events.failure(error, session)
        }
        // The run's own first live buffer can arrive while `start()` is still
        // suspended, which is why this reads the run identity.
        session.onFirstInputBuffer = { [weak self, weak session] in
            guard let self, let session, self.accepts(runID, session: session) else { return }
            events.firstInput()
        }
    }

    /// Whether a provider callback belongs to the run and session that are
    /// current *now*. The stop in progress still receives its own final partials.
    func accepts(_ runID: UUID, session: any IOSRecordingSession) -> Bool {
        guard ownedRunID == runID else { return false }
        switch lifecycle.state {
        case .starting: return lifecycle.isCurrentStartRun(runID) && startingSession === session
        case .recording: return activeSession === session
        case .stopping: return !stopWasCancelled && stoppingSession === session
        case .idle: return false
        }
    }

    func owns(_ handle: ForegroundCaptureHandle) -> Bool {
        guard let runID = handle.runID else { return false }
        return ownedRunID == runID
    }

    // MARK: Stopping

    func beginStopping() -> Bool { lifecycle.beginStopping() }

    func finishStopping() {
        lifecycle.finishStopping()
        release()
    }

    /// Moves the active session into its owned drain.
    func takeForStop() -> (any IOSRecordingSession)? {
        guard let session = activeSession else { return nil }
        activeSession = nil
        stoppingSession = session
        stopWasCancelled = false
        return session
    }

    /// Whether the drain of `session` still owns its outcome.
    func stillOwnsStop(of session: any IOSRecordingSession) -> Bool {
        !Task.isCancelled && !stopWasCancelled && stoppingSession === session
    }

    /// Ends the drain of `session`; `false` when a later owner replaced it.
    func endStop(of session: any IOSRecordingSession) -> Bool {
        guard stoppingSession === session else { return false }
        stoppingSession = nil
        return true
    }

    // MARK: Cancelling

    func cancel() -> Cancellation {
        if lifecycle.state == .starting {
            // Retire first: the suspended start unwinds what it allocated and
            // releases ownership itself, so nothing else can claim it early.
            lifecycle.retireStartRun()
            startup.cancel()
            return .retiredStart
        }
        guard lifecycle.state != .idle else { return .idle }
        let active = activeSession
        activeSession = nil
        stopWasCancelled = stoppingSession != nil
        active?.cancel()
        // A stopping session retains ownership until its suspended drain returns.
        stoppingSession?.cancel()
        return .cancelled(settling: active)
    }

    /// Begins stopping a cancelled run, whose claim is released once
    /// `settling` has cleaned up. Returns `false` when already stopping.
    func settleCancellation(of settling: (any IOSRecordingSession)?, then onSettled: @escaping () -> Void) -> Bool {
        guard lifecycle.beginStopping() else { return false }
        let runID = ownedRunID
        Task { @MainActor [self] in
            await settling?.awaitCancellationSettled()
            guard ownedRunID == runID else { return }
            finishStopping()
            onSettled()
        }
        return true
    }

    /// Resumes once the run that owns capture now has released it.
    func waitForRelease() async {
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    private func release() {
        if let ownedRunID {
            onRelease(ownedRunID)
            ownership.release(ownedRunID)
        }
        ownedRunID = nil
        let waiters = releaseWaiters
        releaseWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}
#endif
