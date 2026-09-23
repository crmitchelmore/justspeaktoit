import Foundation
import SpeakDesktop

/// Native in-app playback of the selected History recording. This is additive:
/// Open audio still launches the registered external application. Play never
/// modifies the recording, uses only the store-resolved audio URL, and stops
/// before recording, importing, switching records or closing.
extension DesktopHostController {
    func preparePlayback() {
        playback.setStatusHandler { [weak self] revision, message in
            Task { await self?.playbackStatus(revision: revision, message: message) }
        }
    }

    /// Terminal playback outcomes share the status line, but never while a
    /// recording or transcription owns it.
    func playbackStatus(revision: UInt64, message: String) {
        guard !closed, !busy, recording == nil, playback.isCurrent(revision: revision) else { return }
        update(message)
    }

    /// Play/Pause for the selected record: pauses or resumes an active run for
    /// that record, otherwise starts a new run from the canonical audio file.
    package func playbackToggle(_ identifier: String) async {
        guard !closed, let id = UUID(uuidString: identifier), let record = history[id] else { return }
        if playback.togglePause(recordID: id) { return }
        guard canUseHistory, selectedHistoryID == id, isVisible(id) else { return }
        // History playback replaces Read aloud, including a segment still being synthesized.
        stopReadAloud()
        activeOperations += 1
        defer { finishOperation() }
        do {
            let audio = try await store.audioURL(for: record)
            // Re-check after the suspension: the selection, a recording or
            // shutdown may have changed while the store resolved the file.
            guard !closed, canUseHistory, selectedHistoryID == id else { return }
            try playback.play(recordID: id, path: audio.path, knownDuration: record.result?.duration)
        } catch { update("Could not play recording: \(error.localizedDescription)") }
    }

    package func playbackStop() {
        guard !closed else { return }
        stopReadAloud()
        playback.stop()
    }
}
