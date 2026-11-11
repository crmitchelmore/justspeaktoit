import Foundation
import SpeakDesktop

extension DesktopHostController {
    package func beginAudioCleanupConfirmation() {
        guard !closed else { return }
        guard canUseHistory, audioCleanupTask == nil, audioCleanupConfirmation == nil else {
            update("Recording audio cleanup is unavailable while another operation or confirmation is running.")
            return
        }
        busy = true
        activeOperations += 1
        update("Preparing saved audio confirmation...", state: 2)
        audioCleanupTask = Task {
            defer { endAudioCleanupOperation() }
            do {
                let snapshot = try await store.snapshotSavedAudio()
                try Task.checkCancellation()
                guard !closed else { return }
                guard !snapshot.isEmpty else {
                    showSelectedHistory(status: "No saved recording audio needs deleting. History was kept.", state: 0)
                    return
                }
                let id = UUID()
                audioCleanupConfirmation = (id, snapshot)
                busy = false
                update("Confirm audio deletion in the dialog. History will be kept.", state: 0)
                try Platform.confirmAudioCleanup(id: id, count: snapshot.count)
            } catch {
                audioCleanupConfirmation = nil
                guard !closed else { return }
                showSelectedHistory(status: "Could not prepare audio cleanup: \(error.localizedDescription)", state: 0)
            }
        }
    }

    package func answerAudioCleanup(_ identifier: String, delete: Bool) {
        guard !closed else { return }
        guard let confirmation = audioCleanupConfirmation,
              UUID(uuidString: identifier) == confirmation.id else {
            update("The recording audio confirmation is no longer current. Nothing was deleted.")
            return
        }
        audioCleanupConfirmation = nil
        guard delete else {
            update("Audio cleanup cancelled. Saved audio and History were kept.")
            return
        }
        guard canUseHistory, audioCleanupTask == nil else {
            update("Audio cleanup cancelled because another operation started. Nothing was deleted.")
            return
        }
        busy = true
        activeOperations += 1
        update("Deleting confirmed saved audio...", state: 2)
        audioCleanupTask = Task {
            defer { endAudioCleanupOperation() }
            do {
                try await playback.stopSavedAudioAndWait()
                try Task.checkCancellation()
                guard !closed else { return }
                let outcome = try await store.removeSavedAudio(confirmation.snapshot)
                guard !closed else { return }
                var status = "Deleted \(outcome.removed) saved audio file(s). History entries were kept."
                if let first = outcome.failures.first {
                    status += " \(outcome.failures.count) file(s) need attention: \(first.filename): \(first.message)"
                }
                if outcome.cancelled {
                    status += " Cleanup stopped; remaining audio was kept."
                }
                showSelectedHistory(status: status, state: 0)
            } catch {
                guard !closed else { return }
                showSelectedHistory(status: "Audio cleanup stopped: \(error.localizedDescription)", state: 0)
            }
        }
    }

    private func endAudioCleanupOperation() {
        busy = false
        audioCleanupTask = nil
        finishOperation()
    }
}
