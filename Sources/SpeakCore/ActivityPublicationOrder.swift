import Foundation

/// Orders Live Activity content publications so a superseded or prior-run
/// publication can never overwrite the current run's latest state (issue #983).
///
/// ActivityKit updates are asynchronous. Submitting each one as its own
/// unstructured task lets an older publication land *after* a newer one, which
/// defeats the point of proven-capture presentation: a reused activity can show
/// `.arming` again after this run proved capture, and a deferred update from the
/// preceding recording — a throttled snippet, or the priming continuation — can
/// complete during its successor and replace that successor's preparation
/// content with a previous run's transcript.
///
/// Every publication takes a ticket stamped with the run that owns the activity
/// plus a monotonic sequence. A ticket may be applied only while its run still
/// owns the activity *and* no newer publication has been submitted, so ordering
/// and run ownership are decided by one rule that is testable off-device.
///
/// This is presentation bookkeeping only: it never gates capture, buffering,
/// delivery or cancellation.
public struct ActivityPublicationOrder: Sendable, Equatable {
    /// A single pending publication.
    public struct Ticket: Sendable, Equatable, Hashable {
        public let run: UUID
        public let sequence: Int
    }

    private var run: UUID?
    private var sequence = 0

    public init() {}

    /// The run that currently owns the activity, if any.
    public var currentRun: UUID? { run }

    /// Retires whatever run held the activity and opens a new one. Every
    /// outstanding publication of the previous run is superseded immediately.
    @discardableResult
    public mutating func beginRun() -> UUID {
        let next = UUID()
        run = next
        sequence += 1
        return next
    }

    /// Takes the next ticket for the owning run, or `nil` when no run owns the
    /// activity (nothing may be published then).
    public mutating func submit() -> Ticket? {
        guard let run else { return nil }
        sequence += 1
        return Ticket(run: run, sequence: sequence)
    }

    /// Whether `ticket` is still both owned by the current run and the newest
    /// publication submitted for it.
    public func isCurrent(_ ticket: Ticket) -> Bool {
        run == ticket.run && sequence == ticket.sequence
    }

    /// Whether `candidate` still owns the activity. Used by deferred work — the
    /// priming continuation — that must not publish into a successor run.
    public func owns(_ candidate: UUID) -> Bool { run == candidate }

    /// Ends the run. Nothing outstanding may publish afterwards.
    public mutating func retire() {
        run = nil
        sequence += 1
    }
}
