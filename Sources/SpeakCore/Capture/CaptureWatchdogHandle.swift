import Foundation

/// The one run-owned handle for a capture's watchdog work (issue #993).
///
/// It owns everything one run's watchdog needs — the run identity, the clock
/// start, the ``CaptureWatchdogMonitor`` and the tick — so none of them can
/// belong to a different run from the others:
///
/// - ``arm(run:startedAt:isLive:onTrip:)`` first retires whatever the previous
///   run armed, cancelling its tick, then starts the new run's tick.
/// - ``retire()`` is called from every teardown path.
/// - Boundaries, input reports and trips are keyed by run. A tick from run A
///   that wakes after run B was armed fails the identity check and ends; it
///   can never evaluate or act on B.
///
/// The action re-checks ownership itself, because a run can end between the
/// evaluation and the action.
@MainActor
public final class CaptureWatchdogHandle {
    public typealias Sleep = @Sendable (TimeInterval) async -> Void

    private struct Armed {
        let run: UUID
        let startedAt: Date
    }

    private let tickSeconds: TimeInterval
    private let sleep: Sleep
    private let now: () -> Date
    private var armed: Armed?
    private var tick: Task<Void, Never>?
    /// The bounds of the armed run. Tests replace it mid-run to force a trip.
    var monitor = CaptureWatchdogMonitor()

    /// - Parameter tickSeconds: how often the bounds are checked. The shortest
    ///   bound is ten seconds, so one second is indistinguishable from a
    ///   precise timer and costs nothing.
    public init(
        tickSeconds: TimeInterval = 1,
        sleep: @escaping Sleep = CaptureDeadline.sleep,
        now: @escaping () -> Date = Date.init
    ) {
        self.tickSeconds = tickSeconds
        self.sleep = sleep
        self.now = now
    }

    /// The run these bounds belong to, while armed.
    public var runID: UUID? { armed?.run }

    public func owns(_ run: UUID) -> Bool {
        armed?.run == run
    }

    /// Seconds since `run` began, or `nil` when `run` does not own the handle.
    public func elapsedSeconds(for run: UUID) -> TimeInterval? {
        guard let armed, armed.run == run else { return nil }
        return now().timeIntervalSince(armed.startedAt)
    }

    /// Arms fresh bounds for `run`, measured from `startedAt`.
    ///
    /// - Parameters:
    ///   - isLive: whether the owner still considers the run in flight. A run
    ///     that ended by any other route is never evaluated.
    ///   - onTrip: acts on a trip. A non-terminal trip
    ///     (``CaptureWatchdogTrip/maximumDurationWarning``) keeps the tick
    ///     running; a terminal one ends it, because a run cannot end twice.
    public func arm(
        run: UUID,
        startedAt: Date,
        isLive: @escaping @MainActor () -> Bool,
        onTrip: @escaping @MainActor (CaptureWatchdogTrip, UUID) async -> Void
    ) {
        retire()
        monitor = CaptureWatchdogMonitor()
        armed = Armed(run: run, startedAt: startedAt)
        let sleep = sleep
        let tickSeconds = tickSeconds
        tick = Task { [weak self] in
            while !Task.isCancelled {
                await sleep(tickSeconds)
                guard !Task.isCancelled, let self, self.owns(run) else { return }
                guard let trip = self.evaluate(run: run, isLive: isLive) else { continue }
                await onTrip(trip, run)
                guard trip == .maximumDurationWarning else { return }
            }
        }
    }

    /// Ends the armed run's watchdog work: the tick is cancelled, the identity
    /// cleared and the monitor retired. Safe to call when nothing is armed.
    public func retire() {
        tick?.cancel()
        tick = nil
        armed = nil
        monitor.retire()
    }

    /// Forwards a startup boundary `run` crossed.
    public func note(_ stage: StartupStage, run: UUID) {
        guard let elapsed = elapsedSeconds(for: run) else { return }
        monitor.note(stage, atSeconds: elapsed)
    }

    /// Forwards that `run`'s own input tap delivered a buffer.
    public func noteInputObserved(run: UUID) {
        guard owns(run) else { return }
        monitor.noteInputObserved()
    }

    private func evaluate(run: UUID, isLive: () -> Bool) -> CaptureWatchdogTrip? {
        guard isLive(), let elapsed = elapsedSeconds(for: run) else { return nil }
        return monitor.evaluate(atSeconds: elapsed)
    }
}
