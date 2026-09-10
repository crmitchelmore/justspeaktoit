import Foundation

/// Decides when recording startup may stop presenting *preparation* and start
/// presenting *active capture* (issue #983).
///
/// Recording presentation used to flip to "recording" as soon as a start was
/// requested, before the backend had started and before any microphone buffer
/// had been seen. This gate keeps the presentation truthful: a run is only
/// promoted once it has *both* started its own backend *and* observed a
/// non-empty buffer from its *own* live input tap. Either arrival order
/// completes the pair — a tap callback can land before `start()` returns — and
/// the promotion is reported exactly once per run.
///
/// Run identity is the whole point: a buffer observed by a replaced or retired
/// run must never promote its successor, so every observation is stamped with
/// the run that made it. This is presentation only — it does not gate capture,
/// buffering, delivery or cancellation.
public struct CapturePresentationGate: Sendable, Equatable {
    public enum Presentation: String, Sendable, Equatable {
        /// No run is in flight.
        case idle
        /// A run is starting; capture is not yet proven.
        case preparing
        /// This run started its backend and observed its own input.
        case capturing
    }

    private var runID: UUID?
    private var backendStarted = false
    private var inputObserved = false
    private var promoted = false

    /// Copy shown while recording startup has not yet proven capture. Shared
    /// with the widget so the lock screen and the app agree.
    public static let preparingMessage = "Preparing recording..."

    public init() {}

    public var presentation: Presentation {
        guard runID != nil else { return .idle }
        return promoted ? .capturing : .preparing
    }

    /// Whether active-capture presentation (a recording indicator, live
    /// snippets, hands-free utterance status) may be shown right now.
    public var isPresentingCapture: Bool { presentation == .capturing }

    public func isCurrent(_ run: UUID) -> Bool { runID == run }

    /// Begins a new run, retiring any predecessor's pending observations.
    public mutating func begin(run: UUID) {
        runID = run
        backendStarted = false
        inputObserved = false
        promoted = false
    }

    /// Records that `run`'s backend start completed successfully.
    /// - Returns: `true` exactly once, when this completes the pair.
    @discardableResult
    public mutating func noteBackendStarted(run: UUID) -> Bool {
        guard runID == run else { return false }
        backendStarted = true
        return promoteIfProven()
    }

    /// Records a non-empty buffer accepted from `run`'s own live input tap.
    /// - Returns: `true` exactly once, when this completes the pair.
    @discardableResult
    public mutating func noteInputObserved(run: UUID) -> Bool {
        guard runID == run else { return false }
        inputObserved = true
        return promoteIfProven()
    }

    /// Ends the current run — stop, cancel, or a failed start. Callbacks that
    /// arrive afterwards are ignored until a new run begins, so a failed start
    /// can never leave the presentation stuck in preparation.
    public mutating func finish() {
        runID = nil
        backendStarted = false
        inputObserved = false
        promoted = false
    }

    private mutating func promoteIfProven() -> Bool {
        guard !promoted, backendStarted, inputObserved else { return false }
        promoted = true
        return true
    }
}

/// A once-only "this tap delivered input" flag, set from the real-time audio
/// thread and read on the owning actor.
///
/// `markObserved()` returns `true` for the first accepted buffer only, so a
/// tap raises at most one actor hop per run rather than one per buffer. No
/// sample analysis happens here: a positive frame count is evidence that the
/// tap is delivering, not that anyone spoke.
public final class FirstInputSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false

    public init() {}

    public var hasObserved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    /// - Returns: `true` only for the first call.
    public func markObserved() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if observed { return false }
        observed = true
        return true
    }
}
