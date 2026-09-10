// Capture watchdogs: putting a bound on the states an iOS capture can
// currently sit in forever (issue #993).
//
// Three of the four bounds are decisions, and every decision lives here —
// pure, clock-driven, free of AV, Speech and UIKit — because the way a
// watchdog fails is by firing on somebody who was using the app normally, and
// that is not something a device check finds reliably. The fourth, the
// finalisation deadline, is a race rather than a rule, so it is expressed here
// as ``CaptureDeadline`` with an injectable sleep and proved the same way.
//
// The inputs are the ones the stack already produces. The stage boundaries are
// ``StartupStage`` values reported through `IOSTranscriptionSession`'s existing
// observation seam (issue #972). The first-buffer fact is the same
// `FirstInputSignal` promotion that issue #983 already routes into
// ``CapturePresentationGate``. Nothing here adds a second detector.
import Foundation

// MARK: - Policy

/// The budgets a capture runs to, in one place so no surface can disagree.
///
/// Every value errs long. A watchdog that fires during legitimate use destroys
/// a recording the user was in the middle of, which is strictly worse than the
/// hang it was meant to prevent; a watchdog that fires ten seconds later than
/// it could have costs nothing, because the state it is bounding was going to
/// last forever otherwise.
public enum CaptureWatchdogPolicy {
    /// How long a start may take before it is abandoned, measured from the
    /// earliest app-code entry the caller observed.
    ///
    /// A healthy start crosses ``StartupStage/sessionStarted`` in well under a
    /// second on Apple's on-device path and in a few seconds on a cloud
    /// provider's first socket. Sixty seconds is roughly an order of magnitude
    /// beyond the slowest legitimate case that does not involve a download,
    /// so nothing that is merely slow trips it.
    ///
    /// The known exception is a first-use SpeechAnalyzer asset download, which
    /// still runs inside the start path and can take minutes on a poor
    /// connection (issue #938). Until that moves out of the start path, a
    /// first-run start on a slow link can hit this deadline. That is recorded
    /// as a known false positive rather than papered over: the outcome is a
    /// cancelled start with the stalled stage named, not a lost recording.
    public static let startDeadlineSeconds: TimeInterval = 60

    /// How long after the audio engine reports started the capture may see no
    /// input buffer at all before the microphone is treated as dead.
    ///
    /// This is a bound on *zero buffers*, never on quiet ones. A healthy tap
    /// delivers its first buffer within a hardware buffer period — on the
    /// order of a hundred milliseconds — whether the room is silent or not,
    /// because a buffer of silence is still a buffer. Ten seconds is a hundred
    /// times that, and a user who takes ten seconds to start speaking is not
    /// affected by it at all: their tap has been delivering silence the whole
    /// time.
    public static let firstInputDeadlineSeconds: TimeInterval = 10

    /// The hard cap on a single capture.
    ///
    /// An hour is longer than anything anyone dictates in one go, and it is
    /// the bound on the genuinely unbounded case: a capture started by a
    /// hardware trigger in a pocket that nobody ever stops. Reaching it is not
    /// an error — the capture is finalised and delivered exactly as a press of
    /// the stop button would finalise it.
    public static let maximumCaptureSeconds: TimeInterval = 3600

    /// How long before the cap the capture says so, once, so a user who is
    /// still talking has time to stop and restart rather than being cut off
    /// without warning.
    public static let maximumCaptureWarningLeadSeconds: TimeInterval = 300

    /// How long a stop may wait for its provider to finalise.
    ///
    /// A streaming provider drains a tail it already holds, which is a
    /// sub-second operation; thirty seconds bounds a socket that has silently
    /// died without ever cutting a healthy drain short. A batch provider has
    /// to upload the whole recording, so its budget is the length of a slow
    /// cellular upload of a long file, not of a drain.
    ///
    /// This is a ceiling over the shorter, provider-level bounds that already
    /// exist — the legacy Apple recogniser's two-second completion wait from
    /// issue #948 among them — never a replacement for them.
    public static func finalisationDeadlineSeconds(isBatch: Bool) -> TimeInterval {
        isBatch ? 300 : 30
    }
}

// MARK: - Trips

/// What a watchdog found. Each value has exactly one defined outcome at the
/// call site, and each is raised at most once per run.
public enum CaptureWatchdogTrip: Equatable, Sendable {
    /// The start never reached ``StartupStage/sessionStarted``. Carries the
    /// last boundary the run actually crossed, so the failure names where it
    /// stalled instead of saying only that it did.
    case startStalled(after: StartupStage?)
    /// The audio engine started and the input tap then produced no buffer at
    /// all. This is a dead microphone, not a quiet one.
    case noInput
    /// The capture is ``CaptureWatchdogPolicy/maximumCaptureWarningLeadSeconds``
    /// away from its cap.
    case maximumDurationWarning
    /// The capture reached its cap.
    case maximumDuration
}

// MARK: - Monitor

/// The bounds one capture run is held to.
///
/// Injectable so tests can prove the fire and the no-fire cases without
/// waiting in real time, and so a caller that wants a different cap (a
/// one-shot intent with its own budget) states it rather than editing policy.
public struct CaptureWatchdogBudget: Equatable, Sendable {
    public let startDeadline: TimeInterval
    public let firstInputDeadline: TimeInterval
    public let maximumDuration: TimeInterval
    public let maximumDurationWarningLead: TimeInterval

    public init(
        startDeadline: TimeInterval = CaptureWatchdogPolicy.startDeadlineSeconds,
        firstInputDeadline: TimeInterval = CaptureWatchdogPolicy.firstInputDeadlineSeconds,
        maximumDuration: TimeInterval = CaptureWatchdogPolicy.maximumCaptureSeconds,
        maximumDurationWarningLead: TimeInterval = CaptureWatchdogPolicy.maximumCaptureWarningLeadSeconds
    ) {
        self.startDeadline = startDeadline
        self.firstInputDeadline = firstInputDeadline
        self.maximumDuration = maximumDuration
        self.maximumDurationWarningLead = maximumDurationWarningLead
    }
}

/// Decides, from the boundaries a run has crossed and how long it has been
/// running, whether one of its bounds has been exceeded.
///
/// Time is supplied by the caller as seconds since the run began, so every
/// case is provable on the host. The monitor is single-shot for terminal
/// trips: once it has reported one, it reports nothing further, because the
/// outcome of a trip is that the run ends and a run cannot end twice.
public struct CaptureWatchdogMonitor: Equatable, Sendable {
    private let budget: CaptureWatchdogBudget
    private var lastStage: StartupStage?
    private var engineStartedAtSeconds: TimeInterval?
    private var sessionStarted = false
    private var inputObserved = false
    private var warned = false
    private var finished = false

    public init(_ budget: CaptureWatchdogBudget = CaptureWatchdogBudget()) {
        self.budget = budget
    }

    /// Records a boundary this run crossed, as reported through the existing
    /// startup observation seam. `atSeconds` is when it was crossed.
    public mutating func note(_ stage: StartupStage, atSeconds seconds: TimeInterval) {
        lastStage = stage
        if stage == .engineStarted, engineStartedAtSeconds == nil {
            engineStartedAtSeconds = seconds
        }
        if stage == .sessionStarted {
            sessionStarted = true
        }
    }

    /// Records that this run's own input tap delivered a buffer — the same
    /// fact issue #983 already routes into ``CapturePresentationGate``.
    /// A positive frame count is evidence the tap is delivering, never
    /// evidence that anyone spoke.
    public mutating func noteInputObserved() {
        inputObserved = true
    }

    /// Stops the monitor reporting anything further. Called when the run ends
    /// by any route, so a watchdog can never act on a run that is already over.
    public mutating func retire() {
        finished = true
    }

    public var isRetired: Bool { finished }

    /// - Parameter seconds: elapsed time since the run began.
    /// - Returns: the bound that has been exceeded, or `nil`.
    public mutating func evaluate(atSeconds seconds: TimeInterval) -> CaptureWatchdogTrip? {
        guard !finished else { return nil }

        if seconds >= budget.maximumDuration {
            finished = true
            return .maximumDuration
        }

        // A start that has not reached its backend yet cannot have a live
        // microphone to lose, so the two startup bounds are checked before the
        // warning and never after the run is live.
        if let engineStartedAtSeconds,
           !inputObserved,
           seconds - engineStartedAtSeconds >= budget.firstInputDeadline {
            finished = true
            return .noInput
        }

        if !sessionStarted, seconds >= budget.startDeadline {
            finished = true
            return .startStalled(after: lastStage)
        }

        if !warned, seconds >= budget.maximumDuration - budget.maximumDurationWarningLead {
            warned = true
            return .maximumDurationWarning
        }

        return nil
    }
}

// MARK: - Finalisation deadline

/// A box for the settled flag of a race between real work and a deadline.
/// `@MainActor` because every caller of ``CaptureDeadline`` is, so no
/// synchronisation beyond actor isolation is needed or claimed.
@MainActor
private final class CaptureDeadlineGate {
    var settled = false
}

/// Bounds how long a caller waits for work that may never return.
///
/// Deliberately *not* a task group: a group does not return until all of its
/// children have, so a provider that ignores cancellation would keep the
/// caller waiting for exactly as long as it would have without the bound. The
/// expired branch cancels the work and stops waiting on it.
@MainActor
public enum CaptureDeadline {
    /// Real time. Injectable so the deadline is provable on the host without
    /// waiting for it.
    public static let sleep: @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// - Returns: the operation's value, or `nil` when `seconds` elapsed first.
    ///   An error thrown by the operation is rethrown unchanged, so a caller's
    ///   existing failure handling is untouched by the bound.
    public static func result<T: Sendable>(
        of operation: @escaping @MainActor () async throws -> T,
        orNilAfter seconds: TimeInterval,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = CaptureDeadline.sleep
    ) async throws -> T? {
        let gate = CaptureDeadlineGate()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, Error>) in
            let work = Task { @MainActor in
                do {
                    let value = try await operation()
                    guard !gate.settled else { return }
                    gate.settled = true
                    continuation.resume(returning: value)
                } catch {
                    guard !gate.settled else { return }
                    gate.settled = true
                    continuation.resume(throwing: error)
                }
            }
            Task { @MainActor in
                await sleep(seconds)
                guard !gate.settled else { return }
                gate.settled = true
                work.cancel()
                continuation.resume(returning: nil)
            }
        }
    }
}
