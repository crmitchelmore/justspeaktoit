import Foundation
import SpeakCore
import SpeakDesktop

/// The recording HUD follows one dictation from Record to its result, keyed by
/// its record. Imports and retries never show it, and a phase reported for any
/// other record is ignored, so a late output or an import can never overwrite
/// or finish a newer dictation's HUD.
extension DesktopHostController {
    /// A recording has started: the status line and a new HUD session say so.
    func announceRecording(_ recordID: UUID, profile: DesktopProfileSession, trigger: HotKeySessionTrigger) {
        update(profileRecordingStatus(profile, trigger: trigger), state: 1)
        beginHUD(recordID, .recording(profile: profile.profileName))
    }

    /// A dictation that ends without a result: the status line says why, and
    /// so does the HUD if it follows this recording.
    func reportFailure(_ message: String, for recordID: UUID, headline: String = "Something went wrong") {
        update(message, state: 0)
        finishHUD(recordID, .failure(message, headline: headline))
    }

    func beginHUD(_ recordID: UUID, _ state: DesktopHUDState) {
        guard !closed else { return }
        hudRecording = recordID
        Platform.hud(state)
    }

    func hud(_ recordID: UUID, _ state: DesktopHUDState) {
        guard !closed, hudRecording == recordID else { return }
        Platform.hud(state)
    }

    func finishHUD(_ recordID: UUID, _ state: DesktopHUDState) {
        guard !closed, hudRecording == recordID else { return }
        hudRecording = nil
        Platform.hud(state)
    }

    /// A dictation that could not start has no record; it replaces whatever
    /// the HUD showed.
    func failHUDStart(_ message: String) {
        guard !closed else { return }
        hudRecording = nil
        Platform.hud(.failure(message, headline: "Recording could not start"))
    }

    /// The HUD's last word on a presented record: delivering while its output
    /// runs (the output finishes it), otherwise the result.
    func presentHUD(_ record: DesktopRecordingStore.Record, status: String, output: DesktopHostOutputStart) {
        switch output {
        case .inserting, .copying:
            hud(record.id, .delivering(copying: output == .copying))
        case .busy, .unavailable:
            if let failure = record.failure {
                finishHUD(record.id, .failure(failure, headline: "Transcription failed"))
            } else if record.postProcessingFailure != nil {
                finishHUD(record.id, .failure(status, headline: "Post-processing failed"))
            } else if (record.displayText ?? "").isEmpty {
                finishHUD(record.id, .success("No speech was detected."))
            } else {
                finishHUD(record.id, .success(status))
            }
        }
    }
}
