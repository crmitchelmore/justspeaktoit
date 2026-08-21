import Foundation

/// How one PCM frame was admitted to (or refused by) recording persistence
/// (issue #705).
public enum RecordingPersistenceAdmission: Equatable, Sendable {
    /// Copied through the reusable pool and queued for writing.
    case accepted
    /// The pool was exhausted, but the in-flight budget allowed a controlled
    /// fallback allocation to absorb the stall.
    case acceptedViaOverflow
    /// The bounded in-flight budget is exhausted: the frame was dropped and
    /// recorded as a gap. The saved recording is no longer complete.
    case backpressured
}

/// What a completed recording's persistence actually did — the truth the
/// session and UI must report instead of presenting every saved file as a
/// healthy complete recording (issue #705).
public struct RecordingPersistenceDiagnostics: Equatable, Sendable {
    /// Frames admitted (pool or overflow) and handed to the writer.
    public var admittedFrames: Int = 0
    /// Audio duration admitted, in seconds of source PCM.
    public var admittedSeconds: Double = 0
    /// Frames dropped because the bounded in-flight budget was exhausted.
    public var droppedFrames: Int = 0
    /// Exactly how much audio the drops removed, in seconds.
    public var droppedSeconds: Double = 0
    /// File writes that failed after admission.
    public var writeFailures: Int = 0
    /// Fallback allocations used while the pool was exhausted.
    public var overflowAllocations: Int = 0
    /// Most audio seconds simultaneously in flight (admitted, not yet
    /// written) — evidence for sizing the pool and budget.
    public var inFlightHighWaterSeconds: Double = 0

    public init() {}

    /// A recording is complete only when nothing was dropped and every
    /// admitted write landed.
    public var isComplete: Bool { droppedFrames == 0 && writeFailures == 0 }
}

/// Bounded admission for the persistence write queue (issue #705).
///
/// The real-time audio callback must never block, so admission is a
/// constant-time decision: use the reusable pool while it has capacity, absorb
/// short I/O stalls with fallback allocations up to a duration budget sized
/// from the actual sample format, and beyond that drop the frame while
/// accounting for exactly how much audio was lost. Sustained overflow can
/// therefore never masquerade as a healthy complete recording.
public final class RecordingPersistenceAdmissionController: @unchecked Sendable {
    private let lock = NSLock()
    private let overflowBudgetSeconds: Double
    private var inFlightSeconds: Double = 0
    private var storedDiagnostics = RecordingPersistenceDiagnostics()

    /// - Parameter overflowBudgetSeconds: how much audio may sit admitted but
    ///   unwritten before further frames are dropped. Two seconds absorbs a
    ///   short filesystem stall without letting a wedged writer grow memory
    ///   unboundedly.
    public init(overflowBudgetSeconds: Double = 2.0) {
        self.overflowBudgetSeconds = overflowBudgetSeconds
    }

    public var diagnostics: RecordingPersistenceDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return storedDiagnostics
    }

    /// Decides admission for one frame.
    ///
    /// - Parameters:
    ///   - frameSeconds: the frame's duration derived from the actual sample
    ///     format (`frameLength / sampleRate`).
    ///   - poolHasCapacity: whether the reusable pool produced a copy.
    public func admit(frameSeconds: Double, poolHasCapacity: Bool) -> RecordingPersistenceAdmission {
        lock.lock()
        defer { lock.unlock() }

        if !poolHasCapacity && inFlightSeconds + frameSeconds > overflowBudgetSeconds {
            storedDiagnostics.droppedFrames += 1
            storedDiagnostics.droppedSeconds += frameSeconds
            return .backpressured
        }

        inFlightSeconds += frameSeconds
        storedDiagnostics.admittedFrames += 1
        storedDiagnostics.admittedSeconds += frameSeconds
        storedDiagnostics.inFlightHighWaterSeconds = max(
            storedDiagnostics.inFlightHighWaterSeconds,
            inFlightSeconds
        )
        if poolHasCapacity {
            return .accepted
        }
        storedDiagnostics.overflowAllocations += 1
        return .acceptedViaOverflow
    }

    /// Records the completion of one admitted write.
    public func completeWrite(frameSeconds: Double, failed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        inFlightSeconds = max(0, inFlightSeconds - frameSeconds)
        if failed {
            storedDiagnostics.writeFailures += 1
        }
    }
}
