#if os(iOS)
import Foundation
import SpeakCore

// The claim a running capture leaves beside its safety recording (issue #992).
//
// Split out of `AudioRecordingPersistence` so the recorder file stays about
// writing audio. The claim is what lets a launch after a crash tell a
// half-written recording from a finished one; the rules that read it are in
// SpeakCore's `CaptureRecoveryScanner`, where `swift test` proves them.
extension AudioRecordingPersistence {
    func startClaimHeartbeat(for recording: UUID) {
        Self.openClaims.insert(recording)
        claimHeartbeat?.invalidate()
        let timer = Timer(
            timeInterval: CaptureRecoveryPolicy.heartbeatIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeClaim == recording else { return }
                self.claimStore.heartbeat(recording: recording)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        claimHeartbeat = timer
    }

    /// Drops the claim for the file this recorder last wrote, after that file
    /// has been deleted. A claim outliving its audio is bookkeeping pointing at
    /// nothing; the audio is never deleted *because* of a claim.
    func forgetLastClaim() {
        guard let claim = lastClaim else { return }
        lastClaim = nil
        claimStore.forget(recording: claim)
    }

    func stopClaimHeartbeat() {
        claimHeartbeat?.invalidate()
        claimHeartbeat = nil
        if let activeClaim { Self.openClaims.remove(activeClaim) }
        activeClaim = nil
    }

}
#endif
