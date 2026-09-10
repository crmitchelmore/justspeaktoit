// Recovering audio that was captured and never transcribed (issue #992).
//
// The safety recording is written for exactly the case nobody can test on
// demand: the process dies — jetsam, a crash, a battery cut — between the
// first buffer and the delivered transcript. Today that audio survives on
// disk and nothing ever looks at it again.
//
// Everything that decides *what happened to a file* lives here, pure and
// clock-driven, because the failure mode of a recovery pass is destroying a
// recording it misread. The rule this file exists to enforce is that a
// recovery pass has no way to delete a file at all: the plan it produces can
// name a *claim record* to forget, never a byte of user audio. Discarding
// audio stays a thing the person who recorded it does, on purpose.
//
// Run identity is the one the stack already has: the `run` UUID that
// `StartupDiagnostics`, `CapturePresentationGate` and `CaptureWatchdogMonitor`
// all stamp their observations with. Nothing here invents a second scheme.
import Foundation

// MARK: - The claim

/// The record a capture leaves beside its safety recording while it is still
/// running, and clears when the transcript has been delivered.
///
/// A claim is not the recording. It is the only evidence that a particular
/// file was *in the middle of being written* rather than finished, which is
/// the entire distinction a recovery pass has to draw. Files in the recordings
/// directory with no claim are ordinary finished recordings — the saved-audio
/// library already lists and plays them — and this pass leaves them alone.
public struct CaptureSafetyClaim: Codable, Equatable, Sendable {
    /// Identity of the capture that opened the file.
    ///
    /// On iOS this is `AudioRecordingPersistence.stableRecordingID(for:)` —
    /// the value `RecordingInfo.id` already carries — so a claim and the entry
    /// the saved-recording library lists are the same thing, and the identity
    /// is re-derivable from the file on a later launch without a lookup table.
    /// No new identifier scheme is introduced for recovery.
    public let run: UUID
    /// File name only, never a path: the container moves between installs and
    /// an absolute path recorded yesterday does not resolve today.
    public let fileName: String
    /// When the capture began, for the sentence the user is shown.
    public let startedAt: Date
    /// Identity of the process that opened the file, generated once per
    /// launch. Equality with the current process's identity is proof that the
    /// owner is *this* process and therefore alive.
    public let owner: UUID
    /// Refreshed by the owning capture while it runs. Its age is the evidence
    /// that a claim written by some *other* process is or is not still live.
    public var lastHeartbeat: Date
    /// Set once the transcript for this run reached its destination. A claim
    /// that says so is never offered for recovery even if it outlives its
    /// capture, because re-transcribing already-delivered audio would put a
    /// duplicate in History.
    public var deliveredTranscript: Bool

    public init(
        run: UUID,
        fileName: String,
        startedAt: Date,
        owner: UUID,
        lastHeartbeat: Date,
        deliveredTranscript: Bool = false
    ) {
        self.run = run
        self.fileName = fileName
        self.startedAt = startedAt
        self.owner = owner
        self.lastHeartbeat = lastHeartbeat
        self.deliveredTranscript = deliveredTranscript
    }
}

/// One file as the recovery pass sees it: a name and a size, nothing read
/// from inside it.
public struct CaptureSafetyFile: Equatable, Sendable {
    public let fileName: String
    public let byteSize: Int64

    public init(fileName: String, byteSize: Int64) {
        self.fileName = fileName
        self.byteSize = byteSize
    }
}

// MARK: - Policy

public enum CaptureRecoveryPolicy {
    /// How often a running capture refreshes its claim.
    public static let heartbeatIntervalSeconds: TimeInterval = 5

    /// How long a claim from another process may go unrefreshed before its
    /// owner is treated as gone.
    ///
    /// Twelve heartbeat intervals. The cost of being wrong is asymmetric and
    /// this errs the safe way in both directions: too short and a live
    /// capture's file is offered for recovery while it is still being written;
    /// too long and the user waits one extra launch before being offered audio
    /// that is not going anywhere. Nothing is deleted either way.
    public static let stalenessWindowSeconds: TimeInterval = heartbeatIntervalSeconds * 12

    /// How far a heartbeat may sit in the future before the clock is treated
    /// as unreliable. Small, because a legitimate heartbeat is never ahead of
    /// `now`; anything beyond scheduling jitter means the clock moved.
    public static let clockToleranceSeconds: TimeInterval = 5

    /// Below this the file holds a container and no meaningful audio. An
    /// AAC `.m4a` with a handful of frames is already several kilobytes, so
    /// this only catches files that never received a buffer.
    public static let minimumRecoverableBytes: Int64 = 4096
}

// MARK: - Verdicts

/// Why a claim is being treated as belonging to a capture that is running
/// right now. Each is positive evidence of life, never an absence of evidence
/// of death.
public enum CaptureLivenessEvidence: String, Equatable, Sendable {
    /// The caller says this run is capturing in this process at this moment.
    case runIsCapturingNow
    /// The claim was opened by this very process launch.
    case sameProcess
    /// Another process refreshed the claim within the staleness window.
    case recentHeartbeat
}

/// Why a file is being kept and shown but not acted on. Every one of these
/// means "the pass could not establish what this is", and the response to all
/// of them is identical: keep the audio, say so, do nothing.
public enum CaptureRecoveryUncertainty: String, Equatable, Sendable {
    /// The transcript for this run was already delivered. Re-transcribing
    /// would duplicate a History entry, so it is not offered — but the audio
    /// stays exactly where it is.
    case transcriptAlreadyDelivered
    /// The owner is gone but the file never grew past an empty container, so
    /// there is very likely nothing in it. "Very likely" is not "certainly",
    /// which is why this keeps the file instead of tidying it away.
    case fileHoldsNoAudio
    /// The heartbeat is in the future. A clock that moved makes every age
    /// comparison in this file meaningless for this claim, so no age-based
    /// conclusion is drawn from it at all.
    case clockUnreliable
}

/// What the pass concluded about one claim.
public enum CaptureRecoveryDisposition: Equatable, Sendable {
    /// A capture owns this file right now. Untouchable, and not shown.
    case live(CaptureLivenessEvidence)
    /// The owner is provably gone and the file holds audio. This is the one
    /// disposition that offers the user anything: Transcribe, or Keep.
    case recoverable
    /// Kept and reported, never acted on.
    case uncertain(CaptureRecoveryUncertainty)
    /// The claim outlived its file — the recording was deleted, or the
    /// container was replaced. There is nothing to recover and nothing to
    /// show; only the claim record itself can be forgotten.
    case nothingRecorded
}

/// One claim, and what became of it.
public struct CaptureRecoveryFinding: Equatable, Sendable {
    public let run: UUID
    public let fileName: String
    public let startedAt: Date
    public let byteSize: Int64
    public let disposition: CaptureRecoveryDisposition

    public init(
        run: UUID,
        fileName: String,
        startedAt: Date,
        byteSize: Int64,
        disposition: CaptureRecoveryDisposition
    ) {
        self.run = run
        self.fileName = fileName
        self.startedAt = startedAt
        self.byteSize = byteSize
        self.disposition = disposition
    }
}

// MARK: - The pass

/// Everything the pass is allowed to know. All of it is a fact about a file or
/// a clock; none of it is a transcript, a credential, a route or a device.
public struct CaptureRecoveryInput: Sendable {
    public let claims: [CaptureSafetyClaim]
    public let files: [CaptureSafetyFile]
    /// This process launch's identity.
    public let currentOwner: UUID
    /// Runs the caller knows are capturing at this instant. Belt to the
    /// process-identity braces: a claim for a live run is never reachable by
    /// any other rule in this file.
    public let liveRuns: Set<UUID>
    public let now: Date

    public init(
        claims: [CaptureSafetyClaim],
        files: [CaptureSafetyFile],
        currentOwner: UUID,
        liveRuns: Set<UUID> = [],
        now: Date = Date()
    ) {
        self.claims = claims
        self.files = files
        self.currentOwner = currentOwner
        self.liveRuns = liveRuns
        self.now = now
    }
}

/// The result of a pass.
///
/// Note what is not here: there is no list of files to remove. The type has no
/// way to express "delete this recording", so no caller can act on one by
/// mistake and no future edit can add one without changing this contract.
public struct CaptureRecoveryPlan: Equatable, Sendable {
    public let findings: [CaptureRecoveryFinding]

    public init(findings: [CaptureRecoveryFinding]) {
        self.findings = findings
    }

    /// Captures to offer the user. Oldest first, so a queue of them is
    /// resolved in the order they were recorded.
    public var recoverable: [CaptureRecoveryFinding] {
        self.findings
            .filter { $0.disposition == .recoverable }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Captures whose audio is being kept without an offer, and why. These are
    /// reported to the user rather than swept up silently.
    public var uncertain: [CaptureRecoveryFinding] {
        self.findings.filter {
            if case .uncertain = $0.disposition { return true }
            return false
        }
    }

    /// Claim *records* that can be forgotten — and only those whose file has
    /// already gone. Forgetting one of these removes a few bytes of
    /// bookkeeping and no audio whatsoever.
    public var claimsToForget: [UUID] {
        self.findings
            .filter { $0.disposition == .nothingRecorded }
            .map(\.run)
    }

    /// True while any capture in this plan is still running. The caller uses
    /// it to hold the recovery prompt back rather than interrupting a capture
    /// in progress with a question about a different one.
    public var hasLiveCapture: Bool {
        self.findings.contains {
            if case .live = $0.disposition { return true }
            return false
        }
    }
}

public enum CaptureRecoveryScanner {
    /// Decides what became of every claim.
    ///
    /// The order of the rules is the substance. Liveness is established
    /// first and from positive evidence only, so the single outcome this pass
    /// must never produce — treating a file that a running capture is writing
    /// into as an orphan — is unreachable from any later rule.
    public static func scan(
        _ input: CaptureRecoveryInput,
        stalenessWindow: TimeInterval = CaptureRecoveryPolicy.stalenessWindowSeconds,
        clockTolerance: TimeInterval = CaptureRecoveryPolicy.clockToleranceSeconds,
        minimumRecoverableBytes: Int64 = CaptureRecoveryPolicy.minimumRecoverableBytes
    ) -> CaptureRecoveryPlan {
        let sizes = Dictionary(
            input.files.map { ($0.fileName, $0.byteSize) },
            uniquingKeysWith: { first, _ in first }
        )

        let findings = input.claims.map { claim -> CaptureRecoveryFinding in
            let size = sizes[claim.fileName]
            let disposition = Self.disposition(
                for: claim,
                byteSize: size,
                input: input,
                thresholds: Thresholds(
                    stalenessWindow: stalenessWindow,
                    clockTolerance: clockTolerance,
                    minimumRecoverableBytes: minimumRecoverableBytes
                )
            )
            return CaptureRecoveryFinding(
                run: claim.run,
                fileName: claim.fileName,
                startedAt: claim.startedAt,
                byteSize: size ?? 0,
                disposition: disposition
            )
        }
        return CaptureRecoveryPlan(findings: findings)
    }

    /// The three numbers the pass compares against, bundled so the rules read
    /// as rules rather than as a parameter list.
    struct Thresholds {
        let stalenessWindow: TimeInterval
        let clockTolerance: TimeInterval
        let minimumRecoverableBytes: Int64
    }

    private static func disposition(
        for claim: CaptureSafetyClaim,
        byteSize: Int64?,
        input: CaptureRecoveryInput,
        thresholds: Thresholds
    ) -> CaptureRecoveryDisposition {
        // 1. Liveness, from positive evidence, before anything else.
        if input.liveRuns.contains(claim.run) {
            return .live(.runIsCapturingNow)
        }
        if claim.owner == input.currentOwner {
            // This process opened the file. Whether or not its capture is
            // still running, no crash separated us from it, so nothing here
            // is orphaned and nothing needs recovering.
            return .live(.sameProcess)
        }

        // 2. A clock that moved makes every age below meaningless. Say so
        //    rather than drawing a conclusion from an age we cannot trust.
        if claim.lastHeartbeat > input.now.addingTimeInterval(thresholds.clockTolerance) {
            return .uncertain(.clockUnreliable)
        }

        // 3. A heartbeat refreshed within the window means another process is
        //    capturing into this file at this moment.
        if input.now.timeIntervalSince(claim.lastHeartbeat) <= thresholds.stalenessWindow {
            return .live(.recentHeartbeat)
        }

        // From here the owner is gone. Nothing below deletes anything.
        guard let byteSize else {
            return .nothingRecorded
        }
        if claim.deliveredTranscript {
            return .uncertain(.transcriptAlreadyDelivered)
        }
        if byteSize < thresholds.minimumRecoverableBytes {
            return .uncertain(.fileHoldsNoAudio)
        }
        return .recoverable
    }
}
