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

    func stopClaimHeartbeat() {
        claimHeartbeat?.invalidate()
        claimHeartbeat = nil
        if let activeClaim { Self.openClaims.remove(activeClaim) }
        activeClaim = nil
    }

}
#endif
