import Foundation

/// Explicit lifecycle of a recording service (issue #701). `starting` is an
/// active, cancellable operation: a stop that arrives while startup is
/// suspended retires the pending run instead of no-opping.
public enum RecordingServiceState: Equatable, Sendable {
    case idle
    case starting
    case recording
    case stopping
}

/// The run-identity state machine behind a cancellable recording startup
/// (issue #701).
///
/// A startup run holds a `UUID` identity. Every suspension point in the
/// service's `startRecording` re-checks `isCurrentStartRun` before publishing
/// shared state; a stop or cancel during `starting` retires the run, making
/// the resumed start unwind what it allocated instead of activating the
/// microphone. Stops can await `awaitStartSettled()` so cancellation is not
/// fire-and-forget. Cleanup ownership stays with the run that allocated each
/// resource: a retired old run can neither publish state nor tear down a
/// newer run's session, because `activate`/`isCurrentStartRun` fail for it.
@MainActor
public final class RecordingLifecycleCoordinator {
    public private(set) var state: RecordingServiceState = .idle

    private var activeStartRunID: UUID?
    private var cancelStartingSession: (() -> Void)?
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Whether a stop/toggle has an operation to act on: a live recording or
    /// a startup in flight (which stop will cancel).
    public var isActive: Bool { state == .starting || state == .recording }

    /// Claims the service for a new startup run. Returns the run's identity,
    /// or `nil` when the service is not idle (double start).
    public func beginStart() -> UUID? {
        guard state == .idle else { return nil }
        let runID = UUID()
        activeStartRunID = runID
        state = .starting
        return runID
    }

    /// Whether the given startup run still owns the service. False once a
    /// stop/cancel retired it or a newer run replaced it.
    public func isCurrentStartRun(_ runID: UUID) -> Bool {
        activeStartRunID == runID && state == .starting
    }

    /// Retires the in-flight startup run (a stop/cancel during `starting`).
    /// Cancels its allocated session immediately when a hook is installed.
    /// The suspended run still owns cleanup and settlement, so replacements
    /// cannot acquire resources before the old startup finishes unwinding.
    public func retireStartRun() {
        guard state == .starting else { return }
        activeStartRunID = nil
        let cancel = cancelStartingSession
        cancelStartingSession = nil
        cancel?()
    }

    /// Gives the current run ownership of its allocated session's cancellation.
    /// A late installation is cancelled immediately and cannot attach to a new run.
    @discardableResult
    public func installStartCancellation(for runID: UUID, cancel: @escaping () -> Void) -> Bool {
        guard isCurrentStartRun(runID) else {
            cancel()
            return false
        }
        cancelStartingSession = cancel
        return true
    }

    /// Publishes successful activation for the given run. Returns `false`
    /// when the run was retired or replaced — the caller must unwind instead
    /// of going live.
    public func activate(_ runID: UUID) -> Bool {
        guard isCurrentStartRun(runID) else { return false }
        activeStartRunID = nil
        cancelStartingSession = nil
        state = .recording
        settle()
        return true
    }

    /// Settles the state machine after a startup run unwound (cancellation or
    /// startup failure). Resumes any stops waiting on the cancellation.
    public func finishStartUnwind() {
        if state == .starting {
            activeStartRunID = nil
            cancelStartingSession = nil
            state = .idle
        }
        settle()
    }

    /// Transitions `recording` → `stopping`. Returns `false` when there is no
    /// live recording to stop.
    public func beginStopping() -> Bool {
        guard state == .recording else { return false }
        state = .stopping
        return true
    }

    /// Completes a stop (or a full cancel teardown) back to `idle`.
    public func finishStopping() {
        activeStartRunID = nil
        cancelStartingSession = nil
        state = .idle
        settle()
    }

    /// Waits until the in-flight startup run has activated or unwound, so a
    /// stop that cancelled a pending start returns only after no microphone,
    /// session or activity can remain active.
    public func awaitStartSettled() async {
        guard state == .starting else { return }
        await withCheckedContinuation { continuation in
            guard state == .starting else {
                continuation.resume()
                return
            }
            settleWaiters.append(continuation)
        }
    }

    private func settle() {
        guard state != .starting else { return }
        let waiters = settleWaiters
        settleWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}
